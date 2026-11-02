import AppKit
import Synchronization
import VitrineBinary
import VitrineTrust
import VitrineDocument
import VitrineSupport
import VitrineUI

/// Apps, installers, disk images and provisioning profiles in the picked card design (cards r3-a Glass Case) with the
/// trust verdict under it (trust r3-a Verdict first): the object's own icon on a lit stage with one glass chip, the
/// museum label (the gradient kind tile, title 14/650, sentence, at most three numbers, a 3 pt top rule for caution
/// and danger), then the verdict box and the answers, findings first and numbered; a calm card lists its answers
/// tight. The whole card scrolls, so a small Quick Look window or Finder's preview pane shows all of it; under 420 pt
/// the stage steps aside and the rows take their narrow form. ⌘I opens Details. The document keeps its text view so
/// copy still works; the capsule below shows the pill. Torrents, configuration profiles and iOS and Android apps use
/// the same card (P-2, P-4); an app's, installer's or torrent's files are one viewer switch away (Card / Contents, or
/// Files for a torrent) in the archive outline, nested archives included. roadmap: S-8, S-22
@MainActor
public final class BinaryCardRenderer: NSObject, Renderer {
    public static func canRender(_ kind: FileKind) -> Bool {
        if case .reader = kind { return true }
        return [.appBundle, .installerPackage, .diskImage, .provisioningProfile, .configurationProfile, .torrent, .keyMaterial, .lockfile,
         .archive(.ipa), .archive(.apk)].contains(kind)
    }

    public override required init() { super.init() }

    // MARK: The signature check (G-34, S-16 follow-up A)
    //
    // The full check of a large app takes seconds (Xcode 6.5 s), and the card is drawn on the main actor. So the card
    // never waits for it there: the check runs on a worker thread (SignatureVerifier.assess(url:budget:) joins one
    // already running for the file), the first paint waits off the main thread at most `firstLookBudget` and shows
    // what had finished — the quick result as "Partly checked", or "Signature not checked" — with "Checking the
    // signature…" in the gutter, and the card and the pill change in place to the full verdict when it comes. A
    // preview closed first cancels the wait and the result is dropped. The verdict words are BinaryFacts' own, so
    // "Valid" still appears only after the full check (G-34).

    /// The check itself: the code at the URL, given at most the duration. Tests stand in a slow one.
    nonisolated(unsafe) static var assessSignature: @Sendable (URL, Duration) -> SignatureAssessment = {
        SignatureVerifier.assess(url: $0, budget: $1)
    }
    /// How long the first paint waits, off the main thread, before it shows what had finished: long enough for most
    /// small apps and tools to finish whole (no second paint), short enough to read as at once.
    nonisolated(unsafe) static var firstLookBudget: Duration = .milliseconds(250)
    /// How long the card goes on waiting for the full verdict; past it the card stays "Partly checked".
    nonisolated(unsafe) static var fullCheckBudget: Duration = .seconds(120)

    /// The wait for the full verdict, cancelled when the preview goes.
    let followUp = FollowUp()

    deinit { followUp.cancel() }

