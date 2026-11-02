import AppKit
import Foundation
import VitrineArchive
import VitrineData
import VitrineDocument
import VitrineEngineering
import VitrineFormats
import VitrineSupport
import VitrineTrust

/// One card for every format reader (S-21, S-22, S-23; cards r3-a): the reader's headline as the sentence, its facts,
/// its warnings as the verdict and numbered findings, and its views (a graph, a waterfall, the file's Source) behind
/// the viewer switch. Each reader family maps its own document into a `ReaderDigest`; the card never parses.
/// roadmap: S-22
struct ReaderDigest {
    struct Warning { var danger: Bool; var title: String; var detail: String? }
    var chip: String
    var symbol: String
    var headline: String
    var facts: [(id: String, label: String, value: String)]
    var warnings: [Warning]
    var views: [(title: String, view: DocumentView)]
    var truncated = false
    /// A cover or album art for the card's stage (books, comics, audio).
    var picture: Data?
    /// The file itself has text worth a Source view.
    var hasSource = true
    /// The picked format view for the stage, when the format has one (F1–F9).
    var stage: StageFactory?
}

enum ReaderDigests {
    /// The digest for a `.reader(id)` file, or nil when its reader cannot read it.
    static func make(url: URL, id: String, data: Data) -> ReaderDigest? {
        let family = id.split(separator: ".").first.map(String.init) ?? ""
        switch family {
        case "infra": return infra(url: url, data: data)
        case "api": return apiSpec(url: url, data: data)
        case "apple": return appleDev(url: url, data: data, folder: id == "apple.folder")
        case "media": return media(url: url)
        case "ai": return aiFormats(url: url, folder: id == "ai.folder")
        case "aidata": return aiData(url: url, data: data)
        case "everyday": return everyday(url: url, data: data)
        default: return nil
        }
    }

    // MARK: Infrastructure (E-4, T-8)

