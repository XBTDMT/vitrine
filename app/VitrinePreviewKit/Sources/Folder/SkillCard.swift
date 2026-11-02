import AppKit
import VitrineUI

/// A Claude Code or Codex skill folder (P-5): `SKILL.md` with `name` and `description` in its front matter, or a
/// folder of agent instructions (`AGENTS.md`, `CLAUDE.md`). What it ships is listed, bounded; scripts are named
/// because a skill can run them. Read from the files alone; nothing runs. roadmap: S-9
struct SkillInfo: Sendable, Equatable {
    enum Source: String, Sendable { case skill = "SKILL.md", agents = "AGENTS.md", claude = "CLAUDE.md" }

    let source: Source
    /// Every instruction file found, `SKILL.md` first.
    let files: [String]
    let name: String
    let description: String?
    /// Files the folder ships (not folders), up to `maxListed`.
    let fileCount: Int
    let countComplete: Bool
    /// Relative paths of the scripts it ships: in `scripts/`, executable, or a script's extension.
    let scripts: [String]

    static let maxListed = 2_000
    static let maxInstructionBytes = 64 << 10
    static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "command", "py", "rb", "pl", "js", "mjs", "cjs", "ts",
                                                "ps1", "applescript", "scpt"]

    /// Nil when the folder holds none of the instruction files.
    static func read(_ folder: URL) -> SkillInfo? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        func find(_ wanted: String) -> String? { names.first { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
        let found = [Source.skill, .agents, .claude].compactMap { s in find(s.rawValue).map { (s, $0) } }
        guard let (source, file) = found.first else { return nil }
        let text = readText(folder.appendingPathComponent(file))
        var name = folder.lastPathComponent
        var description: String?
        if source == .skill, let front = frontMatter(text) {
            if let n = front["name"], !n.isEmpty { name = n }
            description = front["description"].flatMap { $0.isEmpty ? nil : $0 }
        }
        if description == nil { description = firstParagraph(text) }
        var count = 0, complete = true
        var scripts: [String] = []
        // The walker hands back resolved paths (/private/var/… for /var/…): measure from the resolved folder.
        let base = folder.resolvingSymlinksInPath().pathComponents.count
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let url = walker.nextObject() as? URL {
                if walker.level > 4 { walker.skipDescendants(); continue }
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
                guard v?.isRegularFile == true else { continue }
                count += 1
                if count > maxListed { complete = false; count = maxListed; break }
                let rel = url.resolvingSymlinksInPath().pathComponents.dropFirst(base).joined(separator: "/")
                let ext = url.pathExtension.lowercased()
                if rel.hasPrefix("scripts/") || rel.hasPrefix("bin/") || v?.isExecutable == true || scriptExtensions.contains(ext) { scripts.append(rel) }
            }
        }
        return SkillInfo(source: source, files: found.map(\.1), name: name, description: description, fileCount: count,
                         countComplete: complete, scripts: scripts.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    static func readText(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxInstructionBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The `---` block at the top: `key: value` lines, quotes removed, folded (`>`, `|`) and indented continuation
    /// lines joined with spaces.
    static func frontMatter(_ text: String) -> [String: String]? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var out: [String: String] = [:]
        var key: String?
        for line in lines[..<end] {
            if let k = key, line.first == " " || line.first == "\t" {
                let more = line.trimmingCharacters(in: .whitespaces)
                out[k] = ((out[k] ?? "") + " " + more).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(v) { v = "" }
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
            out[k] = v
            key = k
        }
        return out
    }

    /// The first paragraph of prose after the front matter: no headings, lists, quotes or code.
    static func firstParagraph(_ text: String) -> String? {
        var body = Substring(text)
        if text.hasPrefix("---"), let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            body = text[close.upperBound...]
        }
        var paragraph: [String] = []
        var inCode = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode { continue }
            if line.isEmpty { if !paragraph.isEmpty { break } else { continue } }
            if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("<") || line.hasPrefix("|") {
                if !paragraph.isEmpty { break } else { continue }
            }
            paragraph.append(line)
        }
        let joined = paragraph.joined(separator: " ").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return joined.isEmpty ? nil : String(joined.prefix(400))
    }

    /// "Skill", "Codex agent instructions", "Claude Code instructions".
    var badge: String {
        switch source {
        case .skill: String(localized: "Skill", bundle: .previewKit, comment: "Badge on a folder holding an AI agent skill (SKILL.md).")
        case .agents: String(localized: "Agent instructions", bundle: .previewKit, comment: "Badge on a folder holding AGENTS.md instructions for AI coding agents.")
        case .claude: String(localized: "Claude Code instructions", bundle: .previewKit, comment: "Badge on a folder holding CLAUDE.md instructions. Keep “Claude Code”.")
        }
    }

    /// "12 files · 3 scripts" (a floor when the listing stopped).
    var shipsLine: String {
        let files = fileCount.formatted()
        var parts: [String]
        switch (countComplete, fileCount == 1) {
        case (true, true): parts = [String(localized: "\(files) file", bundle: .previewKit, comment: "Skill card: the folder ships one file.")]
        case (true, false): parts = [String(localized: "\(files) files", bundle: .previewKit, comment: "Skill card: how many files the folder ships.")]
        case (false, true): parts = [String(localized: "at least \(files) file", bundle: .previewKit, comment: "Skill card: the folder ships at least one file (the listing stopped early).")]
        case (false, false): parts = [String(localized: "at least \(files) files", bundle: .previewKit, comment: "Skill card: the folder ships at least this many files (the listing stopped early).")]
        }
        if !scripts.isEmpty {
            let count = scripts.count.formatted()
            parts.append(scripts.count == 1
                ? String(localized: "\(count) script", bundle: .previewKit, comment: "Skill card: the folder ships one script.")
                : String(localized: "\(count) scripts", bundle: .previewKit, comment: "Skill card: how many scripts the folder ships."))
        }
        return parts.joined(separator: " · ")
    }
}