    /// The gutter while the full check runs.
    static var checkingStatus: GutterStatus {
        GutterStatus(leading: String(localized: "Checking the signature…", bundle: .previewKit,
                                     comment: "Gutter under an app's card while the full signature check of every file inside is still running."))
    }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        // Started before the facts are read, so the first paint can show at least the quick result.
        let assess = Self.assessSignature
        var watch: SignatureWatch?
        var firstLook: SignatureAssessment?
        if BinaryFacts.assessesSignature(kind) {
            let started = SignatureWatch(url: url, assess: assess)
            firstLook = await started.start(firstLook: Self.firstLookBudget, budget: Self.fullCheckBudget)
            watch = started
        }
        var shown: SignatureAssessment?
        let read = try BinaryFacts.read(url: url, kind: kind) { checked in
            // Never a wait here: a check not started above is started now and shown as far as it got (usually not yet).
            let verdict = (checked == url ? firstLook : nil) ?? assess(checked, .zero)
            shown = verdict
            return verdict
        }
        var document = read.0
        // Where it came from (T-1): the address and the app that downloaded it, in the card's Details.
        let origin = DownloadOrigin.facts(for: url)
        document.facts += origin
        let extras = read.1
        let card = BinaryCard.make(document: document, url: url)
        var contents: ArchiveView?
        if let listing = extras.contents {
            let model = FamilyFacts.archiveModel(listing: listing, fileSize: listing.fileSize, kind: kind)
            contents = ArchiveView(model: model, archiveName: url.lastPathComponent, source: extras.contentsSource, kind: kind)
            document.views.append(model.document.views[0])
            document.viewTitles = ["Card",
                                   extras.contentsTitle]
        }
        // The scripts, readable (T-2): a text view the viewer switch offers after the contents.
        if !extras.scripts.isEmpty {
            // Masked as every text view masks a script's secrets (G-23).
            let text = extras.scripts.map { "# \($0.name)\n\(LensPolicy.masked($0.text, kind: .code(language: "shell")).text)" }.joined(separator: "\n\n")
            if document.viewTitles == nil { document.viewTitles = ["Card"] }
            document.views.append(.code(text, language: "shell"))
            document.viewTitles?.append("Scripts")
        }
        for extra in extras.extraViews {
            if document.viewTitles == nil { document.viewTitles = ["Card"] }
            document.views.append(extra.view)
            document.viewTitles?.append(extra.title)
        }
        let view = BinaryCardView(card: card, icon: extras.icon ?? NSWorkspace.shared.icon(forFile: url.path), facts: document.facts,
                                  contents: contents, stageContent: extras.stage?())
        let scrollOffset: @MainActor () -> Double? = { [weak view] in view.map { Double($0.scrollView.contentView.bounds.origin.y) } }
        let restoreScroll: @MainActor (Double) -> Void = { [weak view] y in view?.scroll(to: CGFloat(y)) }
        let toggleInspector: @MainActor () -> Void = { [weak view] in view?.toggleInspector() }
        guard let contents else {
            let preview = RenderedPreview(view: view, document: document, owner: self, scrollOffset: scrollOffset,
                                          restoreScroll: restoreScroll, toggleInspector: toggleInspector)
            if let shown, shown.ranOutOfTime {
                awaitFullVerdict(watch ?? SignatureWatch(url: url, assess: assess), startWatch: watch == nil,
                                 url: url, kind: kind, origin: origin, view: view, preview: preview)
            }
            return preview
        }
        let preview = RenderedPreview(view: view, document: document, owner: self, scrollOffset: scrollOffset,
                                      restoreScroll: restoreScroll, toggleInspector: toggleInspector,
                                      find: { [weak view] q, forward in
                                          view?.findInContents(q, forward: forward) ?? FindResult(count: 0, index: -1)
                                      },
                                      clearFind: { [weak view] in view?.contents?.outline.clearFind() },
                                      showView: { [weak view] index in view?.show(index) ?? false })
        view.requestContents = { [weak preview] in preview?.requestView(1) }
        // The pill stays the card's: a nested archive opened in the contents speaks through the gutter only.
        contents.onStatus = { [weak preview] status in preview?.updateGutter(status) }
        if let shown, shown.ranOutOfTime {
            awaitFullVerdict(watch ?? SignatureWatch(url: url, assess: assess), startWatch: watch == nil,
                             url: url, kind: kind, origin: origin, view: view, preview: preview)
        }
        return preview
    }

    /// Says the check is still running, waits for its end off the main thread, then redraws the card and the pill
    /// with the full verdict. Holds the view and the preview weakly: a preview closed first is left alone.
    private func awaitFullVerdict(_ watch: SignatureWatch, startWatch: Bool, url: URL, kind: FileKind, origin: [Fact],
                                  view: BinaryCardView, preview: RenderedPreview) {
        preview.updateGutter(Self.checkingStatus)
        let budget = Self.fullCheckBudget
        followUp.replace(Task { @MainActor [weak view, weak preview] in
            if startWatch { _ = await watch.start(firstLook: .zero, budget: budget) }
            let final = await watch.final()
            guard !Task.isCancelled, let view, let preview else { return }
            Self.apply(final, url: url, kind: kind, origin: origin, view: view, preview: preview)
        })
    }

    /// The card and the pill rebuilt from the full verdict, in place: the same view, scroll position and Details.
    /// A file that can no longer be read keeps the first card, which said what was known.
    static func apply(_ final: SignatureAssessment, url: URL, kind: FileKind, origin: [Fact], view: BinaryCardView, preview: RenderedPreview) {
        if preview.gutter == checkingStatus { preview.updateGutter(nil) }
        guard let fresh = try? BinaryFacts.document(url: url, kind: kind, assessSignature: { _ in final }) else { return }
        var document = preview.document
        document.facts = fresh.facts + origin
        document.badges = fresh.badges
        if !document.views.isEmpty, let summary = fresh.views.first { document.views[0] = summary }
        view.update(card: BinaryCard.make(document: document, url: url), facts: document.facts)
        preview.updateDocument(document)
    }
}