    static func infra(url: URL, data: Data) -> ReaderDigest? {
        guard let doc = InfraReader.read(data: data, fileName: url.lastPathComponent, path: url.path) else { return nil }
        var views: [(title: String, view: DocumentView)] = []
        var stage: StageFactory?
        switch doc {
        case .compose(let s):
            if !s.graph.edges.isEmpty || !s.graph.nodes.isEmpty {
                views.append((title: "Graph", view: .text(graphText(s.graph))))
                let graph = StageAdapters.graph(s)
                stage = { GraphStageView(graph: graph) }   // F9 A
            }
        case .githubWorkflow(let s):
            if !s.graph.nodes.isEmpty {
                views.append((title: "Graph", view: .text(graphText(s.graph))))
                let graph = StageAdapters.graph(s)
                stage = { GraphStageView(graph: graph) }   // F9 A
            }
        case .har(let s):
            views.append((title: "Waterfall", view: .text(waterfallText(s))))
            let rows = StageAdapters.waterfall(s)
            if !rows.isEmpty { stage = { WaterfallStageView(rows: rows) } }   // F8 A
        default: break
        }
        return ReaderDigest(chip: infraChip(doc.kind), symbol: infraSymbol(doc.kind), headline: doc.headline,
                            facts: doc.facts.map { (id: $0.id, label: $0.label, value: $0.value) },
                            warnings: doc.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: $0.subject) },
                            views: views, truncated: doc.truncated, stage: stage)
    }

    // MARK: Models, pickles and MCP configs (S-21)

    static func aiFormats(url: URL, folder: Bool) -> ReaderDigest? {
        let doc: AIDocument?
        if folder { doc = AIFormatsReader.read(directory: url) }
        else if let source = try? FileByteSource(url: url) { doc = AIFormatsReader.read(source: source, fileName: url.lastPathComponent, path: url.path) }
        else { doc = nil }
        guard let doc else { return nil }
        let chip: String, symbol: String
        switch doc {
        case .rules: chip = String(localized: "Rules file", bundle: .previewKit, comment: "The kind chip on an agent rules or skill file's card."); symbol = "text.book.closed"
        case .mcpConfig: chip = String(localized: "MCP config", bundle: .previewKit, comment: "The kind chip on an MCP server configuration's card."); symbol = "server.rack"
        case .pickle: chip = String(localized: "Pickle", bundle: .previewKit, comment: "The kind chip on a Python pickle or PyTorch file's card."); symbol = "exclamationmark.shield"
        case .gguf, .safetensors, .onnx, .coreML: chip = String(localized: "Model", bundle: .previewKit, comment: "The kind chip on a machine-learning model file's card."); symbol = "cpu"
        case .tokenizer: chip = String(localized: "Tokenizer", bundle: .previewKit, comment: "The kind chip on a tokenizer.json card."); symbol = "textformat.abc"
        }
        let textual: Bool = { if case .mcpConfig = doc { return true }; if case .tokenizer = doc { return true }; return false }()
        return ReaderDigest(chip: chip, symbol: symbol, headline: doc.headline,
                            facts: doc.facts.map { (id: $0.label, label: $0.label, value: $0.value) },
                            warnings: doc.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: nil) },
                            views: [], hasSource: textual)
    }

    // MARK: JSONL, chat exports, evals, traces and arrays (S-21)

    static func aiData(url: URL, data: Data) -> ReaderDigest? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard let doc = AIDataReader.read(data: data, fileName: url.lastPathComponent, totalFileSize: size) else { return nil }
        var views: [(title: String, view: DocumentView)] = []
        if let table = doc.table, !table.columns.isEmpty {
            let lines = [table.columns.joined(separator: "\t")] + table.rows.map { $0.joined(separator: "\t") }
            views.append((title: "Table", view: .text(lines.joined(separator: "\n"))))
        }
        var stage: StageFactory?
        let chip: String, symbol: String
        switch doc {
        case .jsonLines: chip = String(localized: "JSON Lines", bundle: .previewKit, comment: "The kind chip on a JSONL file's card."); symbol = "list.bullet.rectangle"
        case .chatExport: chip = String(localized: "Chat export", bundle: .previewKit, comment: "The kind chip on a ChatGPT or Claude conversations export's card."); symbol = "bubble.left.and.bubble.right"
        case .promptfoo, .inspectEval: chip = String(localized: "Eval results", bundle: .previewKit, comment: "The kind chip on an AI evaluation log's card."); symbol = "checklist"
        case .trace(let t):
            chip = String(localized: "Trace", bundle: .previewKit, comment: "The kind chip on an OpenTelemetry trace's card."); symbol = "chart.bar.doc.horizontal"
            let rows = StageAdapters.waterfall(t)
            if !rows.isEmpty { stage = { WaterfallStageView(rows: rows) } }   // F8 A
        case .numpyArray, .numpyArchive, .hdf5: chip = String(localized: "Array data", bundle: .previewKit, comment: "The kind chip on a NumPy or HDF5 file's card."); symbol = "square.grid.3x3"
        }
        let ext = url.pathExtension.lowercased()
        return ReaderDigest(chip: chip, symbol: symbol, headline: doc.headline,
                            facts: doc.facts.map { (id: $0.label, label: $0.label, value: $0.value) },
                            warnings: doc.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: nil) },
                            views: views, hasSource: ["jsonl", "ndjson", "json"].contains(ext), stage: stage)
    }

    // MARK: Subtitles, calendars, contacts, email, LaTeX and BibTeX (S-23)

    static func everyday(url: URL, data: Data) -> ReaderDigest? {
        guard let doc = EverydayReader.read(data: data, fileName: url.lastPathComponent) else { return nil }
        var views: [(title: String, view: DocumentView)] = []
        var stage: StageFactory?
        let chip: String, symbol: String
        switch doc {
        case .subtitles(let summary):
            chip = String(localized: "Subtitles", bundle: .previewKit, comment: "The kind chip on a subtitle file's card."); symbol = "captions.bubble"
            stage = { SubtitleStageView(summary: summary) }   // F4 A
        case .calendar(let summary):
            chip = String(localized: "Calendar", bundle: .previewKit, comment: "The kind chip on a calendar invite's card."); symbol = "calendar"
            stage = { InviteStageView(calendar: summary) }   // F7 A
        case .contacts(let summary):
            chip = String(localized: "Contact", bundle: .previewKit, comment: "The kind chip on a contact card file's card."); symbol = "person.crop.rectangle"
            stage = { ContactStageView(contacts: summary) }   // F7 A
        case .email(let s):
            chip = String(localized: "Email", bundle: .previewKit, comment: "The kind chip on an email file's card."); symbol = "envelope"
            stage = { EmailStageView(summary: s) }   // F6 A: the message drawn with every remote load blocked
            // The plain text, never the HTML: remote content and scripts stay out (the drawn message view is F6).
            if let body = s.plainBody, !body.isEmpty { views.append((title: "Message", view: .text(String(body.prefix(200_000))))) }
        case .bibliography: chip = String(localized: "Bibliography", bundle: .previewKit, comment: "The kind chip on a BibTeX file's card."); symbol = "books.vertical"
        case .latex: chip = String(localized: "LaTeX document", bundle: .previewKit, comment: "The kind chip on a LaTeX file's card."); symbol = "function"
        }
        let ext = url.pathExtension.lowercased()
        return ReaderDigest(chip: chip, symbol: symbol, headline: doc.headline,
                            facts: doc.facts.map { (id: $0.label, label: $0.label, value: $0.value) },
                            warnings: doc.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: nil) },
                            views: views, truncated: doc.truncated, hasSource: ext != "msg", stage: stage)
    }

    // MARK: Books, comics, maps, 3D and audio (S-23)

    static func media(url: URL) -> ReaderDigest? {
        guard let doc = MediaReader.read(url: url) else { return nil }
        var views: [(title: String, view: DocumentView)] = []
        var picture: Data?
        var stage: StageFactory?
        let chip: String, symbol: String
        switch doc {
        case .book(let s):
            chip = String(localized: "Book", bundle: .previewKit, comment: "The kind chip on an EPUB book's card."); symbol = "book.closed"
            picture = s.cover?.data
            stage = { BookStageView(book: s) }   // F5 A
            if !s.tableOfContents.isEmpty {
                views.append((title: "Contents", view: .text(s.tableOfContents.map { String(repeating: "    ", count: max(0, $0.depth)) + $0.title }.joined(separator: "\n"))))
            }
        case .comic(let s):
            chip = String(localized: "Comic", bundle: .previewKit, comment: "The kind chip on a comic book archive's card."); symbol = "book.pages"
            picture = s.cover?.data
            stage = { BookStageView(comic: s) }   // F5 A
        case .map(let s):
            chip = String(localized: "Map", bundle: .previewKit, comment: "The kind chip on a GPX, KML or GeoJSON file's card."); symbol = "map"
            stage = { MapStageView(summary: s) }   // F1 A: drawn locally, no tiles
            if !s.tracks.isEmpty {
                views.append((title: "Tracks", view: .text(s.tracks.map { t in
                    (t.name ?? "—") + "  ·  " + Measurement(value: t.distanceMeters / 1000, unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, usage: .road))
                        + "  ·  \(t.pointCount) " + String(localized: "points", bundle: .previewKit, comment: "After a number: GPS points in a track.")
                }.joined(separator: "\n"))))
            }
        case .model(let s):
            chip = String(localized: "3D model", bundle: .previewKit, comment: "The kind chip on a 3D model file's card."); symbol = "cube"
            stage = { ModelStageView(summary: s, fileURL: url) }   // F2 A
        case .audio(let s):
            chip = String(localized: "Audio", bundle: .previewKit, comment: "The kind chip on an audio file's card."); symbol = "waveform"
            picture = s.cover?.data
            stage = { AudioStageView(summary: s, fileURL: url) }   // F3 A
        case .image:
            chip = String(localized: "Image", bundle: .previewKit, comment: "The kind chip on an image's card."); symbol = "photo"
        }
        let textual = ["gpx", "kml", "geojson", "obj", "gltf"].contains(url.pathExtension.lowercased())
        return ReaderDigest(chip: chip, symbol: symbol, headline: doc.headline,
                            facts: doc.facts.map { (id: $0.label, label: $0.label, value: $0.value) },
                            warnings: doc.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: nil) },
                            views: views, picture: picture, hasSource: textual, stage: stage)
    }

    // MARK: Apple development files (E-5)

    static func appleDev(url: URL, data: Data, folder: Bool) -> ReaderDigest? {
        guard let doc = folder ? AppleDevReader.read(directory: url) : AppleDevReader.read(data: data, fileName: url.lastPathComponent) else { return nil }
        var views: [(title: String, view: DocumentView)] = []
        let chip: String, symbol: String
        switch doc {
        case .stringCatalog(let s):
            chip = String(localized: "String Catalog", bundle: .previewKit, comment: "The kind chip on an Xcode String Catalog's card."); symbol = "character.bubble"
            let langs = s.languages
            var lines = [(["key"] + langs).joined(separator: "\t")]
            lines += s.rows.prefix(2_000).map { row in
                ([row.key] + langs.map { lang in
                    guard let cell = row.cells[lang] else { return "—" }
                    return (cell.value ?? "") + " [" + cell.state.label + "]"
                }).joined(separator: "\t")
            }
            views.append((title: "Translations", view: .text(lines.joined(separator: "\n"))))
        case .crashReport(let s):
            chip = String(localized: "Crash report", bundle: .previewKit, comment: "The kind chip on a crash report's card."); symbol = "exclamationmark.octagon"
            if !s.frames.isEmpty {
                let lines = s.frames.map { f in
                    String(format: "%3d  ", f.index) + (f.image ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0) + "  "
                        + (f.symbol.map { $0 + (f.symbolOffset.map { " + \($0)" } ?? "") } ?? f.address ?? f.imageOffset.map { "+ \($0)" } ?? "")
                        + (f.sourceFile.map { "  (\($0)" + (f.sourceLine.map { ":\($0)" } ?? "") + ")" } ?? "")
                }
                views.append((title: "Frames", view: .text(lines.joined(separator: "\n") + (s.framesTruncated ? "\n…" : ""))))
            }
        case .entitlements:
            chip = String(localized: "Entitlements", bundle: .previewKit, comment: "The kind chip on an entitlements file's card."); symbol = "checkmark.shield"
        case .infoPlist:
            chip = String(localized: "Info.plist", bundle: .previewKit, comment: "The kind chip on an app's Info.plist card (keep the file name)."); symbol = "info.square"
        case .assetCatalog:
            chip = String(localized: "Asset catalog", bundle: .previewKit, comment: "The kind chip on an Xcode asset catalog's card."); symbol = "photo.stack"
        case .xcodeArchive:
            chip = String(localized: "Xcode archive", bundle: .previewKit, comment: "The kind chip on an Xcode archive's card."); symbol = "archivebox"
        }
        return ReaderDigest(chip: chip, symbol: symbol, headline: doc.headline,
                            facts: doc.facts.map { (id: $0.label, label: $0.label, value: $0.value) },
                            warnings: doc.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: nil) },
                            views: views)
    }

    // MARK: API and schema files (E-3)

    static func apiSpec(url: URL, data: Data) -> ReaderDigest? {
        guard let spec = APISpecReader.read(data: data, fileName: url.lastPathComponent) else { return nil }
        let p = spec.presentation
        var views: [(title: String, view: DocumentView)] = []
        if !p.outline.isEmpty {
            var lines = p.outline.map { item in
                String(repeating: "    ", count: max(0, item.depth)) + item.title + (item.detail.map { "  ·  \($0)" } ?? "")
                    + (item.deprecated ? "  " + String(localized: "(deprecated)", bundle: .previewKit, comment: "Marks a deprecated item in an API outline.") : "")
            }
            if p.outlineTruncated { lines.append("…") }
            views.append((title: "Outline", view: .text(lines.joined(separator: "\n"))))
        }
        return ReaderDigest(chip: apiChip(spec.kind), symbol: "point.3.filled.connected.trianglepath.dotted", headline: p.headline,
                            facts: p.facts.map { (id: $0.label, label: $0.label, value: $0.value) },
                            warnings: p.warnings.map { ReaderDigest.Warning(danger: $0.level == .danger, title: $0.reason, detail: nil) },
                            views: views, truncated: p.truncated)
    }

    static func apiChip(_ k: APISpec.Kind) -> String {
        switch k {
        case .openAPI: String(localized: "OpenAPI", bundle: .previewKit, comment: "The kind chip on an OpenAPI or Swagger file's card.")
        case .graphQL: String(localized: "GraphQL", bundle: .previewKit, comment: "The kind chip on a GraphQL file's card.")
        case .protobuf: String(localized: "Protocol Buffers", bundle: .previewKit, comment: "The kind chip on a .proto file's card.")
        case .jsonSchema: String(localized: "JSON Schema", bundle: .previewKit, comment: "The kind chip on a JSON Schema file's card.")
        case .avro: String(localized: "Avro schema", bundle: .previewKit, comment: "The kind chip on an Avro schema file's card.")
        }
    }

    static func infraChip(_ k: InfraKind) -> String {
        switch k {
        case .terraformState: String(localized: "Terraform state", bundle: .previewKit, comment: "The kind chip on a Terraform state file's card.")
        case .compose: String(localized: "Compose file", bundle: .previewKit, comment: "The kind chip on a docker-compose file's card.")
        case .githubWorkflow: String(localized: "GitHub Actions workflow", bundle: .previewKit, comment: "The kind chip on a GitHub Actions workflow's card.")
        case .kubernetes: String(localized: "Kubernetes manifest", bundle: .previewKit, comment: "The kind chip on a Kubernetes manifest's card.")
        case .dockerfile: String(localized: "Dockerfile", bundle: .previewKit, comment: "The kind chip on a Dockerfile's card.")
        case .har: String(localized: "HTTP archive", bundle: .previewKit, comment: "The kind chip on a HAR file's card (a recording of a browser's network requests).")
        }
    }

    static func infraSymbol(_ k: InfraKind) -> String {
        switch k {
        case .terraformState: "square.stack.3d.up"
        case .compose: "shippingbox"
        case .githubWorkflow: "gearshape.2"
        case .kubernetes: "circle.hexagongrid"
        case .dockerfile: "doc.text"
        case .har: "network"
        }
    }

    /// "web → api (service_healthy)", one edge a line, then lone nodes; until the drawn graph is picked (F9).
    static func graphText(_ g: InfraGraph) -> String {
        var lines = g.edges.map { e in "\(e.from) → \(e.to)" + (e.label.map { " (\($0))" } ?? "") }
        let linked = Set(g.edges.flatMap { [$0.from, $0.to] })
        lines += g.nodes.filter { !linked.contains($0) }
        if !g.missing.isEmpty { lines.append(""); lines.append("? " + g.missing.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// One request a line: start, duration, method, status, host and path; until the drawn waterfall is picked (F8).
    static func waterfallText(_ s: HARSummary) -> String {
        s.entries.map { e in
            String(format: "%8.0f ms  %6.0f ms  ", e.startOffsetMs ?? 0, e.durationMs ?? 0) + "\(e.method) \(e.status)  \(e.host)\(e.path)"
        }.joined(separator: "\n")
    }

    /// The file itself, secrets masked (G-23); a HAR's cookie and authorization header values blanked too.
    static func source(_ text: String, id: String) -> DocumentView {
        let language = id.hasSuffix("dockerfile") ? "dockerfile" : (id.hasSuffix("har") || id.hasSuffix("terraformState") ? "json" : "yaml")
        return sourceView(text, language: language, id: id)
    }

    /// The Source view in a given language (the file's own extension decides for API files).
    static func source(_ text: String, url: URL, id: String) -> DocumentView {
        if id == "aidata.file" || id == "ai.file" { return sourceView(text, language: url.pathExtension.lowercased() == "json" ? "json" : "jsonl", id: id) }
        if id == "everyday.file" {
            let ext = url.pathExtension.lowercased()
            return sourceView(text, language: ["tex", "ltx", "latex", "bib"].contains(ext) ? "latex" : (["ttml", "dfxp"].contains(ext) ? "xml" : "plaintext"), id: id)
        }
        if id == "media.file" {
            let ext = url.pathExtension.lowercased()
            return sourceView(text, language: ["gpx", "kml"].contains(ext) ? "xml" : (["geojson", "gltf"].contains(ext) ? "json" : "plaintext"), id: id)
        }
        if id == "apple.file" {
            let ext = url.pathExtension.lowercased()
            return sourceView(text, language: ext == "xcstrings" || ext == "ips" ? "json" : (ext == "crash" ? "plaintext" : "xml"), id: id)
        }
        guard id.hasPrefix("api.") else { return source(text, id: id) }
        let ext = url.pathExtension.lowercased()
        let language = ["json", "avsc", "avpr"].contains(ext) ? "json" : (["yaml", "yml"].contains(ext) ? "yaml" : (ext == "proto" ? "proto" : (ext.hasPrefix("graph") || ext == "gql" ? "graphql" : "plaintext")))
        return sourceView(text, language: language, id: id)
    }

    static func sourceView(_ text: String, language: String, id: String) -> DocumentView {
        var shown = LensPolicy.masked(text, kind: .code(language: language)).text
        if id.hasSuffix("har"), let pattern = try? NSRegularExpression(
            pattern: #"("name"\s*:\s*"(?i:cookie|set-cookie|authorization|proxy-authorization)"\s*,\s*"value"\s*:\s*")[^"]*(")"#) {
            shown = pattern.stringByReplacingMatches(in: shown, range: NSRange(shown.startIndex..., in: shown), withTemplate: "$1••••••$2")
        }
        return .code(shown, language: language)
    }
}

extension PackageFacts {
    static func reader(url: URL, kind: FileKind, id: String) throws -> (PreviewDocument, Extras) {
        let folder = id.hasSuffix(".folder")
        var data = Data()
        if !folder {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: 32 << 20) ?? Data()
        }
        var b = Builder()
        var extras = Extras()
        // A binary plist's Source is its XML form, when that stays within the budget: Core Foundation writes a shared
        // object out once per reference, so a few kilobytes could become gigabytes of XML (S-16, F39).
        if data.starts(with: Array("bplist".utf8)), let object = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            guard PlistExpansion.fits(object, maxValues: PlistExpansion.maxValues(inputBytes: data.count),
                                      maxTextBytes: PlistExpansion.maxTextBytes(inputBytes: data.count)) else {
                let reason = PlistExpansion.tooLargeReason
                b.add("form", String(localized: "Contains", bundle: .previewKit, comment: "Fact label: what a certificate or key file holds."),
                      reason.prefix(1).uppercased() + reason.dropFirst())
                return (b.document(kind: kind), extras)
            }
            if let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) { data = xml }
        }
        let text = String(decoding: data.prefix(TextLens.maxBytes), as: UTF8.self)
        guard let digest = ReaderDigests.make(url: url, id: id, data: data) else {
            b.add("form", String(localized: "Contains", bundle: .previewKit, comment: "Fact label: what a certificate or key file holds."),
                  String(localized: "Nothing this reader understands", bundle: .previewKit, comment: "Fact value: a format reader could not read the file."))
            if !folder { extras.extraViews.append((title: "Source", view: ReaderDigests.source(text, url: url, id: id))) }
            return (b.document(kind: kind), extras)
        }
        b.add("chip", "chip", digest.chip)
        b.add("symbol", "symbol", digest.symbol)
        b.add("sentence", "sentence", digest.headline)
        for f in digest.facts { b.add("r." + f.id, f.label, f.value) }
        if digest.truncated {
            b.add("truncated", String(localized: "Read in part", bundle: .previewKit, comment: "Fact label: the file was larger than Vitrine reads."), Word.yes)
        }
        for w in digest.warnings {
            b.badges.append(Badge(level: w.danger ? .danger : .caution, title: w.title, detail: w.detail ?? ""))
        }
        b.headline(digest.headline)
        extras.extraViews = digest.views
        if !folder, digest.hasSource { extras.extraViews.append((title: "Source", view: ReaderDigests.source(text, url: url, id: id))) }
        if let picture = digest.picture { extras.icon = NSImage(data: picture) }
        extras.stage = digest.stage
        return (b.document(kind: kind), extras)
    }
}