/// The skill header card above the outline (`.rcard` style on a `win` band): an AI kind tile, the name with its
/// badge, the description in two lines, then what it ships with the scripts in the caution colours.
/// roadmap: S-9
@MainActor
final class SkillCard: NSView {
    let info: SkillInfo
    static let shownScripts = 4

    init(info: SkillInfo) {
        self.info = info
        super.init(frame: .zero)
        let band = FillView("win", bottomRule: true)
        let card = CardBox()
        let tile = TileView(symbol: "sparkles", token: "kind-ai")
        let title = NSTextField(labelWithString: info.name)
        title.font = .systemFont(ofSize: Metric.value("fs-title3"), weight: .semibold)
        title.textColor = NSColor.token("t1")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = PillLabel(symbol: nil, text: info.badge, textToken: "t2", height: Metric.value("h-badge"), radius: Metric.value("r-badge"),
                              font: .systemFont(ofSize: Metric.value("fs-caption"), weight: .semibold), padding: 6)
        let source = NSTextField(labelWithString: info.files.joined(separator: " · "))
        source.font = .monospacedSystemFont(ofSize: Metric.value("fs-mono-xs"), weight: .regular)
        source.textColor = NSColor.token("t3")
        let head = NSStackView(views: [title, badge, NSView(), source])
        head.spacing = 8
        let description = NSTextField(wrappingLabelWithString: info.description
            ?? String(localized: "No description", bundle: .previewKit, comment: "Skill card: the skill gives no description."))
        description.font = .systemFont(ofSize: Metric.value("fs-control"))
        description.textColor = NSColor.token(info.description == nil ? "t3" : "t2")
        description.maximumNumberOfLines = 2
        description.lineBreakMode = .byTruncatingTail
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        description.preferredMaxLayoutWidth = 400
        var strip: [NSView] = [Self.small(info.shipsLine, token: "t2")]
        for script in info.scripts.prefix(Self.shownScripts) {
            let b = PillLabel(symbol: "terminal", text: script, textToken: "caution-text", fill: "caution-soft", height: Metric.value("h-badge"),
                              radius: Metric.value("r-badge"), font: .monospacedSystemFont(ofSize: Metric.value("fs-mono-xs"), weight: .medium), padding: 6)
            b.toolTip = String(localized: "A script this folder ships: it can run code when the skill or agent uses it", bundle: .previewKit, comment: "Tooltip of a script badge on the skill card.")
            strip.append(b)
        }
        if info.scripts.count > Self.shownScripts {
            let more = (info.scripts.count - Self.shownScripts).formatted()
            strip.append(Self.small(String(localized: "+\(more) more", bundle: .previewKit, comment: "Skill card: how many more scripts are not shown."), token: "caution-text"))
        }
        let ships = NSStackView(views: strip)
        ships.spacing = 6
        for v in strip { v.setContentCompressionResistancePriority(.init(300), for: .horizontal) }
        let text = NSStackView(views: [head, description, ships])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(8, after: description)
        wantsLayer = true
        layer?.masksToBounds = true
        for v in [band, card] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [tile, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        // The card wants its words' height below the overview's wish (490) and the list's minimum (495): in a short
        // panel it is the first to give way, cut inside its rounded box.
        let fit = text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        fit.priority = .init(485)
        NSLayoutConstraint.activate([
            fit, card.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            band.topAnchor.constraint(equalTo: topAnchor), band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor), band.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 10), card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            tile.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), tile.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            head.widthAnchor.constraint(equalTo: text.widthAnchor), description.widthAnchor.constraint(equalTo: text.widthAnchor),
            ships.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
        descriptionLabel = description
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let badgeText = info.badge, name = info.name, about = info.description ?? "", shipsText = info.shipsLine
        setAccessibilityLabel(String(localized: "\(badgeText): \(name). \(about). Ships \(shipsText).", bundle: .previewKit, comment: "Accessibility label of the skill card. Arguments: badge, name, description, what it ships."))
    }

    required init?(coder: NSCoder) { nil }

    /// A wrapping label needs a fixed wrap width: without one its height and width chase each other and layout
    /// never settles (the snapshot spun on it).
    override func layout() {
        super.layout()
        guard let label = descriptionLabel else { return }
        let width = label.frame.width
        if width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 { label.preferredMaxLayoutWidth = width }
    }

    private weak var descriptionLabel: NSTextField?

    private static func small(_ text: String, token: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: Metric.value("fs-caption"))
        l.textColor = NSColor.token(token)
        return l
    }
}

/// A 28 pt rounded kind tile with a white symbol (the cards' kind tile, flat). roadmap: S-9
@MainActor
final class TileView: NSView {
    private let token: String

    init(symbol: String, token: String, size: CGFloat = 28) {
        self.token = token
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token(token).cgColor }
}
