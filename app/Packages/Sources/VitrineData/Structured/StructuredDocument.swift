import Foundation

/// The structured formats this engine reads into a `StructuredTree`.
public enum StructuredFormat: String, Sendable, Equatable, Codable, CaseIterable {
    /// JSON, and with `JSONSyntax.automatic` or `.lenient` also JSONC and JSON5.
    case json
    /// JSON Lines / NDJSON: one JSON value per line.
    case jsonLines
    case yaml
    case toml
    case xml
    /// XML, binary and OpenStep property lists.
    case propertyList

    /// The format a file extension names, nil when it names none of these.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "json", "json5", "jsonc", "geojson", "topojson", "webmanifest", "har", "jsonld", "babelrc", "eslintrc",
             "prettierrc", "code-workspace", "code-snippets", "avsc", "gltf":
            self = .json
        case "jsonl", "ndjson", "jsonlines", "ldjson": self = .jsonLines
        case "yaml", "yml": self = .yaml
        case "toml": self = .toml
        case "xml", "xsd", "xsl", "xslt", "rss", "atom", "opml", "xib", "storyboard", "xliff", "xlf", "csproj",
             "vcxproj", "props", "targets", "nuspec", "resx", "wsdl", "pom", "kml", "gpx", "dae", "sdef", "rdf", "xspf":
            self = .xml
        case "plist", "entitlements", "strings", "stringsdict", "savedsearch", "webloc", "scriptsuite", "car", "nib":
            self = .propertyList
        default: return nil
        }
    }

    /// The format the first bytes show, for files without a telling extension.
    public static func sniff(_ prefix: Data) -> StructuredFormat? {
        var bytes = [UInt8](prefix.prefix(4096))
        if bytes.starts(with: Array("bplist".utf8)) { return .propertyList }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let first = bytes.firstIndex(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return nil }
        let head = String(decoding: bytes[first...], as: UTF8.self)
        if head.hasPrefix("<") {
            if head.contains("<!DOCTYPE plist") || head.contains("<plist") { return .propertyList }
            return .xml
        }
        if head.hasPrefix("{") || head.hasPrefix("[") {
            let lines = head.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
            if lines.count >= 2, lines.allSatisfy({ $0.hasPrefix("{") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("}") }) {
                return .jsonLines
            }
            return .json
        }
        if head.hasPrefix("---") || head.hasPrefix("%YAML") { return .yaml }
        return nil
    }
}

/// The dialect a parse found, which can be narrower than the format asked for.
public enum StructuredDialect: String, Sendable, Equatable, Codable, CaseIterable {
    case json, jsonc, json5, jsonLines, yaml, toml, xml, plistXML, plistBinary, plistOpenStep

    public var displayName: String {
        switch self {
        case .json: "JSON"
        case .jsonc: "JSONC"
        case .json5: "JSON5"
        case .jsonLines: String(localized: "JSON Lines", bundle: .module, comment: "File format name: one JSON value per line.")
        case .yaml: "YAML"
        case .toml: "TOML"
        case .xml: "XML"
        case .plistXML: String(localized: "XML property list", bundle: .module, comment: "File format name.")
        case .plistBinary: String(localized: "Binary property list", bundle: .module, comment: "File format name.")
        case .plistOpenStep: String(localized: "OpenStep property list", bundle: .module, comment: "File format name; OpenStep is a product name.")
        }
    }
}

/// Line shape of the input, to tell a minified file (one enormous line) from a laid-out one.
public struct StructuredLayout: Sendable, Equatable {
    public var lineCount: Int
    public var longestLineBytes: Int
    /// Most of the input sits on lines of 1,000 bytes or more: a "Formatted" view is worth offering first.
    public var isMinified: Bool

    public static func measure(_ bytes: UnsafeBufferPointer<UInt8>) -> StructuredLayout {
        guard !bytes.isEmpty else { return StructuredLayout(lineCount: 0, longestLineBytes: 0, isMinified: false) }
        var lines = 0, longest = 0, inLongLines = 0, start = 0
        var i = 0
        let count = bytes.count
        while i < count {
            if bytes[i] == 0x0A {
                let length = i - start
                lines += 1
                longest = max(longest, length)
                if length >= 1000 { inLongLines += length }
                start = i + 1
            }
            i += 1
        }
        if start < count {
            let length = count - start
            lines += 1
            longest = max(longest, length)
            if length >= 1000 { inLongLines += length }
        }
        let minified = count >= 1000 && inLongLines * 2 >= count
        return StructuredLayout(lineCount: lines, longestLineBytes: longest, isMinified: minified)
    }

    public static func measure(_ data: Data) -> StructuredLayout {
        data.withUnsafeBytes { measure($0.bindMemory(to: UInt8.self)) }
    }
}