extension BinaryCard {
    static func reader(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let facts = doc.facts.filter { $0.key.hasPrefix("r.") }
        // Short values make the strip; every fact is an answer below.
        let strip = firstThree(facts.filter { $0.value.count <= 24 }.prefix(3).map { Stat(value: $0.value, label: $0.label) })
        var answers = doc.badges.filter { $0.level != .info }.map { badge in
            Answer(mark: badge.level == .danger ? .danger : .caution,
                   question: badge.detail.isEmpty ? String(localized: "Finding", bundle: .previewKit, comment: "Row label on a format reader's card for a warning that names no subject.") : badge.detail,
                   answer: badge.title, asksQuestion: false)
        }
        answers += facts.map { Answer(mark: .neutral, question: $0.label, answer: $0.value, asksQuestion: false) }
        return BinaryCard(kind: doc.kind, title: fileName, sentence: v("sentence") ?? "", bold: [],
                          stageChip: v("chip") ?? String(localized: "Structured file", bundle: .previewKit, comment: "The kind chip on a format reader's card when the format has no name."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: String(localized: "Check before using", bundle: .previewKit, comment: "Verdict chip: a caution on a format reader's card."),
                                           danger: String(localized: "Review first", bundle: .previewKit, comment: "Verdict chip: a danger finding on a format reader's card (the file is read, not run)."),
                                           calmTitle: String(localized: "No warnings", bundle: .previewKit, comment: "Calm verdict title on a format reader's card."),
                                           calmReason: String(localized: "Read on this Mac; nothing in it was run or fetched.", bundle: .previewKit,
                                                              comment: "Calm verdict reason on a format reader's card.")),
                          answers: answers)
    }
}