/// One card's signature check, waited for on a worker thread so the main thread never blocks on it (G-34, S-16).
/// `start` hands back what had finished after the first look; the same worker then waits, up to the budget, for
/// the full verdict that `final()` returns. Waiting happens inside SignatureVerifier (a condition variable), so it
/// runs on a dispatch thread, never on Swift's cooperative pool; the check itself goes on to its end either way.
final class SignatureWatch: Sendable {
    private let url: URL
    private let assess: @Sendable (URL, Duration) -> SignatureAssessment
    private struct State {
        var final: SignatureAssessment?
        var waiters: [CheckedContinuation<SignatureAssessment, Never>] = []
    }
    private let state = Mutex(State())

    init(url: URL, assess: @escaping @Sendable (URL, Duration) -> SignatureAssessment) {
        self.url = url
        self.assess = assess
    }

    /// Starts the check (or joins the one running for the file) and returns what had finished after `firstLook`.
    func start(firstLook: Duration, budget: Duration) async -> SignatureAssessment {
        let url = url, assess = assess
        return await withCheckedContinuation { (first: CheckedContinuation<SignatureAssessment, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let look = assess(url, firstLook)
                first.resume(returning: look)
                self.finish(look.ranOutOfTime ? assess(url, budget) : look)
            }
        }
    }

