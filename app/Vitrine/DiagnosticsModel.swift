import Foundation

// The Diagnostics window's model (S-10; parity B-8 and H-4): what each Quick Look tool printed, parsed into values,
// and the rule that names which previewer answers for each file type Vitrine claims. Foundation only and free of
// side effects, so the tests compile this file directly and feed it recorded tool output; the live side (running
// pluginkit and qlmanage, making test files, the repair actions) is DiagnosticsProbe.swift and DiagnosticsRepair.swift.

// MARK: - pluginkit

/// One line of `pluginkit -m -v [-A -D] -p com.apple.quicklook.preview`.
struct PluginRecord: Equatable, Sendable {
    /// The user election tag pluginkit prints first (pluginkit(8), "-m"): `+` use, `-` ignore, `!` debug use,
    /// `=` superseded by another plug-in, `?` unknown, and nothing when the user never chose (the default).
    enum Election: String, Sendable { case use = "+", ignore = "-", debug = "!", superseded = "=", unknown = "?", none = " " }

    let election: Election
    let identifier: String
    let version: String
    let uuid: String?
    let timestamp: String?
    let path: String?

    /// Quick Look may ask this copy: everything except an explicit ignore or a superseded copy.
    var isEligible: Bool { election != .ignore && election != .superseded }
    /// The `.app` that holds this `.appex`, read from the path (`…/X.app/Contents/PlugIns/Y.appex`).
    var parentAppPath: String? {
        guard let path, let r = path.range(of: ".app/Contents/PlugIns/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}

enum PluginKitParser {
    /// Lines look like `+    io.example.ext(1.2)\t<UUID>\t2026-10-30 23:06:22 +0000\t/path/X.appex`; without `-v`
    /// only the first field is printed, and the summary line ` (22 plug-ins)` is skipped.
    static func records(from output: String) -> [PluginRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { record(from: String($0)) }
    }

    static func record(from line: String) -> PluginRecord? {
        guard let first = line.first else { return nil }
        let election = PluginRecord.Election(rawValue: String(first)) ?? .none
        let body = election == .none && first != " " ? Substring(line) : line.dropFirst()
        let fields = body.split(separator: "\t", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = fields.first, let open = head.lastIndex(of: "("), head.hasSuffix(")"), open > head.startIndex else { return nil }
        let identifier = String(head[..<open])
        guard !identifier.isEmpty, !identifier.contains(" ") else { return nil }
        let version = String(head[head.index(after: open)..<head.index(before: head.endIndex)])
        func field(_ i: Int) -> String? { fields.count > i && !fields[i].isEmpty ? fields[i] : nil }
        return PluginRecord(election: election, identifier: identifier, version: version,
                            uuid: field(1), timestamp: field(2), path: field(3))
    }
}

// MARK: - qlmanage

enum QuickLookParser {
    /// `qlmanage -m plugins` lists macOS's own previewers as `  public.json -> /System/Library/QuickLook/Text.qlgenerator (1114.1.11)`.
    /// Returns content type → generator path.
    static func generators(from output: String) -> [String: String] {
        var map: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let arrow = line.range(of: " -> ") else { continue }
            let type = String(line[..<arrow.lowerBound])
            var path = String(line[arrow.upperBound...])
            if let paren = path.range(of: " (", options: .backwards) { path = String(path[..<paren.lowerBound]) }
            guard !type.isEmpty, !type.contains(" ") else { continue }
            map[type] = path
        }
        return map
    }

    /// What `qlmanage -p -o <dir> <files>` said for one file. In output mode qlmanage only writes what macOS's own
    /// previewers draw; a file a Quick Look app extension answers for "did not produce any preview" (measured
    /// 2026-10-30 on macOS 27.2: .csv, .svg, .txt, .html and .ts produced one, .json, .md and .swift did not, matching
    /// what the real panel shows).
    enum ProbeLine: Equatable, Sendable {
        /// macOS drew it; `kind` is the type of what it drew (`public.html`, `public.plain-text` …).
        case produced(kind: String)
        case nothing
    }

    /// Parses `* /tmp/…/t12.csv produced a preview with data of type public.html` and
    /// `* /tmp/…/t3.json did not produce any preview` into file name → answer.
    static func probeLines(from output: String) -> [String: ProbeLine] {
        var map: [String: ProbeLine] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.hasPrefix("* ") else { continue }
            let body = line.dropFirst(2)
            if let r = body.range(of: " did not produce any preview") {
                map[fileName(String(body[..<r.lowerBound]))] = .nothing
            } else if let r = body.range(of: " produced a preview") {
                let tail = body[r.upperBound...]
                let kind = tail.range(of: " of type ").map { String(tail[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                map[fileName(String(body[..<r.lowerBound]))] = .produced(kind: kind)
            }
        }
        return map
    }

    private static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }
}

// MARK: - Extensions on this Mac

/// A Quick Look preview extension as macOS knows it: its pluginkit record plus the types its Info.plist claims.
struct InstalledExtension: Equatable, Sendable {
    enum Maker: Equatable, Sendable { case vitrine, apple, other }

    let record: PluginRecord
    let displayName: String
    /// The containing app's name and version, for the "Inkwell Markdown 3.2" wording.
    let appName: String
    let appVersion: String
    let claims: [String]

    var identifier: String { record.identifier }
    var maker: Maker { Self.maker(of: record.identifier, path: record.path) }

    static let vitrinePrefixes = ["io.github.xbtdmt.vitrine.quicklook.", "com.xbtdmt.spacebar.quicklook."]

    static func maker(of identifier: String, path: String?) -> Maker {
        if vitrinePrefixes.contains(where: identifier.hasPrefix) { return .vitrine }
        if identifier.hasPrefix("com.apple.") || (path ?? "").hasPrefix("/System/") { return .apple }
        return .other
    }

    /// `QLSupportedContentTypes` from an extension's Info.plist dictionary.
    static func claims(fromInfo info: [String: Any]) -> [String] {
        let ext = info["NSExtension"] as? [String: Any]
        let attrs = ext?["NSExtensionAttributes"] as? [String: Any]
        return attrs?["QLSupportedContentTypes"] as? [String] ?? []
    }
}

// MARK: - Kinds

/// A kind is how the window groups Vitrine's claimed types: "Markdown", "Source code", "CSV". The catalogue names
/// every type `Config/uti-table.json` lists (a test keeps the two in step); a claimed type missing here still shows,
/// under a kind named for its extension family.
struct DiagnosticKind: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// Design token for the row's tile: `kind-text`, `kind-code`, `kind-data` …
    let tile: String
    /// SF Symbol drawn on the tile.
    let symbol: String
    let types: [String]
    /// A fixed subtitle, when the extensions would not say it (filename-only kinds).
    let subtitle: String?

    init(_ id: String, _ name: String, tile: String, symbol: String, subtitle: String? = nil, _ types: [String]) {
        self.id = id; self.name = name; self.tile = tile; self.symbol = symbol; self.subtitle = subtitle; self.types = types
    }

    static let v = "io.github.xbtdmt.vitrine."

    /// Kind names are marked for translation (S-12, parity H-6), except the ones that are only format names
    /// (Markdown, SVG, JSON …), which stay as written in every language.
    static let catalogue: [DiagnosticKind] = [
        DiagnosticKind("markdown", "Markdown", tile: "kind-text", symbol: "text.document",
                 ["net.daringfireball.markdown", "public.markdown", "org.textbundle.package"]),
        DiagnosticKind("markdown-flavours", "MDX, Quarto, R Markdown", tile: "kind-text", symbol: "text.document",
                 [v + "mdx", v + "mdc", v + "qmd", v + "rmd"]),
        DiagnosticKind("markup", "reStructuredText, AsciiDoc, Org", tile: "kind-text", symbol: "text.alignleft",
                 ["org.python.restructuredtext", "org.asciidoc.asciidoc", "org.orgmode.org"]),
        DiagnosticKind("svg", "SVG", tile: "kind-image", symbol: "photo", ["public.svg-image"]),
        DiagnosticKind("typescript", "TypeScript", tile: "kind-code", symbol: "chevron.left.forwardslash.chevron.right",
                 ["com.microsoft.typescript"]),
        DiagnosticKind("code", String(localized: "Source code", comment: "Diagnostics: a kind of file"), tile: "kind-code", symbol: "chevron.left.forwardslash.chevron.right", [
            "public.swift-source", "public.objective-c-source", "public.objective-c-plus-plus-source", "public.c-header",
            "public.c-plus-plus-header", "public.c-source", "public.c-plus-plus-source", "public.python-script",
            "public.ruby-script", "public.php-script", "public.perl-script", "public.shell-script", "public.bash-script",
            "public.zsh-script", "org.lua", "com.netscape.javascript-source", "public.jsx-source",
            "com.microsoft.typescript.tsx", "com.sun.java-source", "org.kotlinlang.kotlin-source", "org.golang.go-source",
            "org.rust-lang.rust-source", "com.sass-lang.sass", "org.iso.sql", "com.google.dart-source",
            "org.scala-lang.scala-source", "org.haskell.haskell-source", "org.clojure.clojure-source",
            "org.elixir-lang.elixir-source", "org.ocaml.ocaml-source", "net.common-lisp.lisp", "com.microsoft.fsharp-source",
            "org.lesscss.less", "org.latex-project.latex", "org.vuejs.vue", "com.microsoft.csharp-source",
            "org.r-project.r-source", "org.codehaus.groovy-source", "org.erlang.erlang-source", "com.apple.applescript.text",
            "public.assembly-source"]),
        DiagnosticKind("config", String(localized: "Config, logs and .env", comment: "Diagnostics: a kind of file; keep .env as written"), tile: "kind-code", symbol: "gearshape",
                 [v + "env", v + "conf", v + "properties", v + "log", v + "nfo", "com.apple.log"]),
        DiagnosticKind("patch", String(localized: "Patches", comment: "Diagnostics: a kind of file (diff and patch files)"), tile: "kind-code", symbol: "plusminus", [v + "patch", "public.patch-file"]),
        DiagnosticKind("notebooks", String(localized: "Jupyter notebooks", comment: "Diagnostics: a kind of file"), tile: "kind-ai", symbol: "book.pages", [v + "ipynb"]),
        DiagnosticKind("jsonl", String(localized: "JSON Lines and agent sessions", comment: "Diagnostics: a kind of file; JSON Lines is a format name"), tile: "kind-ai", symbol: "bubble.left.and.bubble.right", [v + "jsonl"]),
        DiagnosticKind("web-fonts", String(localized: "Web fonts", comment: "Diagnostics: a kind of file"), tile: "kind-text", symbol: "textformat", [v + "woff", v + "woff2"]),
        DiagnosticKind("apng", String(localized: "Animated PNG", comment: "Diagnostics: a kind of file"), tile: "kind-image", symbol: "photo", [v + "apng"]),
        DiagnosticKind("json", "JSON", tile: "kind-data", symbol: "curlybraces", ["public.json"]),
        DiagnosticKind("yaml", "YAML", tile: "kind-data", symbol: "curlybraces", ["public.yaml"]),
        DiagnosticKind("toml", "TOML", tile: "kind-data", symbol: "curlybraces", ["public.toml", "io.toml"]),
        DiagnosticKind("xml", String(localized: "XML and property lists", comment: "Diagnostics: a kind of file"), tile: "kind-data", symbol: "chevron.left.slash.chevron.right",
                 ["public.xml", "com.apple.property-list", "com.apple.xml-property-list", "com.apple.binary-property-list"]),
        DiagnosticKind("csv", "CSV", tile: "kind-data", symbol: "tablecells", ["public.comma-separated-values-text", v + "csv"]),
        DiagnosticKind("tsv", "TSV", tile: "kind-data", symbol: "tablecells", ["public.tab-separated-values-text", v + "tsv"]),
        DiagnosticKind("sqlite", "SQLite", tile: "kind-data", symbol: "cylinder", ["org.sqlite.database", v + "sqlite"]),
        DiagnosticKind("columnar", String(localized: "Parquet and Arrow", comment: "Diagnostics: a kind of file; Parquet and Arrow are format names"), tile: "kind-data", symbol: "tablecells", [v + "parquet", v + "arrow", v + "arrows", v + "feather"]),
        DiagnosticKind("xlsx", String(localized: "Excel workbooks", comment: "Diagnostics: a kind of file"), tile: "kind-data", symbol: "tablecells", ["org.openxmlformats.spreadsheetml.sheet"]),
        DiagnosticKind("archives", String(localized: "Archives", comment: "Diagnostics: a kind of file (zip, tar …)"), tile: "kind-archive", symbol: "archivebox", [
            "public.zip-archive", "com.pkware.zip-archive", "public.tar-archive", "org.gnu.gnu-zip-archive",
            "public.bzip2-archive", "com.rarlab.rar-archive", "org.7-zip.7-zip-archive", "org.tukaani.xz-archive",
            "org.tukaani.tar-xz-archive", "com.facebook.zstandard-archive", "com.facebook.zstandard-tar-archive",
            "public.lz4-archive", "org.tukaani.lzma-archive", "public.lzip-archive", "public.lzip-tar-archive",
            "public.z-archive", "public.tar-bzip2-archive", "org.gnu.gnu-zip-tar-archive", "public.cpio-archive",
            "com.apple.xar-archive", "com.microsoft.cab", "public.archive.lha"]),
        DiagnosticKind("java-archives", String(localized: "Java archives", comment: "Diagnostics: a kind of file (jar, war, ear)"), tile: "kind-archive", symbol: "archivebox",
                 ["com.sun.java-archive", "com.sun.web-application-archive", v + "ear"]),
        DiagnosticKind("apps", String(localized: "Apps and installers", comment: "Diagnostics: a kind of file"), tile: "kind-app", symbol: "app", [
            "com.apple.application-bundle", "com.apple.installer-package-archive", v + "ipa", "com.apple.itunes.ipa",
            v + "apk", "public.archive.apk", v + "rpm", v + "deb"]),
        DiagnosticKind("profiles", String(localized: "Profiles", comment: "Diagnostics: a kind of file (provisioning and configuration profiles)"), tile: "kind-app", symbol: "checkmark.seal",
                 [v + "provisioningprofile", "com.apple.mobileconfig"]),
        DiagnosticKind("disk-images", String(localized: "Disk images", comment: "Diagnostics: a kind of file (dmg, iso)"), tile: "kind-disk", symbol: "externaldrive",
                 ["com.apple.disk-image", "com.apple.disk-image-udif", v + "iso", "public.iso-image"]),
        DiagnosticKind("torrents", String(localized: "Torrents", comment: "Diagnostics: a kind of file"), tile: "kind-other", symbol: "arrow.down.circle", [v + "torrent", "org.bittorrent.torrent"]),
        DiagnosticKind("keys", String(localized: "Certificates and keys", comment: "Diagnostics: a kind of file (.pem, .cer, .pub)"), tile: "kind-other", symbol: "key",
                       ["public.x509-certificate", v + "csr", v + "ssh-public-key"]),
        DiagnosticKind("folders", String(localized: "Folders", comment: "Diagnostics: a kind of item Vitrine previews"), tile: "kind-folder", symbol: "folder",
                       subtitle: String(localized: "Any folder", comment: "Diagnostics: subtitle of the Folders kind"), ["public.folder"]),
        DiagnosticKind("skills", String(localized: "Agent skill folders", comment: "Diagnostics: a kind of item, folders holding an AI agent skill"), tile: "kind-ai", symbol: "sparkle",
                       subtitle: String(localized: "Folders with a SKILL.md", comment: "Diagnostics: subtitle; SKILL.md is a file name"), [v + "skill"]),
    ]

    /// The catalogue's kinds narrowed to the claimed types, in catalogue order, with any claimed type the catalogue
    /// does not name gathered under "Other <family> types".
    static func kinds(for claimed: [ClaimedType]) -> [DiagnosticKind] {
        let claimedSet = Set(claimed.map(\.uti))
        var named = Set<String>()
        var kinds: [DiagnosticKind] = []
        for kind in catalogue {
            let types = kind.types.filter(claimedSet.contains)
            named.formUnion(kind.types)
            if !types.isEmpty {
                kinds.append(DiagnosticKind(kind.id, kind.name, tile: kind.tile, symbol: kind.symbol, subtitle: kind.subtitle, types))
            }
        }
        var leftovers: [String: [String]] = [:], order: [String] = []
        for c in claimed where !named.contains(c.uti) {
            if leftovers[c.family] == nil { order.append(c.family) }
            if !(leftovers[c.family] ?? []).contains(c.uti) { leftovers[c.family, default: []].append(c.uti) }
        }
        for family in order {
            kinds.append(DiagnosticKind("other-" + family.lowercased(),
                                        String(localized: "Other \(family) types", comment: "Diagnostics: a kind for types no named kind covers; the extension family's name (Code, Data)"),
                                        tile: "kind-other", symbol: "doc", leftovers[family]!))
        }
        return kinds
    }
}

/// One type a Vitrine extension lists in `QLSupportedContentTypes`.
struct ClaimedType: Equatable, Sendable {
    let uti: String
    /// The Vitrine extension that claims it ("io.github.xbtdmt.vitrine.quicklook.code").
    let extensionID: String
    /// Its family name for display ("Code").
    let family: String
}

// MARK: - Who answers Space

/// What Quick Look does for one claimed type today.
enum TypeOwner: Equatable, Sendable {
    /// Vitrine's extension answers.
    case vitrine(extensionID: String)
    /// Another app's extension also claims the type and is switched on. macOS documents no order between two
    /// extensions that claim one type, so this is a conflict whichever answers first; the fix sets the other aside.
    case otherApp(extensionID: String, extensionName: String, appName: String, appVersion: String)
    /// macOS answers with its own previewer, before any extension is asked.
    case macOS(reason: String)
    /// No extension that may answer claims the type, and macOS has nothing of its own: the panel shows macOS's
    /// fallback (the icon and file facts). Happens when the Vitrine extension for it is off or not registered.
    case fallback(extensionID: String)
    /// macOS was not asked: no test file could be made for this type, or the check did not run.
    case notAsked(reason: String)

    enum Category: Int, CaseIterable, Sendable { case vitrine, otherApp, fallback, macOS, notAsked }

    var category: Category {
        switch self {
        case .vitrine: .vitrine
        case .otherApp: .otherApp
        case .fallback: .fallback
        case .macOS: .macOS
        case .notAsked: .notAsked
        }
    }
}

/// What the live probe learned about one claimed type.
struct TypeProbe: Equatable, Sendable {
    let uti: String
    /// The filename extension the test file used (nil for a folder or when none was made).
    let sampleExtension: String?
    /// The type macOS gave the test file; differs from `uti` when macOS reads that extension as something else
    /// (.ts is an MPEG-2 transport stream to macOS, not TypeScript).
    let resolvedType: String?
    /// Whether the test file is a well-formed file of its type, so that macOS's own previewer would accept it.
    let wellFormed: Bool
    /// What qlmanage said; nil when no test file could be made.
    let answer: QuickLookParser.ProbeLine?
    let skippedBecause: String?

    init(uti: String, sampleExtension: String?, resolvedType: String?, wellFormed: Bool,
         answer: QuickLookParser.ProbeLine?, skippedBecause: String? = nil) {
        self.uti = uti; self.sampleExtension = sampleExtension; self.resolvedType = resolvedType
        self.wellFormed = wellFormed; self.answer = answer; self.skippedBecause = skippedBecause
    }
}

/// The rule, in one place (B-8). Inputs are measured: the probe (qlmanage -p -o on a test file), the extensions
/// pluginkit's default discovery returns with their elections and claims, and macOS's own previewers (qlmanage -m).
struct OwnerResolver: Sendable {
    let extensions: [InstalledExtension]
    /// macOS's own previewers: content type → generator path (`qlmanage -m plugins`).
    let generators: [String: String]
    /// `a` conforms to `b` (UTType conformance in the app; a table in tests).
    let conforms: @Sendable (String, String) -> Bool
    /// Human description of a type ("MPEG-2 transport stream").
    let describe: @Sendable (String) -> String?
    /// Every type Vitrine claims. A test file that macOS types as another claimed type (Vitrine's own CSV type and
    /// public.comma-separated-values-text share .csv) is a mirror, not a reservation.
    var vitrineClaims: Set<String> = []

    /// Claims this broad say nothing about a specific type, so they are not counted as a conflict.
    static let tooBroad: Set<String> = ["public.item", "public.data", "public.content", "public.text", "public.plain-text",
                                        "public.directory", "public.folder", "com.apple.package", "public.archive"]

    func owner(of claimed: ClaimedType, probe: TypeProbe?) -> TypeOwner {
        guard let probe else { return .notAsked(reason: Self.notRunYet) }
        guard let answer = probe.answer else {
            var reason = probe.skippedBecause
                ?? String(localized: "No test file could be made for this type, so macOS was not asked.", comment: "Diagnostics: why a file type was not asked")
            if let resolved = probe.resolvedType, resolved != claimed.uti, let ext = probe.sampleExtension,
               !vitrineClaims.contains(resolved), !conforms(resolved, claimed.uti), !conforms(claimed.uti, resolved) {
                let kind = describe(resolved).map(Self.inSentence) ?? resolved
                // A second sentence after the first reason.
                reason += " " + String(localized: "macOS reads .\(ext) files as \(kind).",
                                       comment: "Diagnostics: a filename extension, then the kind of file macOS takes it for (MPEG-2 transport stream)")
            }
            return .notAsked(reason: reason)
        }
        let effective = probe.resolvedType ?? claimed.uti
        if case .produced(let drawn) = answer {
            return .macOS(reason: macReason(claimed: claimed.uti, effective: effective, ext: probe.sampleExtension, drawn: drawn))
        }
        // Nothing drawn by macOS. That proves an extension answers only when macOS's own previewer would have
        // accepted the test file, or when macOS has no previewer of its own for the type at all.
        if !probe.wellFormed, let generator = generator(covering: effective) {
            let name = Self.generatorName(generator)
            return .notAsked(reason: String(localized: "macOS has its own previewer for this kind (\(name)) and a valid test file could not be made, so its answer is unknown.",
                                            comment: "Diagnostics: why a file type was not asked; the name of macOS's own previewer (Text, Web, Office)"))
        }
        let claimants = extensions.filter { $0.record.isEligible && claims($0, effective) }
        if let other = claimants.first(where: { $0.maker == .other }) {
            return .otherApp(extensionID: other.identifier, extensionName: other.displayName,
                             appName: other.appName, appVersion: other.appVersion)
        }
        if let mine = claimants.first(where: { $0.maker == .vitrine }) { return .vitrine(extensionID: mine.identifier) }
        if let apple = claimants.first(where: { $0.maker == .apple }) {
            let name = apple.displayName
            return .macOS(reason: String(localized: "previews it with \(name)", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”"))
        }
        return .fallback(extensionID: claimed.extensionID)
    }

    func claims(_ ext: InstalledExtension, _ type: String) -> Bool {
        ext.claims.contains { claim in claim == type || (!Self.tooBroad.contains(claim) && conforms(type, claim)) }
    }

    func generator(covering type: String) -> String? {
        if let exact = generators[type] { return exact }
        return generators.first { !Self.tooBroad.contains($0.key) && conforms(type, $0.key) }?.value
            ?? generators.first { conforms(type, $0.key) }?.value
    }

    /// Shown when a type has not been checked.
    static var notRunYet: String { String(localized: "The check has not run yet.", comment: "Diagnostics: why a file type was not asked") }

    /// A type's description as it reads inside a sentence: lower case in English ("plain text document"), as macOS
    /// gave it in any other language, where lower-casing would be wrong (German capitalises nouns).
    static func inSentence(_ s: String) -> String {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("en") ? sentenceCase(s) : s
    }

    /// "Plain Text Document" → "plain text document"; words in capitals ("MPEG-2") stay as they are.
    static func sentenceCase(_ s: String) -> String {
        s.split(separator: " ").map { word in
            word.count > 1 && word.dropFirst().contains(where: \.isUppercase) ? String(word) : word.lowercased()
        }.joined(separator: " ")
    }

    static func generatorName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The short why for a type macOS keeps, in the design's register ("reserves .ts for MPEG-2 video streams",
    /// "draws plain text itself", "renders web pages itself").
    func macReason(claimed: String, effective: String, ext: String?, drawn: String) -> String {
        let mirror = vitrineClaims.contains(effective) || conforms(claimed, effective) || conforms(effective, claimed)
        if effective != claimed, !mirror, let ext {
            let kind = describe(effective).map(Self.inSentence) ?? effective
            return String(localized: "reserves .\(ext) for \(kind)", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        }
        // Named by macOS's previewer for the type; without the generator list, by the type itself. What qlmanage
        // drew is no guide (the Office previewer draws CSV as HTML).
        let generator = self.generator(covering: effective).map(Self.generatorName)
            ?? Self.typeFamilies.first { conforms(effective, $0.type) || effective == $0.type }?.generator
        switch generator {
        case "Text": return String(localized: "draws plain text itself", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        case "Web": return String(localized: "renders web pages itself", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        case "Office": return String(localized: "previews spreadsheets and documents itself", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        case "Font": return String(localized: "keeps fonts", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        case "Image": return String(localized: "draws images itself", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        case "Movie", "Audio": return String(localized: "plays media itself", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        case let g?: return String(localized: "previews it itself (\(g))", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        default: return String(localized: "previews it itself", comment: "Diagnostics: why macOS keeps a kind, a phrase whose subject is macOS; shown alone and inside “macOS …, so macOS never asks another app”")
        }
    }

    /// Stand-ins for `qlmanage -m plugins` when it gives nothing, most specific first.
    static let typeFamilies: [(type: String, generator: String)] = [
        ("public.comma-separated-values-text", "Office"), ("public.svg-image", "Web"), ("public.html", "Web"),
        ("public.font", "Font"), ("public.image", "Image"), ("public.movie", "Movie"), ("public.audio", "Audio"),
        ("public.plain-text", "Text"),
    ]
}

// MARK: - Rows the window draws

/// One row of the File Types pane: a kind, or the part of a kind that shares one answer.
struct KindRow: Equatable, Sendable, Identifiable {
    let kind: DiagnosticKind
    /// The types of the kind in this row.
    let types: [String]
    let owner: TypeOwner
    /// Filename extensions of those types, for the subtitle (".md .markdown .textbundle").
    let extensions: [String]
    /// Types of the same kind macOS was not asked about, folded into this row so each kind is counted once.
    var unasked: [(uti: String, reason: String)] = []

    var id: String {
        if case .otherApp(let ext, _, _, _) = owner { return kind.id + "#other#" + ext }
        return kind.id + "#" + String(owner.category.rawValue)
    }

    var subtitle: String {
        let base: String
        let count = types.count
        if let fixed = kind.subtitle { base = fixed }
        else if extensions.isEmpty { base = count == 1 ? types[0] : String(localized: "\(count) types", comment: "Diagnostics: how many file types a row covers") }
        else if extensions.count > 6 {
            let some = extensions.prefix(5).map { "." + $0 }.joined(separator: " ")
            base = String(localized: "\(count) types · \(some) …", comment: "Diagnostics: how many file types a row covers, then the first few filename extensions (.swift .m …)")
        }
        else { base = extensions.map { "." + $0 }.joined(separator: " ") }
        guard !unasked.isEmpty, owner.category != .notAsked else { return base }
        let n = unasked.count
        return String(localized: "\(base) · \(n) not asked", comment: "Diagnostics: a row's subtitle, then how many of its types macOS was not asked about")
    }

    static func == (a: KindRow, b: KindRow) -> Bool {
        a.kind == b.kind && a.types == b.types && a.owner == b.owner && a.extensions == b.extensions
            && a.unasked.map(\.uti) == b.unasked.map(\.uti) && a.unasked.map(\.reason) == b.unasked.map(\.reason)
    }
}

struct FileTypesSummary: Equatable, Sendable {
    let rows: [KindRow]
    let kindCount: Int
    let typeCount: Int

    func rows(_ category: TypeOwner.Category) -> [KindRow] { rows.filter { $0.owner.category == category } }
    func count(_ category: TypeOwner.Category) -> Int { rows(category).count }
    /// Kinds Vitrine could preview here: every row macOS does not keep and that was asked.
    var possible: Int { count(.vitrine) + count(.otherApp) + count(.fallback) }

    /// Builds rows: each kind's types grouped by answer; a kind whose types all share one answer is one row.
    /// Within a kind, other-app answers are kept per app so the fix names the right one. Types not asked are folded
    /// into the kind's first answered row (its subtitle says how many); a kind with no answered type is one
    /// Not asked row.
    static func make(claimed: [ClaimedType], owners: [String: TypeOwner], extensionsOf: (String) -> [String]) -> FileTypesSummary {
        let kinds = DiagnosticKind.kinds(for: claimed)
        var rows: [KindRow] = []
        for kind in kinds {
            var groups: [(TypeOwner, [String])] = []
            var unasked: [(uti: String, reason: String)] = []
            for t in kind.types {
                let owner = owners[t] ?? .notAsked(reason: OwnerResolver.notRunYet)
                if case .notAsked(let reason) = owner { unasked.append((t, reason)) }
                if let i = groups.firstIndex(where: { Self.sameRow($0.0, owner) }) { groups[i].1.append(t) }
                else { groups.append((owner, [t])) }
            }
            let answered = groups.contains { $0.0.category != .notAsked }
            if answered { groups.removeAll { $0.0.category == .notAsked } }
            for (i, (owner, types)) in groups.sorted(by: { $0.0.category.rawValue < $1.0.category.rawValue }).enumerated() {
                var exts: [String] = []
                for t in types { for e in extensionsOf(t) where !exts.contains(e) { exts.append(e) } }
                var row = KindRow(kind: kind, types: types, owner: owner, extensions: exts)
                if !answered || i == 0 { row.unasked = unasked }
                rows.append(row)
            }
        }
        let typeCount = Set(claimed.map(\.uti)).count
        return FileTypesSummary(rows: rows, kindCount: kinds.count, typeCount: typeCount)
    }

    private static func sameRow(_ a: TypeOwner, _ b: TypeOwner) -> Bool {
        switch (a, b) {
        case (.otherApp(let x, _, _, _), .otherApp(let y, _, _, _)): x == y
        // A kind's types macOS keeps share one row; it shows the first type's reason.
        case (.macOS, .macOS): true
        default: a.category == b.category && a.category != .macOS && a.category != .otherApp
        }
    }
}

// MARK: - Use Vitrine

/// What setting other apps' extensions aside changes, for the confirm sheet: macOS chooses previewers per app
/// extension, not per file type, so every type the other extension claims changes, including ones Vitrine does not
/// preview (those drop to the icon).
struct SetAsidePlan: Equatable, Sendable, Identifiable {
    struct Change: Equatable, Sendable, Identifiable {
        let name: String
        let subtitle: String
        let tile: String
        let symbol: String
        /// The short name of the app that answers today ("Inkwell").
        let from: String
        /// Vitrine answers afterwards; otherwise the file shows only its icon.
        let toVitrine: Bool
        var id: String { name + "|" + from }
    }

    let extensions: [InstalledExtension]
    /// The kinds the person picked ("Markdown"); the title and the toast name them.
    let kindNames: [String]
    let changes: [Change]

    var id: String { extensions.map(\.identifier).joined(separator: ",") }
    var title: String {
        if kindNames.count == 1 {
            let name = kindNames[0]
            return String(localized: "Use Vitrine for \(name)?", comment: "Diagnostics: confirm sheet title; the kind of file (Markdown)")
        }
        let count = kindNames.count
        return String(localized: "Use Vitrine for \(count) kinds?", comment: "Diagnostics: confirm sheet title; how many kinds of file")
    }
    var extensionNames: [String] { extensions.map(\.displayName) }
    var appNames: [String] { Array(NSOrderedSet(array: extensions.map(\.appName)).array as? [String] ?? []) }
    var doneMessage: String {
        let names = Self.list(kindNames)
        return String(localized: "\(names) now preview in Vitrine", comment: "Diagnostics: message after Use Vitrine; the kinds of file, as a list")
    }

    /// Names joined the way the language joins a list: "A and B", "A, B and C" (with the comma before "and" where the
    /// locale writes one).
    static func list(_ names: [String], locale: Locale = .autoupdatingCurrent) -> String {
        names.formatted(.list(type: .and).locale(locale))
    }

    /// The first word of an app's name, the way the design shortens "Inkwell Markdown" to "Inkwell".
    static func shortName(_ app: String) -> String { app.split(separator: " ").first.map(String.init) ?? app }

    static func make(rows: [KindRow], installed: [InstalledExtension], summary: FileTypesSummary,
                     describe: (String) -> String?, extensionsOf: (String) -> [String]) -> SetAsidePlan {
        var ids: [String] = []
        for row in rows { if case .otherApp(let id, _, _, _) = row.owner, !ids.contains(id) { ids.append(id) } }
        let exts = ids.compactMap { id in installed.first { $0.identifier == id } }
        let kindByType = Dictionary(summary.rows.flatMap { r in r.types.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        var changes: [Change] = []
        for ext in exts {
            let from = shortName(ext.appName)
            for claim in ext.claims {
                if let row = kindByType[claim] {
                    guard !changes.contains(where: { $0.name == row.kind.name && $0.from == from }) else { continue }
                    changes.append(Change(name: row.kind.name, subtitle: row.subtitle, tile: row.kind.tile, symbol: row.kind.symbol, from: from, toVitrine: true))
                } else {
                    let name = describe(claim) ?? claim
                    guard !changes.contains(where: { $0.name == name && $0.from == from }) else { continue }
                    let exts = extensionsOf(claim).map { "." + $0 }.joined(separator: " ")
                    let note = String(localized: "Vitrine does not preview this kind", comment: "Diagnostics: confirm sheet, a kind of file that will show only its icon")
                    changes.append(Change(name: name, subtitle: (exts.isEmpty ? "" : exts + " · ") + note,
                                          tile: "kind-other", symbol: "doc", from: from, toVitrine: false))
                }
            }
        }
        changes = changes.filter(\.toVitrine) + changes.filter { !$0.toVitrine }
        var names: [String] = []
        for row in rows where !names.contains(row.kind.name) { names.append(row.kind.name) }
        return SetAsidePlan(extensions: exts, kindNames: names, changes: changes)
    }
}

// MARK: - Extensions pane

/// One of Vitrine's extensions as the Extensions pane shows it.
struct ExtensionHealth: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        /// On, and macOS uses this app's copy.
        case on(version: String)
        /// On, but pluginkit's default discovery returns another copy (an older build, another folder); `path` is
        /// that copy's app.
        case onElsewhere(version: String, path: String)
        /// The user turned it off (System Settings › Login Items & Extensions › Quick Look, or `pluginkit -e ignore`).
        case off
        /// pluginkit does not list it at all.
        case notRegistered
    }

    let id: String
    let name: String
    let state: State

    var isProblem: Bool { if case .on = state { false } else { true } }
}

/// A registered copy of a Vitrine extension that is not inside the running app.
struct OtherCopy: Equatable, Sendable, Identifiable {
    /// The `.app` the copies live in.
    let appPath: String
    let version: String
    let extensionPaths: [String]
    /// macOS currently uses at least one extension from this copy.
    let inUse: Bool
    /// The copy carries the working name's identifiers (com.xbtdmt.spacebar.*).
    let legacyName: Bool

    var id: String { appPath }
}

struct ExtensionsSummary: Equatable, Sendable {
    let extensions: [ExtensionHealth]
    let otherCopies: [OtherCopy]

    var offCount: Int { extensions.filter { if case .off = $0.state { true } else { false } }.count }
    var problemCount: Int { extensions.filter(\.isProblem).count + (otherCopies.isEmpty ? 0 : 1) }

    /// - Parameters:
    ///   - elected: `pluginkit -m -v -p com.apple.quicklook.preview` (the copy discovery returns per identifier).
    ///   - all: the same with `-A -D` (every registered copy).
    ///   - ownApp: the running app's bundle path; `expected` its extensions (identifier, display name).
    static func make(elected: [PluginRecord], all: [PluginRecord], ownApp: String, expected: [(String, String)]) -> ExtensionsSummary {
        let own = ownApp.hasSuffix("/") ? String(ownApp.dropLast()) : ownApp
        let health: [ExtensionHealth] = expected.map { id, name in
            guard let rec = elected.first(where: { $0.identifier == id }) ?? all.first(where: { $0.identifier == id }) else {
                return ExtensionHealth(id: id, name: name, state: .notRegistered)
            }
            if rec.election == .ignore { return ExtensionHealth(id: id, name: name, state: .off) }
            if let parent = rec.parentAppPath, parent != own {
                return ExtensionHealth(id: id, name: name, state: .onElsewhere(version: rec.version, path: parent))
            }
            return ExtensionHealth(id: id, name: name, state: .on(version: rec.version))
        }
        let electedPaths = Set(elected.compactMap(\.path))
        var byApp: [String: (version: String, paths: [String], inUse: Bool, legacy: Bool)] = [:], order: [String] = []
        for rec in all where InstalledExtension.maker(of: rec.identifier, path: rec.path) == .vitrine {
            guard let app = rec.parentAppPath, app != own, let path = rec.path else { continue }
            if byApp[app] == nil { order.append(app); byApp[app] = (rec.version, [], false, false) }
            if !byApp[app]!.paths.contains(path) { byApp[app]!.paths.append(path) }
            if electedPaths.contains(path) { byApp[app]!.inUse = true }
            if rec.identifier.hasPrefix("com.xbtdmt.spacebar.") { byApp[app]!.legacy = true }
        }
        let copies = order.map { app in
            let c = byApp[app]!
            return OtherCopy(appPath: app, version: c.version, extensionPaths: c.paths, inUse: c.inUse, legacyName: c.legacy)
        }.sorted { ($0.inUse ? 0 : 1, $0.appPath) < ($1.inUse ? 0 : 1, $1.appPath) }
        return ExtensionsSummary(extensions: health, otherCopies: copies)
    }
}

// MARK: - Report

enum DiagnosticsReportText {
    /// The text Copy Report puts on the clipboard, in the Report pane's format: counts and kinds only, no file names,
    /// paths or contents (only the two sections this window has built). Its wording stays English in every language
    /// (S-12): it is written for the bug tracker and `--diagnose`, in a fixed format with a fixed date stamp.
    static func make(appVersion: String, macOS: String, generated: Date, fileTypes: FileTypesSummary?, extensions: ExtensionsSummary?) -> String {
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["## Vitrine diagnostics", "Vitrine \(appVersion) · macOS \(macOS)",
                     "Generated \(stamp.string(from: generated)) · no file names, paths or contents", ""]
        if let f = fileTypes {
            lines.append("### File types")
            for row in f.rows(.otherApp) {
                if case .otherApp(_, _, let app, let version) = row.owner { lines.append("- \(row.kind.name): \(app) \(version) wins".replacingOccurrences(of: "  ", with: " ")) }
            }
            for row in f.rows(.fallback) { lines.append("- \(row.kind.name): no previewer (Vitrine extension off)") }
            if f.count(.vitrine) > 0 { lines.append("- \(kinds(f.count(.vitrine))): Vitrine") }
            let kept = f.rows(.macOS)
            if !kept.isEmpty { lines.append("- \(kinds(kept.count)) kept by macOS (\(kept.map(\.kind.name).joined(separator: ", ")))") }
            if f.count(.notAsked) > 0 { lines.append("- \(kinds(f.count(.notAsked))) not asked") }
            let partly = f.rows.reduce(0) { $0 + ($1.owner.category == .notAsked ? 0 : $1.unasked.count) }
            if partly > 0 { lines.append("- \(partly) more \(partly == 1 ? "type" : "types") not asked") }
            lines.append("")
        }
        if let e = extensions {
            lines.append("### Extensions")
            var fine = 0, problems = false
            for x in e.extensions {
                switch x.state {
                case .on: fine += 1
                case .off: lines.append("- \(x.name): off in System Settings"); problems = true
                case .notRegistered: lines.append("- \(x.name): not registered"); problems = true
                case .onElsewhere(let v, _): lines.append("- \(x.name): macOS uses another copy (\(v))"); problems = true
                }
            }
            // Copies grouped by what they are, so a build folder full of them stays one line.
            var groups: [(String, Int)] = []
            for c in e.otherCopies {
                let label = "\(c.inUse ? "copy in use" : "other copy registered"): Vitrine \(c.version)\(c.legacyName ? " (old name)" : "")"
                if let i = groups.firstIndex(where: { $0.0 == label }) { groups[i].1 += 1 } else { groups.append((label, 1)) }
            }
            for (label, n) in groups {
                lines.append("- " + (n == 1 ? label.prefix(1).uppercased() + label.dropFirst() : "\(n) × \(label)"))
                problems = true
            }
            if fine > 0 { lines.append(problems ? "- \(fine) \(fine == 1 ? "other" : "others"): on" : "- All \(fine) on") }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func kinds(_ n: Int) -> String { n == 1 ? "1 kind" : "\(n) kinds" }
}