/// Everything one parse produced: the tree, how much of the document it covers, and what went wrong.
public struct StructuredParseResult: Sendable {
    public let format: StructuredFormat
    public let dialect: StructuredDialect
    public let tree: StructuredTree
    public let coverage: StructuredCoverage
    /// The first error, when the input is not valid in its format (the tree then holds what came before it).
    public let error: StructuredDiagnostic?
    /// Every finding, errors included, capped at `StructuredOptions.maxDiagnostics`.
    public let diagnostics: [StructuredDiagnostic]
    /// YAML documents, JSON Lines records (good and bad), 1 otherwise (0 for an empty YAML stream).
    public let documentCount: Int
    /// Nodes in the source, kept or not (a lower bound when the parse stopped early).
    public let sourceNodeCount: Int
    /// The deepest node in the source, kept or not.
    public let maxDepth: Int
    public let layout: StructuredLayout
    /// Bytes parsed, and the file's size when it is known to be larger.
    public let parsedBytes: Int64
    public let fileSize: Int64

    public var isValid: Bool { error == nil }
}

/// The entry point: parse bytes or a file into a tree.
public enum StructuredParser {
    /// Parses `url`, reading at most `options.maxInputBytes` of it (a larger file gives a partial tree).
    /// - Parameter format: nil uses the extension, then the first bytes.
    public static func parse(contentsOf url: URL, format: StructuredFormat? = nil,
                             options: StructuredOptions = StructuredOptions()) throws -> StructuredParseResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let limit = Int(min(fileSize, max(0, options.maxInputBytes)))
        let data = try handle.read(upToCount: limit) ?? Data()
        let chosen = format ?? StructuredFormat(fileExtension: url.pathExtension) ?? StructuredFormat.sniff(data) ?? .json
        var options = options
        if format == nil, ["json5", "jsonc"].contains(url.pathExtension.lowercased()), options.jsonSyntax == .automatic {
            options.jsonSyntax = .lenient
        }
        return parse(data, format: chosen, options: options, fileSize: max(fileSize, Int64(data.count)))
    }

    /// Parses `data`. Pass `fileSize` when `data` is only the start of a larger file, so the end of `data` is read as
    /// "the rest was not read" rather than as a syntax error.
    public static func parse(_ data: Data, format: StructuredFormat, options: StructuredOptions = StructuredOptions(),
                             fileSize: Int64? = nil) -> StructuredParseResult {
        var input = data
        if Int64(input.count) > options.maxInputBytes { input = input.prefix(Int(max(0, options.maxInputBytes))) }
        let size = max(fileSize ?? Int64(data.count), Int64(data.count))
        let truncated = Int64(input.count) < size

        var notes: [StructuredDiagnostic] = []
        if format != .propertyList && format != .xml, let (utf8, name) = StructuredText.transcodeIfNeeded(input) {
            input = utf8
            notes.append(StructuredDiagnostic(.warning, String(localized: "read as \(name); byte offsets refer to the UTF-8 text", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")))
        }

        var output: ReaderOutput
        switch format {
        case .json: output = JSONReader.read(input, options: options, truncated: truncated)
        case .jsonLines: output = JSONLinesReader.read(input, options: options, truncated: truncated)
        case .yaml: output = YAMLReader.read(input, options: options, truncated: truncated)
        case .toml: output = TOMLReader.read(input, options: options, truncated: truncated)
        case .xml: output = XMLTreeReader.read(input, options: options, truncated: truncated)
        case .propertyList: output = PlistReader.read(input, options: options, truncated: truncated)
        }
        output.diagnostics.insert(contentsOf: notes, at: 0)
        var layout = StructuredLayout.measure(input)
        // A binary plist has no lines, and JSON Lines is one record per line by design: neither is "minified".
        if output.dialect == .plistBinary || output.dialect == .jsonLines { layout.isMinified = false }
        return output.result(format: format, options: options, layout: layout, parsedBytes: Int64(input.count),
                             fileSize: size, inputTruncated: truncated)
    }
}

/// What a format reader hands back before the tree is finished.
struct ReaderOutput {
    var builder: StructuredTreeBuilder
    var dialect: StructuredDialect
    var error: StructuredDiagnostic?
    var diagnostics: [StructuredDiagnostic] = []
    /// The input ended inside the document because it was cut short.
    var endedEarly = false
    var extraLimits: [StructuredLimit] = []
    var documentCount = 1

    init(builder: StructuredTreeBuilder, dialect: StructuredDialect) {
        self.builder = builder; self.dialect = dialect
    }

    mutating func note(_ diagnostic: StructuredDiagnostic, cap: Int) {
        if diagnostics.count < cap { diagnostics.append(diagnostic) }
    }

    mutating func fail(_ diagnostic: StructuredDiagnostic, cap: Int) {
        if error == nil { error = diagnostic }
        note(diagnostic, cap: cap)
    }

    consuming func result(format: StructuredFormat, options: StructuredOptions, layout: StructuredLayout,
                          parsedBytes: Int64, fileSize: Int64, inputTruncated: Bool) -> StructuredParseResult {
        let stoppedEarly = error != nil || endedEarly || !extraLimits.isEmpty
        let tree = builder.finish(inputEndedEarly: stoppedEarly)
        var reasons = builder.limitReasons + extraLimits
        if error != nil, dialect != .jsonLines { reasons.append(.syntaxError) }
        if inputTruncated { reasons.append(.inputByteLimit(readBytes: parsedBytes, fileSize: fileSize)) }
        let wholeDocumentScanned = !inputTruncated && !stoppedEarly
        let coverage: StructuredCoverage = reasons.isEmpty
            ? .complete(nodes: tree.count)
            : .partial(shownNodes: tree.count, totalNodes: wholeDocumentScanned ? builder.totalNodes : nil, reasons: reasons)
        let firstError = error ?? diagnostics.first { $0.severity == .error }
        return StructuredParseResult(format: format, dialect: dialect, tree: tree, coverage: coverage, error: firstError,
                                     diagnostics: diagnostics, documentCount: documentCount,
                                     sourceNodeCount: builder.totalNodes, maxDepth: builder.maxDepthSeen, layout: layout,
                                     parsedBytes: parsedBytes, fileSize: fileSize)
    }
}

enum StructuredText {
    /// UTF-16 and UTF-32 input (by BOM, or by the zero-byte pattern RFC 4627 describes) as UTF-8, so the byte parsers
    /// see one encoding. nil when the input already is UTF-8 (or ASCII).
    static func transcodeIfNeeded(_ data: Data) -> (Data, String)? {
        let b = [UInt8](data.prefix(4))
        guard b.count >= 2 else { return nil }
        let encoding: String.Encoding
        let name: String
        var skip = 0
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0xFE, b[3] == 0xFF { encoding = .utf32BigEndian; name = "UTF-32"; skip = 4 }
        else if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0, b[3] == 0 { encoding = .utf32LittleEndian; name = "UTF-32"; skip = 4 }
        else if b[0] == 0xFE, b[1] == 0xFF { encoding = .utf16BigEndian; name = "UTF-16"; skip = 2 }
        else if b[0] == 0xFF, b[1] == 0xFE { encoding = .utf16LittleEndian; name = "UTF-16"; skip = 2 }
        else if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0, b[3] != 0 { encoding = .utf32BigEndian; name = "UTF-32" }
        else if b.count >= 4, b[0] != 0, b[1] == 0, b[2] == 0, b[3] == 0 { encoding = .utf32LittleEndian; name = "UTF-32" }
        else if b[0] == 0, b[1] != 0 { encoding = .utf16BigEndian; name = "UTF-16" }
        else if b[0] != 0, b[1] == 0 { encoding = .utf16LittleEndian; name = "UTF-16" }
        else { return nil }
        var body = data.dropFirst(skip)
        let unit = name == "UTF-32" ? 4 : 2
        body = body.prefix(body.count - body.count % unit)
        guard let text = String(data: Data(body), encoding: encoding) else { return nil }
        return (Data(text.utf8), name)
    }
}

/// `.json`: strict first, then (with `.automatic`) the lenient reader and JSON Lines, keeping whichever explains the
/// file best.
enum JSONReader {
    static func read(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch options.jsonSyntax {
            case .strict: return once(bytes, lenient: false, options: options, truncated: truncated).output
            case .lenient: return once(bytes, lenient: true, options: options, truncated: truncated).output
            case .automatic:
                let strict = once(bytes, lenient: false, options: options, truncated: truncated)
                guard let strictError = strict.output.error else { return strict.output }
                if strict.outcome.extraDataOnLaterLine {
                    let lines = JSONLinesReader.read(bytes, options: options, truncated: truncated)
                    if lines.error == nil, lines.documentCount >= 2 { return lines }
                }
                var lenient = once(bytes, lenient: true, options: options, truncated: truncated)
                if lenient.output.error == nil {
                    let dialectName = lenient.output.dialect.displayName
                    lenient.output.note(StructuredDiagnostic(.warning, String(localized: "not strict JSON (\(strictError.reason)); read as \(dialectName)", bundle: .module, comment: "Note on a JSON file that only parses leniently; the arguments are the strict parser's complaint and a format name such as JSON5."),
                                                             at: strictError.location), cap: options.maxDiagnostics)
                    return lenient.output
                }
                return lenient.outcome.errorPosition > strict.outcome.errorPosition ? lenient.output : strict.output
            }
        }
    }

    private static func once(_ bytes: UnsafeBufferPointer<UInt8>, lenient: Bool, options: StructuredOptions,
                             truncated: Bool) -> (output: ReaderOutput, outcome: JSONOutcome) {
        var parser = JSONParser(bytes: bytes, lenient: lenient, options: options)
        var builder = StructuredTreeBuilder(options: options, pathStyle: .jsonPath)
        let outcome = parser.parse(into: &builder, inputTruncated: truncated)
        let dialect: StructuredDialect = outcome.features.contains(.json5) ? .json5
            : outcome.features.isEmpty ? .json : .jsonc
        var output = ReaderOutput(builder: builder, dialect: dialect)
        output.endedEarly = outcome.endedEarly
        if let error = outcome.error { output.fail(error, cap: options.maxDiagnostics) }
        return (output, outcome)
    }
}