    /// The verdict at the end: the full one, or what had finished when the budget ran out (`ranOutOfTime`).
    func final() async -> SignatureAssessment {
        await withCheckedContinuation { (c: CheckedContinuation<SignatureAssessment, Never>) in
            let ready = state.withLock { s -> SignatureAssessment? in
                if let final = s.final { return final }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    private func finish(_ verdict: SignatureAssessment) {
        let waiters = state.withLock { s -> [CheckedContinuation<SignatureAssessment, Never>] in
            s.final = verdict
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume(returning: verdict) }
    }
}

/// The card's wait for the full verdict: one task at a time, cancelled from the renderer's deinit.
final class FollowUp: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    func replace(_ next: Task<Void, Never>) { task.withLock { $0?.cancel(); $0 = next } }
    func cancel() { task.withLock { $0?.cancel(); $0 = nil } }
    /// The wait in flight, for tests.
    var current: Task<Void, Never>? { task.withLock { $0 } }
}

/// The stage, the label and the verdict, top to bottom inside a scroll view; Details on the right when it is open.
@MainActor
final class BinaryCardView: NSView {
    private(set) var card: BinaryCard
    /// The width under which the Glass Case steps aside for Finder's pane (cards r3-a §4, G-8).
    static let narrowWidth: CGFloat = 420

    /// The parts tests look at.
    private(set) var scrollView: NSScrollView!
    private(set) var stage: StageView!
    private(set) var stageChipLabel: NSTextField!
    private(set) var tile: KindTileView!
    private(set) var titleField: NSTextField!
    private(set) var sentenceField: WrappingLabel!
    private(set) var stripValues: [String] = []
    private(set) var stripCells: [NSView] = []
    private(set) var stripLabels: [NSTextField] = []
    private(set) var stripValueFields: [NSTextField] = []
    private(set) var ruleView: TokenBox?
    private(set) var verdictBox: VerdictBoxView!
    private(set) var answerRows: [AnswerRow] = []
    private(set) var inspector: DetailsInspector!
    private(set) var isNarrow = false
    var isInspectorShown: Bool { !inspector.isHidden }

    private var content: CardFlippedView!
    private var stageWide: [NSLayoutConstraint] = []
    private var stageNarrow: [NSLayoutConstraint] = []
    private var inspectorWidth: NSLayoutConstraint!

    /// The files behind the card (an app's, installer's or torrent's), shown in place of the card by the viewer
    /// switch's second view.
    let contents: ArchiveView?
    /// Asks the host to switch to the contents (find runs there).
    var requestContents: (() -> Void)?
    var isShowingContents: Bool { contents?.isHidden == false }

    init(card: BinaryCard, icon: NSImage, facts: [Fact] = [], contents: ArchiveView? = nil, stageContent: NSView? = nil) {
        self.card = card
        self.contents = contents
        super.init(frame: .zero)
        wantsLayer = true

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        content = CardFlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        addSubview(scrollView)

        // Stage: nothing on it but the object and one glass chip.
        stage = StageView()
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(iconView)
        // A format view (a map, a model, a waveform …; format views r1 picked A) takes the object's place on the stage.
        if let stageContent {
            iconView.isHidden = true
            stageContent.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(stageContent)
            NSLayoutConstraint.activate([
                stageContent.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 16),
                stageContent.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -16),
                stageContent.topAnchor.constraint(equalTo: stage.topAnchor, constant: 44),
                stageContent.bottomAnchor.constraint(equalTo: stage.bottomAnchor, constant: -16),
            ])
        }
        let chip = ChipView(text: card.stageChip, symbol: nil, fill: "glass", textColor: "t2", border: "hair")
        stageChipLabel = chip.label
        stage.addSubview(chip)
        content.addSubview(stage)

        let clip = scrollView.contentView
        // A stage that carries a format view gets more of the window: the view is the point of the card.
        let fill = stage.heightAnchor.constraint(equalTo: heightAnchor, multiplier: stageContent == nil ? 0.4 : 0.55)
        fill.priority = .defaultHigh
        stageWide = [fill, stage.heightAnchor.constraint(greaterThanOrEqualToConstant: stageContent == nil ? 150 : 260)]
        stageNarrow = [stage.heightAnchor.constraint(equalToConstant: 0)]
        NSLayoutConstraint.activate(stageWide + [
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor), content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),

            stage.topAnchor.constraint(equalTo: content.topAnchor), stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            iconView.centerXAnchor.constraint(equalTo: stage.centerXAnchor), iconView.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            iconView.heightAnchor.constraint(equalTo: stage.heightAnchor, multiplier: 0.62), iconView.heightAnchor.constraint(lessThanOrEqualToConstant: 256),
            iconView.widthAnchor.constraint(equalTo: iconView.heightAnchor),
            chip.topAnchor.constraint(equalTo: stage.topAnchor, constant: 12), chip.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -12),
        ])
        // The label and the verdict under the stage: what the full signature check redraws (`update(card:facts:)`).
        installCard()
        if let contents {
            contents.translatesAutoresizingMaskIntoConstraints = false
            contents.isHidden = true
            addSubview(contents)
            NSLayoutConstraint.activate([
                contents.leadingAnchor.constraint(equalTo: leadingAnchor),
                contents.topAnchor.constraint(equalTo: topAnchor), contents.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        installInspector(facts: facts, hidden: true, width: 0)
    }

    // MARK: Redrawn in place (S-16 follow-up A)

    /// The museum label and the trust body now shown, and the constraints that place them.
    private var cardParts: [NSView] = []
    private var cardConstraints: [NSLayoutConstraint] = []
    private var inspectorConstraints: [NSLayoutConstraint] = []

    /// The card says what the full signature check found: the label and the verdict are drawn again from `card`,
    /// Details from `facts`; the stage, the contents, whether Details is open, the narrow form and the scroll
    /// position stay as they were.
    func update(card: BinaryCard, facts: [Fact]) {
        let y = scrollView.contentView.bounds.origin.y
        self.card = card
        installCard()
        installInspector(facts: facts, hidden: inspector.isHidden, width: inspectorWidth.constant)
        needsLayout = true
        scroll(to: y)
    }

    /// Builds the museum label and the trust body from `card` under the stage, replacing what was there.
    private func installCard() {
        NSLayoutConstraint.deactivate(cardConstraints)
        for part in cardParts { part.removeFromSuperview() }
        stripValues = []; stripCells = []; stripLabels = []; stripValueFields = []; ruleView = nil; answerRows = []
        stageChipLabel.stringValue = card.stageChip
        let lbl = museumLabel()
        let body = trustBody()
        content.addSubview(lbl)
        content.addSubview(body)
        cardParts = [lbl, body]
        cardConstraints = [
            lbl.topAnchor.constraint(equalTo: stage.bottomAnchor), lbl.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lbl.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            body.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 14), body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
        ]
        NSLayoutConstraint.activate(cardConstraints)
        if isNarrow { narrowCard(true) }
    }

    /// Details (⌘I) listing `facts`, replacing the one there, open or not as before.
    private func installInspector(facts: [Fact], hidden: Bool, width: CGFloat) {
        NSLayoutConstraint.deactivate(inspectorConstraints)
        inspector?.removeFromSuperview()
        let next = DetailsInspector(facts: facts)
        next.isHidden = hidden
        addSubview(next)
        inspector = next
        inspectorWidth = next.widthAnchor.constraint(equalToConstant: width)
        inspectorConstraints = [
            scrollView.trailingAnchor.constraint(equalTo: next.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor), next.topAnchor.constraint(equalTo: topAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor), inspectorWidth,
        ] + (contents.map { [$0.trailingAnchor.constraint(equalTo: next.leadingAnchor)] } ?? [])
        NSLayoutConstraint.activate(inspectorConstraints)
    }

    required init?(coder: NSCoder) { nil }

    /// The viewer switch: 0 the card, 1 the contents outline. Both are drawn here, so the host never shows text.
    func show(_ index: Int) -> Bool {
        guard let contents else { return false }
        contents.isHidden = index != 1
        scrollView.isHidden = index == 1
        if index == 1 { window?.makeFirstResponder(contents.outline.table) }
        return index == 0 || index == 1
    }

    /// Find searches the files: from the card it switches to them first, as Finder's search shows results.
    func findInContents(_ query: String, forward: Bool) -> FindResult {
        guard let contents else { return FindResult(count: 0, index: -1) }
        if !isShowingContents, !query.isEmpty { requestContents?() }
        return contents.outline.find(query, forward: forward)
    }

    /// The museum label (cards r3-a `.label`): hairlines top and bottom, padding 11 16, the tile and the title and
    /// sentence beside it, then the number strip across the full width under a separator.
    private func museumLabel() -> NSView {
        let lbl = TokenBox(fill: "card")
        let hairTop = TokenBox(fill: "hair"), hairBottom = TokenBox(fill: "hair")
        tile = KindTileView(token: Self.tileToken(card.kind), symbol: Self.tileSymbol(card.kind))
        titleField = cardLabel(card.title, font: tokenFont("fs-headline"), color: "t1")
        sentenceField = WrappingLabel(attributed: Self.sentence(card), lines: 2)
        for v in [hairTop, hairBottom, tile!, titleField!, sentenceField!] as [NSView] { lbl.addSubview(v) }
        var constraints = [
            hairTop.topAnchor.constraint(equalTo: lbl.topAnchor), hairTop.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
            hairTop.trailingAnchor.constraint(equalTo: lbl.trailingAnchor), hairTop.heightAnchor.constraint(equalToConstant: 0.5),
            hairBottom.bottomAnchor.constraint(equalTo: lbl.bottomAnchor), hairBottom.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
            hairBottom.trailingAnchor.constraint(equalTo: lbl.trailingAnchor), hairBottom.heightAnchor.constraint(equalToConstant: 0.5),
            tile.topAnchor.constraint(equalTo: lbl.topAnchor, constant: 11), tile.leadingAnchor.constraint(equalTo: lbl.leadingAnchor, constant: 16),
            titleField.topAnchor.constraint(equalTo: tile.topAnchor, constant: -1), titleField.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: lbl.trailingAnchor, constant: -16),
            sentenceField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1), sentenceField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            sentenceField.trailingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: -16),
        ]
        if card.strip.isEmpty {
            constraints += [lbl.bottomAnchor.constraint(greaterThanOrEqualTo: sentenceField.bottomAnchor, constant: 11),
                            lbl.bottomAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor, constant: 11),
                            lbl.bottomAnchor.constraint(equalTo: sentenceField.bottomAnchor, constant: 11).with(priority: .defaultLow)]
        } else {
            let stripSep = TokenBox(fill: "sep")
            let strip = NSStackView()
            strip.orientation = .horizontal
            strip.distribution = .fillEqually
            strip.spacing = 0
            strip.translatesAutoresizingMaskIntoConstraints = false
            for (i, stat) in card.strip.enumerated() {
                let cell = NSView()
                cell.translatesAutoresizingMaskIntoConstraints = false
                // `.label .ss`: value 14/650 tabular, its name sentence case 11/600 t2 (cards 8, G12); padding 6 16 7.
                let value = cardLabel(stat.value, font: tabularFigures(tokenFont("fs-headline")), color: "t1")
                let name = cardLabel(stat.label, font: tokenFont("fs-caption", weight: 600), color: "t2")
                cell.addSubview(value); cell.addSubview(name)
                NSLayoutConstraint.activate([
                    value.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6), value.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                    value.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
                    name.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 0), name.leadingAnchor.constraint(equalTo: value.leadingAnchor),
                    name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
                    name.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -7),
                ])
                if i > 0 {
                    let line = TokenBox(fill: "sep")
                    cell.addSubview(line)
                    NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: cell.leadingAnchor), line.topAnchor.constraint(equalTo: cell.topAnchor),
                                                 line.bottomAnchor.constraint(equalTo: cell.bottomAnchor), line.widthAnchor.constraint(equalToConstant: 0.5)])
                }
                strip.addArrangedSubview(cell)
                stripCells.append(cell)
                stripLabels.append(name)
                stripValueFields.append(value)
                stripValues.append(stat.value)
            }
            lbl.addSubview(stripSep); lbl.addSubview(strip)
            constraints += [
                stripSep.topAnchor.constraint(greaterThanOrEqualTo: sentenceField.bottomAnchor, constant: 9),
                stripSep.topAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor, constant: 9),
                stripSep.topAnchor.constraint(equalTo: sentenceField.bottomAnchor, constant: 9).with(priority: .defaultLow),
                stripSep.leadingAnchor.constraint(equalTo: lbl.leadingAnchor), stripSep.trailingAnchor.constraint(equalTo: lbl.trailingAnchor),
                stripSep.heightAnchor.constraint(equalToConstant: 0.5),
                strip.topAnchor.constraint(equalTo: stripSep.bottomAnchor), strip.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: lbl.trailingAnchor), strip.bottomAnchor.constraint(equalTo: lbl.bottomAnchor),
            ]
        }
        if let level = card.rule, level != .info {
            let rule = TokenBox(fill: level == .danger ? "danger" : "caution")
            lbl.addSubview(rule)
            ruleView = rule
            constraints += [rule.topAnchor.constraint(equalTo: lbl.topAnchor), rule.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
                            rule.trailingAnchor.constraint(equalTo: lbl.trailingAnchor), rule.heightAnchor.constraint(equalToConstant: 3)]
        }
        NSLayoutConstraint.activate(constraints)
        return lbl
    }

    /// The verdict, then the answers: caution and danger list the findings first, numbered, as full rows; calm lists
    /// every answer tight under the box (trust r3-a states 1–4).
    private func trustBody() -> NSView {
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        verdictBox = Self.verdictBox(card.verdict)
        body.addArrangedSubview(verdictBox)
        verdictBox.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let calm = card.verdict.level == .calm
        body.setCustomSpacing(calm ? 9 + 4 : 9, after: verdictBox)
        for (number, answer) in card.numberedAnswers {
            let row = AnswerRow(answer, number: number, style: calm ? .tight : .full)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            if calm { body.setCustomSpacing(3, after: row) }
            answerRows.append(row)
        }
        let column = AnswerRow.questionColumn(for: answerRows)
        for row in answerRows { row.questionWidthConstraint.constant = column }
        return body
    }

    override func layout() {
        let width = bounds.width - inspectorWidth.constant
        let narrow = bounds.width > 0 && width < Self.narrowWidth
        if narrow != isNarrow { setNarrow(narrow) }
        super.layout()
    }

    /// Finder's preview pane: the stage steps aside, the strip keeps two numbers, the verdict and the answers take
    /// their pane form (cards r3-a §4, trust r3-a "Finder preview pane").
    private func setNarrow(_ narrow: Bool) {
        isNarrow = narrow
        NSLayoutConstraint.deactivate(narrow ? stageWide : stageNarrow)
        NSLayoutConstraint.activate(narrow ? stageNarrow : stageWide)
        stage.isHidden = narrow
        narrowCard(narrow)
        needsLayout = true
    }

    /// The label's strip and the trust body in their narrow or wide form.
    private func narrowCard(_ narrow: Bool) {
        for (i, cell) in stripCells.enumerated() { cell.isHidden = narrow && i >= 2 }
        verdictBox.isNarrow = narrow
        for row in answerRows { row.isNarrow = narrow }
    }

    func toggleInspector() {
        inspector.isHidden.toggle()
        inspectorWidth.constant = inspector.isHidden ? 0 : Metric.value("w-inspector")
        needsLayout = true
    }

    func scroll(to y: CGFloat) {
        layoutSubtreeIfNeeded()
        let maxY = max(0, content.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.token("win").cgColor }
    }

    /// Apps, installers and profiles are app-kind tiles ("Apps, installers"; the cards design draws the profile on
    /// kind-app too); disk images are disk-kind.
    static func tileToken(_ kind: FileKind) -> String {
        switch kind {
        case .diskImage: "kind-disk"
        case .torrent: "kind-archive"
        case .lockfile, .reader: "kind-code"
        default: "kind-app"
        }
    }

    static func tileSymbol(_ kind: FileKind) -> String {
        switch kind {
        case .installerPackage: "shippingbox"
        case .diskImage: "externaldrive"
        case .provisioningProfile: "person.text.rectangle"
        case .configurationProfile: "gearshape.2"
        case .torrent: "arrow.down.circle"
        case .keyMaterial: "key"
        case .lockfile: "lock.doc"
        case .reader: "doc.text.magnifyingglass"
        case .archive(.ipa): "iphone"
        case .archive(.apk): "candybarphone"
        default: "app"
        }
    }

    /// The sentence 12 t2 with line height 1.38; the bold parts t1 at 600 (`.label .snt b`).
    static func sentence(_ card: BinaryCard) -> NSAttributedString {
        let size = Metric.value("fs-control")
        let text = NSMutableAttributedString(string: card.sentence, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.token("t2"),
        ])
        let ns = card.sentence as NSString
        for part in card.bold where !part.isEmpty {
            let r = ns.range(of: part)
            if r.location != NSNotFound {
                text.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: cssWeight(600)), .foregroundColor: NSColor.token("t1")], range: r)
            }
        }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = (size * 1.38).rounded()
        style.maximumLineHeight = (size * 1.38).rounded()
        style.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    static func verdictBox(_ v: BinaryCard.Verdict) -> VerdictBoxView { VerdictBoxView(v) }
}
