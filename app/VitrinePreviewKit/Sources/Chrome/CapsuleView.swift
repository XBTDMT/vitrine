import SwiftUI
import VitrineUI

/// The gutter under every preview and the Glass Capsule centred in it (chrome r3-b; tokens `h-gutter`, `h-capsule`,
/// `h-pill`; compact sizes below 420 pt, the Finder pane). Coverage lives at the gutter's left. The capsule holds,
/// in order: the status pill, the viewer switch (when the document has more than one view), copy, and the
/// inspector toggle (when the preview has one). Find, Open in… and ⌘K join it as they are built. roadmap: S-24
struct GutterView: View {
    let model: CapsuleModel

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 420
            // Three columns: the left text and the right status share what the capsule leaves, equally, so the
            // capsule stays centred and a long text truncates on its own side instead of running underneath.
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    // The open find field spans the gutter: its texts would sit under it, so they step aside
                    // (long work keeps its spinner and Cancel).
                    if let leading = model.gutterLeading, !model.finding {
                        Text(leading)
                            .font(.system(size: Metric.value("fs-control")).monospacedDigit())
                            .foregroundStyle(Color.token("t2"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(leading)
                            .accessibilityLabel(leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.document != nil {
                    CapsuleView(model: model, compact: compact).fixedSize()
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    // The right home (data 2): a state the preview reports, with Cancel while it is busy. Hidden in the
                    // compact gutter, where the capsule needs the width.
                    if !compact, let status = model.gutter, let trailing = status.trailing, !model.finding || status.busy {
                        if status.busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                        Text(trailing)
                            .font(.system(size: Metric.value("fs-control")))
                            .foregroundStyle(Color.token("t2"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if status.busy {
                            Button { model.cancelWork() } label: {
                                Text("Cancel", bundle: .previewKit, comment: "Gutter button: stops long work (sorting, scanning).")
                            }
                                .controlSize(.small)
                                .keyboardShortcut(.cancelAction)
                            Text("esc", bundle: .previewKit, comment: "Key cap beside Cancel: the Escape key's short name.")
                                .font(.system(size: Metric.value("fs-micro"), design: .monospaced))
                                .foregroundStyle(Color.token("t2"))
                                .padding(.horizontal, 4)
                                .background(Color.token("fill"), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.token("card2"))
        .overlay(alignment: .top) { Rectangle().fill(Color.token("sep")).frame(height: 0.5) }
    }
}

struct CapsuleView: View {
    @State private var pillHovered = false
    let model: CapsuleModel
    let compact: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var height: CGFloat { Metric.value(compact ? "h-capsule-compact" : "h-capsule") }

    var body: some View {
        HStack(spacing: 2) {
            if model.finding {
                FindField(model: model)
            } else {
                pill
                if model.viewTitles.count > 1 {
                    divider
                    ViewerSwitch(model: model)
                }
            }
            divider
            if model.canFind && !model.finding {
                CapsuleButton(symbol: "magnifyingglass",
                              help: String(localized: "Find (⌘F)", bundle: .previewKit, comment: "Capsule button tooltip: opens the find field.")) {
                    model.openFind()
                }
                    .keyboardShortcut("f", modifiers: .command)
            }
            do {
                // Copy as (I-7, data 9) and export (I-10, chrome r3-b): the system menu, opening upward from the capsule.
                Menu {
                    let offer = model.copyFormats?()
                    if let offer {
                        Section(offer.heading) {
                            ForEach(Array(offer.formats.enumerated()), id: \.offset) { _, format in
                                Button(format.title) { model.copy(format) }
                            }
                        }
                    } else {
                        Button(String(localized: "Copy All", bundle: .previewKit, comment: "Copy menu item: copies all of the file's text.")) { model.copy() }
                    }
                    if !(offer?.formats.contains(where: \.isImage) ?? false) {
                        Button(String(localized: "Copy as Image", bundle: .previewKit, comment: "Copy menu item: copies a picture of the preview as drawn.")) { model.copyImage() }
                    }
                    if model.canExport {
                        Divider()
                        // PDF and HTML where the page holds the whole document (Markdown); every other preview draws only
                        // what is in view (long code, big tables), so it offers the picture alone.
                        if model.canExportHTML {
                            Button(String(localized: "Export as PDF…", bundle: .previewKit, comment: "Copy menu item: saves the preview as a PDF.")) { model.export(.pdf) }
                            Button(String(localized: "Export as HTML…", bundle: .previewKit, comment: "Copy menu item: saves the document as one HTML page.")) { model.export(.html) }
                        }
                        Button(String(localized: "Export as PNG…", bundle: .previewKit, comment: "Copy menu item: saves a picture of the preview.")) { model.export(.png) }
                    }
                } label: {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc").font(.system(size: 12.5))
                        .foregroundStyle(model.copied ? Color.token("ok-text") : Color.token("t2"))
                        .frame(width: 26, height: 24)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(model.copied ? Self.copiedHelp
                      : String(localized: "Copy as…", bundle: .previewKit, comment: "Capsule button tooltip: opens the Copy as menu."))
                .accessibilityLabel(Text("Copy as", bundle: .previewKit, comment: "Accessibility label of the Copy as menu button."))
            }
            if (!model.openInApps.isEmpty || model.canReveal) && !model.hidesWindowActions {
                Menu {
                    ForEach(model.openInApps) { app in
                        Button(app.isDefault
                               ? String(localized: "\(app.name) (default)", bundle: .previewKit,
                                        comment: "Open in menu: the app that opens this file by default.")
                               : app.name) { model.open(in: app) }
                    }
                    if model.canReveal {
                        Divider()
                        Button(String(localized: "Reveal in Finder", bundle: .previewKit, comment: "Open in menu: shows the file in a Finder window.")) { model.reveal() }
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12.5)).foregroundStyle(Color.token("t2"))
                        .frame(width: 26, height: 24)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(String(localized: "Open in…", bundle: .previewKit, comment: "Capsule button tooltip: opens the file in another app."))
                .accessibilityLabel(Text("Open in", bundle: .previewKit, comment: "Accessibility label of the Open in menu button."))
            }
            if model.canShowDisplayOptions {
                CapsuleButton(symbol: "ellipsis",
                              help: String(localized: "Theme, font, wrap, line numbers", bundle: .previewKit,
                                           comment: "Capsule More button tooltip: the display options it opens.")) {
                    model.showDisplayOptions()
                }
            }
            if model.canToggleInspector && !model.hidesWindowActions {
                CapsuleButton(symbol: model.inspectorSymbol, help: model.inspectorHelp) { model.toggleInspector() }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: height)
        .modifier(GlassCapsule(solid: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Preview controls", bundle: .previewKit, comment: "Accessibility label of the capsule under every preview."))
    }

    private static var copiedHelp: String {
        String(localized: "Copied", bundle: .previewKit, comment: "Capsule copy button tooltip for a moment after copying.")
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.token(model.dotToken)).frame(width: 7, height: 7)
            if !compact, model.strip.show != .never, !model.pillText.isEmpty {
                Text(model.pillText).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: Metric.value("fs-control")))
        // I-13: quiet until the pointer is over the pill, unless the strip is set to Always.
        .foregroundStyle(Color.token(model.strip.show == .hover && !pillHovered ? "t2" : "t1"))
        .onHover { pillHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: pillHovered)
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: Metric.value(compact ? "h-pill-compact" : "h-pill"))
        .background(Color.token("fill"), in: Capsule())
        .help(model.pillDetail)
        .accessibilityLabel(model.pillText)
    }

    private var divider: some View {
        Rectangle().fill(Color.token("hair")).frame(width: 0.5, height: 20).padding(.horizontal, 4)
    }
}

/// The capsule's find field (chrome 4): every match marked, "3 of 12", Return for the next, Shift-Return for the
/// previous, Escape to close. Typing searches as you go.
private struct FindField: View {
    @Bindable var model: CapsuleModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.token("t2"))
            if model.findModes.count > 1 {
                // The mode badge doubles as the switch (data 1, I-8): Filter or SQL. roadmap: S-6
                Menu {
                    Button(model.plainModeTitle) { if let first = model.findModes.first { model.setFindMode(first) } }
                    Button(String(localized: "Query with \(model.queryLanguage) (read-only)", bundle: .previewKit,
                                  comment: "Find mode menu item; the argument is the query language, SQL or jq.")) { model.setFindMode(.query) }
                } label: { ModeBadge(title: model.findModeTitle, menu: true) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help(String(localized: "\(model.plainModeTitle), or query with \(model.queryLanguage)", bundle: .previewKit,
                                 comment: "Find mode badge tooltip: the plain mode ('Filter rows' or 'Find'), then the query language."))
                    .accessibilityLabel(Text("Find mode: \(model.findModeTitle)", bundle: .previewKit,
                                             comment: "Accessibility label of the find mode badge; the argument is the mode."))
            } else if model.findStyle == .filter {
                ModeBadge(title: String(localized: "Filter", bundle: .previewKit, comment: "Find field mode badge: keep only the matching rows."),
                          menu: false)
            }
            if let prefix = model.findPrefix {
                // A typed prefix becomes an 18 pt badge in the field (code state 1).
                ModeBadge(title: prefix.token, menu: false).help(prefix.title)
            }
            TextField(placeholder, text: $model.findQuery)
                .textFieldStyle(.plain)
                .font(model.findStyle == .query ? .system(size: Metric.value("fs-control"), design: .monospaced)
                                                : .system(size: Metric.value("fs-control")))
                .frame(minWidth: model.findStyle == .query ? 260 : 150)
                .focused($focused)
                .onChange(of: model.findQuery) { model.takePrefix(); Task { await model.find() } }
                .onKeyPress(.delete) { model.dropPrefix() ? .handled : .ignored }
                .onKeyPress(.return, phases: .down) { press in
                    if model.findStyle == .query { Task { await model.runQuery() } }
                    else { Task { await model.find(forward: !press.modifiers.contains(.shift)) } }
                    return .handled
                }
                .onKeyPress(.escape) { model.closeFind(); return .handled }
                .accessibilityLabel(Text("Find", bundle: .previewKit, comment: "Accessibility label of the find field."))
            if let failure = model.queryFailure {
                // The query's own words (SQL's or jq's), cut in the middle when long; the whole message on hover.
                Text(failure).font(.system(size: Metric.value("fs-sub"))).foregroundStyle(Color.token("t2"))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420, alignment: .trailing)
                    .help(failure)
                    .accessibilityLabel(Text("Didn't run: \(failure)", bundle: .previewKit,
                                             comment: "Accessibility label when a query failed; the argument is the engine's own error text."))
            } else if let count = model.findCountText {
                Text(count).font(.system(size: Metric.value("fs-sub"))).foregroundStyle(Color.token("t2"))
                    .fixedSize().accessibilityLabel(count)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.token("fld"), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.token("hair"), lineWidth: 0.5))
        .onAppear { focused = true }
        if model.findStyle == .query {
            Button { Task { await model.runQuery() } } label: {
                Text("Run", bundle: .previewKit, comment: "Find field button: runs the typed query.")
            }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.token("accent"))
                .padding(.horizontal, 6)
                .frame(height: 22)
                .help(String(localized: "Run the query, read-only (↩)", bundle: .previewKit, comment: "Tooltip of the Run button."))
        }
        if model.findStyle == .filter || model.findStyle == .query {
            Button { model.closeFind() } label: {
                Text("Done", bundle: .previewKit, comment: "Find field button: closes a filter or query and shows every row.")
            }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.token("t1"))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .help(String(localized: "Show every row again (esc)", bundle: .previewKit, comment: "Tooltip of the Done button."))
        } else {
            if model.canFoldToMatches, model.findPrefix == nil, (model.findResult?.count ?? 0) > 0 {
                Button(model.foldedToMatches
                       ? String(localized: "Unfold", bundle: .previewKit, comment: "Find field button: shows every line again after folding.")
                       : String(localized: "Fold to matches", bundle: .previewKit, comment: "Find field button: hides the lines away from the matches.")) {
                    model.toggleFoldToMatches()
                }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.token("accent"))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .help(String(localized: "Hide the lines away from every match", bundle: .previewKit,
                                 comment: "Tooltip of the Fold to matches button."))
            }
            CapsuleButton(symbol: "chevron.up",
                          help: String(localized: "Previous match (⇧↩)", bundle: .previewKit, comment: "Find field button tooltip.")) {
                Task { await model.find(forward: false) }
            }
            CapsuleButton(symbol: "chevron.down",
                          help: String(localized: "Next match (↩)", bundle: .previewKit, comment: "Find field button tooltip.")) {
                Task { await model.find(forward: true) }
            }
            CapsuleButton(symbol: "xmark",
                          help: String(localized: "Close find (esc)", bundle: .previewKit, comment: "Find field button tooltip.")) {
                model.closeFind()
            }
        }
    }

    private var placeholder: String {
        switch model.findStyle {
        case .filter: String(localized: "Filter rows", bundle: .previewKit, comment: "Find mode menu item: filter a table's rows.")
        // A sample query, code: never translated.
        case .query: model.queryPlaceholder ?? "SELECT * FROM t"
        case .search: model.findPrefixes.isEmpty
            ? String(localized: "Find", bundle: .previewKit, comment: "Find field mode badge: mark and step through matches.")
            : String(localized: "Find  ·  :line  @symbol", bundle: .previewKit,
                     comment: "Find field placeholder: plain find, then the prefixes ':' (go to line) and '@' (symbol). Keep ':' and '@'.")
        }
    }
}

/// The 18 pt accent chip at the find field's start (data 1): "Filter" or "SQL", with a chevron when it opens the
/// mode menu. roadmap: S-6
private struct ModeBadge: View {
    let title: String
    let menu: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            if menu { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
        }
        .font(.system(size: Metric.value("fs-micro"), weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Color.token("accent"), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Rendered / Source (and later Tree, Hex …), as icons with tooltips.
private struct ViewerSwitch: View {
    let model: CapsuleModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.viewTitles.enumerated()), id: \.offset) { index, title in
                let on = index == model.viewIndex
                Button { model.selectView(index) } label: {
                    Image(systemName: Self.symbol(for: title))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: Metric.value("h-ctl-sm"))
                        .foregroundStyle(Color.token(on ? "t1" : "t2"))
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: Metric.value("r-badge")).fill(Color.token("segsel"))
                                    .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.displayTitle(for: title))
                .accessibilityLabel(Self.displayTitle(for: title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.token("fill"), in: RoundedRectangle(cornerRadius: Metric.value("r-row")))
    }

    /// A view's title is its identifier (English, the symbol table's key, and the describe output's word); people see
    /// it in their language (H-6). A title not in the table is shown as it comes.
    static func displayTitle(for title: String) -> String {
        switch title {
        case "Rendered": String(localized: "Rendered", bundle: .previewKit, comment: "Viewer switch: the rendered view (Markdown, notebook).")
        case "Source": String(localized: "Source", bundle: .previewKit, comment: "Viewer switch: the file's source text.")
        case "Code": String(localized: "Code", bundle: .previewKit, comment: "Viewer switch: the syntax-coloured code view.")
        case "XML": String(localized: "XML", bundle: .previewKit, comment: "Viewer switch: the XML source of a file.")
        case "Formatted": String(localized: "Formatted", bundle: .previewKit, comment: "Viewer switch: the re-indented form of a minified file.")
        case "Rows": String(localized: "Rows", bundle: .previewKit, comment: "Viewer switch: a table's rows.")
        case "Table": String(localized: "Table", bundle: .previewKit, comment: "Viewer switch: the table view.")
        case "Text": String(localized: "Text", bundle: .previewKit, comment: "Viewer switch: the plain text view.")
        case "Schema": String(localized: "Schema", bundle: .previewKit, comment: "Viewer switch: a database's schema.")
        case "Tree": String(localized: "Tree", bundle: .previewKit, comment: "Viewer switch: the outline tree of a structured file.")
        case "List": String(localized: "List", bundle: .previewKit, comment: "Viewer switch: a folder as a list.")
        case "Icons": String(localized: "Icons", bundle: .previewKit, comment: "Viewer switch: a folder as icons.")
        case "Hex": String(localized: "Hex", bundle: .previewKit, comment: "Viewer switch: the hex dump.")
        case "Strings": String(localized: "Strings", bundle: .previewKit, comment: "Viewer switch: the readable strings in a binary.")
        case "Scripts": String(localized: "Scripts", bundle: .previewKit, comment: "Viewer switch: an installer's scripts as text.")
        case "Packages": String(localized: "Packages", bundle: .previewKit, comment: "Viewer switch: the packages a lockfile pins, one per line.")
        case "Graph": String(localized: "Graph", bundle: .previewKit, comment: "Viewer switch: how services or jobs depend on each other.")
        case "Outline": String(localized: "Outline", bundle: .previewKit, comment: "Viewer switch: an API's operations, types or fields as an indented list.")
        case "Translations": String(localized: "Translations", bundle: .previewKit, comment: "Viewer switch: a String Catalog's keys with each language's text.")
        case "Frames": String(localized: "Frames", bundle: .previewKit, comment: "Viewer switch: a crash report's crashed-thread stack frames.")
        case "Tracks": String(localized: "Tracks", bundle: .previewKit, comment: "Viewer switch: a map file's tracks with their distances.")
        case "Message": String(localized: "Message", bundle: .previewKit, comment: "Viewer switch: an email's text.")
        case "Waterfall": String(localized: "Waterfall", bundle: .previewKit, comment: "Viewer switch: requests or spans on a timeline.")
        case "Log": String(localized: "Log", bundle: .previewKit, comment: "Viewer switch: the log view of a log file.")
        case "Card": String(localized: "Card", bundle: .previewKit, comment: "Viewer switch: the summary card.")
        case "Unified": String(localized: "Unified", bundle: .previewKit, comment: "Viewer switch: a diff in one column.")
        case "Split": String(localized: "Split", bundle: .previewKit, comment: "Viewer switch: a diff side by side.")
        case "Rich": String(localized: "Rich", bundle: .previewKit, comment: "Viewer switch: a compare that understands the format.")
        case "Tracked": String(localized: "Tracked", bundle: .previewKit, comment: "Viewer switch: prose changes shown as tracked changes.")
        case "Structure": String(localized: "Structure", bundle: .previewKit, comment: "Viewer switch: the structure of a file.")
        case "2-up": String(localized: "2-up", bundle: .previewKit, comment: "Viewer switch: two images side by side.")
        case "Swipe": String(localized: "Swipe", bundle: .previewKit, comment: "Viewer switch: an image compare with a slider.")
        case "Onion skin": String(localized: "Onion skin", bundle: .previewKit, comment: "Viewer switch: one image faded over the other.")
        case "Difference": String(localized: "Difference", bundle: .previewKit, comment: "Viewer switch: the pixels that differ.")
        case "Contents": String(localized: "Contents", bundle: .previewKit, comment: "Viewer switch: what an archive or bundle contains.")
        case "Files": String(localized: "Files", bundle: .previewKit, comment: "Viewer switch: the files of a patch or archive.")
        case "Photo": String(localized: "Photo", bundle: .previewKit, comment: "Viewer switch: the photo itself.")
        case "Image": String(localized: "Image", bundle: .previewKit, comment: "Viewer switch: the image itself.")
        case "Glyphs": String(localized: "Glyphs", bundle: .previewKit, comment: "Viewer switch: a font's glyphs.")
        case "Conversation": String(localized: "Conversation", bundle: .previewKit, comment: "Viewer switch: a chat transcript as a conversation.")
        case "Changes": String(localized: "Changes", bundle: .previewKit, comment: "Viewer switch: the changes in a file.")
        case "Info": String(localized: "Info", bundle: .previewKit, comment: "Viewer switch: facts about the file.")
        case "Outputs": String(localized: "Outputs", bundle: .previewKit, comment: "Viewer switch: a notebook compare's cell outputs.")
        case "Picture": String(localized: "Picture", bundle: .previewKit, comment: "Viewer switch: an SVG drawn as a picture.")
        case "Notebook": String(localized: "Notebook", bundle: .previewKit, comment: "Viewer switch: a Jupyter notebook drawn as a notebook.")
        case "Code only": String(localized: "Code only", bundle: .previewKit, comment: "Viewer switch: only a notebook's code cells.")
        case "Agent view": String(localized: "Agent view", bundle: .previewKit, comment: "Viewer switch: what an AI agent makes of a rules file (when it fires, its tokens, imports and commands).")
        default: title
        }
    }

    static func symbol(for title: String) -> String {
        switch title {
        case "Rendered": "eye"
        case "Agent view": "sparkles"
        case "Source", "Code", "XML": "chevron.left.forwardslash.chevron.right"
        case "Formatted": "text.alignleft"
        case "Rows", "Table": "tablecells"
        case "Text": "text.alignleft"
        case "Schema": "list.bullet.rectangle"
        case "Tree": "list.bullet.indent"
        case "List": "list.bullet"
        case "Icons": "square.grid.2x2"
        case "Hex": "number"
        case "Strings": "textformat.abc"
        case "Scripts": "terminal"
        case "Packages": "shippingbox"
        case "Graph": "point.3.connected.trianglepath.dotted"
        case "Outline": "list.bullet.indent"
        case "Translations": "character.bubble"
        case "Frames": "list.number"
        case "Tracks": "point.topleft.down.to.point.bottomright.curvepath"
        case "Message": "envelope"
        case "Waterfall": "chart.bar.doc.horizontal"
        case "Log": "text.line.first.and.arrowtriangle.forward"
        case "Card": "rectangle.portrait"
        case "Unified": "text.justify.leading"
        case "Split": "rectangle.split.2x1"
        case "Rich", "Tracked": "doc.richtext"
        case "Structure": "list.bullet.indent"
        case "2-up": "square.split.2x1"
        case "Swipe": "slider.horizontal.below.rectangle"
        case "Onion skin": "square.stack"
        case "Difference": "circle.lefthalf.filled"
        case "Contents", "Files": "list.bullet.indent"
        case "Photo", "Image": "photo"
        case "Glyphs": "textformat"
        case "Conversation": "bubble.left.and.bubble.right"
        case "Changes": "plusminus"
        case "Info": "info.circle"
        default: "square.grid.2x2"
        }
    }
}

private struct CapsuleButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(tint ?? Color.token("t2"))
                .frame(width: 26, height: 24)
                .background(hover ? Color.token("fill") : .clear, in: RoundedRectangle(cornerRadius: Metric.value("r-ctl")))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Liquid Glass on macOS 26 and later; the system's glass token on earlier systems; the solid twin
/// (`glass-solid`) when Reduce Transparency is on.
private struct GlassCapsule: ViewModifier {
    let solid: Bool

    func body(content: Content) -> some View {
        if solid {
            content.background(Color.token("glass-solid"), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.token("hair"), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.token("hair"), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 13, y: 8)
        }
    }
}
