import Foundation

/// Property lists into the tree.
///
/// - XML plists are read by a small XMLParser-driven reader of their seven elements, not by
///   PropertyListSerialization, because that returns an NSDictionary and loses the authored key order (an Info.plist
///   reads best in the order it was written) and every line number. Same lock-down as `XMLTreeReader`.
/// - Binary and OpenStep plists go through PropertyListSerialization; their dictionaries come back unordered, so keys
///   are shown sorted (as `plutil -p` does). Before handing OpenStep text to it, the nesting depth is checked
///   lexically, because its parser recurses.
///
/// Data values show as byte counts ("1,024 bytes"); dates as ISO 8601; booleans and numbers are told apart.
enum PlistReader {
    static func read(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        if data.starts(with: Array("bplist".utf8)) { return viaSerialization(data, options: options, truncated: truncated) }
        func startsWithTag(_ bytes: Data) -> Bool {
            bytes.first { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) } == UInt8(ascii: "<")
        }
        if startsWithTag(data) { return xml(data, options: options, truncated: truncated) }
        // UTF-16 XML plists are rare but legal; XMLParser reads them, the check for '<' needs the decoded text.
        if let (utf8, _) = StructuredText.transcodeIfNeeded(data), startsWithTag(utf8) {
            return xml(data, options: options, truncated: truncated)
        }
        return viaSerialization(data, options: options, truncated: truncated)
    }

    // MARK: XML

    private static func xml(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        let delegate = PlistXMLDelegate(options: options, inputBytes: Int64(data.count))
        let parser = XMLParser.locked(data)
        parser.delegate = delegate
        let ok = parser.parse()
        var output = ReaderOutput(builder: delegate.builder, dialect: .plistXML)
        if delegate.abortedForExpansion {
            output.extraLimits.append(.entityExpansionLimit)
        } else if let error = delegate.structureError {
            output.fail(error, cap: options.maxDiagnostics)
        } else if !ok, let error = delegate.firstError ?? XMLParser.diagnostic(parser.parserError, line: parser.lineNumber, column: parser.columnNumber) {
            if truncated { output.endedEarly = true } else { output.fail(error, cap: options.maxDiagnostics) }
        } else if ok, delegate.builder.rootCount == 0 {
            output.fail(StructuredDiagnostic(.error, String(localized: "the property list has no value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")), cap: options.maxDiagnostics)
        }
        return output
    }

    // MARK: Binary and OpenStep

    private static func viaSerialization(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        let isBinary = data.starts(with: Array("bplist".utf8))
        var output = ReaderOutput(builder: StructuredTreeBuilder(options: options, pathStyle: .jsonPath),
                                  dialect: isBinary ? .plistBinary : .plistOpenStep)
        if truncated {
            // Neither form can be read from a prefix: the binary trailer sits at the end of the file.
            output.fail(StructuredDiagnostic(.error, String(localized: "the property list is larger than the read limit and cannot be read in part", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")),
                        cap: options.maxDiagnostics)
            return output
        }
        if !isBinary, let depth = openStepDepth(data), depth > options.maxDepth {
            output.fail(StructuredDiagnostic(.error, String(localized: "nesting deeper than \(options.maxDepth) levels is not read", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")), cap: options.maxDiagnostics)
            return output
        }
        let value: Any
        var format = PropertyListSerialization.PropertyListFormat.binary
        do {
            value = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        } catch {
            // A binary plist CF cannot read is retried as text inside CF, so its message ("Unexpected character b at
            // line 1") would mislead; CF also refuses nesting past a few hundred levels (measured: 99 reads, 599 does
            // not), which lands here too.
            let message: String
            if isBinary {
                message = String(localized: "not a readable binary property list (damaged, or nested deeper than the system reader allows)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            } else if let system = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String {
                message = system.prefix(1).lowercased() + system.dropFirst()
            } else {
                message = String(localized: "not a valid property list", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            }
            output.fail(StructuredDiagnostic(.error, message), cap: options.maxDiagnostics)
            return output
        }
        output.dialect = format == .binary ? .plistBinary : format == .xml ? .plistXML : .plistOpenStep
        // The walk below follows every reference, so a shared object is visited once per reference (F39): it runs only
        // on a value within the budget. Past `maxNodes` the builder still counts, so the budget is never below that.
        guard PlistExpansion.fits(value, maxValues: max(PlistExpansion.maxValues(inputBytes: data.count), options.maxNodes)) else {
            output.fail(StructuredDiagnostic(.error, PlistExpansion.tooLargeReason), cap: options.maxDiagnostics)
            return output
        }
        emit(value, into: &output.builder)
        return output
    }

    /// The deepest `(`/`{` nesting in OpenStep text, outside quoted strings and comments.
    static func openStepDepth(_ data: Data) -> Int? {
        var depth = 0, deepest = 0
        var quote: UInt8 = 0
        var escaped = false
        var i = data.startIndex
        while i < data.endIndex {
            let c = data[i]
            if quote != 0 {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == UInt8(ascii: "(") || c == UInt8(ascii: "{") {
                depth += 1; deepest = max(deepest, depth)
            } else if c == UInt8(ascii: ")") || c == UInt8(ascii: "}") {
                depth = max(0, depth - 1)
            }
            i += 1
        }
        return deepest
    }

    /// Walks a PropertyListSerialization value into the builder with an explicit work list.
    private static func emit(_ root: Any, into builder: inout StructuredTreeBuilder) {
        enum Work { case value(Any, String?), close }
        let dates = ISO8601DateFormatter()
        var work: [Work] = [.value(root, nil)]
        while let item = work.popLast() {
            guard case .value(let value, let name) = item else { builder.close(); continue }
            switch value {
            case let dictionary as NSDictionary:
                builder.open(.object, name: name, span: .unknown)
                work.append(.close)
                let keys = dictionary.allKeys.map { ($0 as? String) ?? String(describing: $0) }.sorted()
                for key in keys.reversed() { work.append(.value(dictionary[key] ?? NSNull(), key)) }
            case let array as NSArray:
                builder.open(.array, name: name, span: .unknown)
                work.append(.close)
                for element in array.reversed() { work.append(.value(element, nil)) }
            case let string as String:
                let (preview, cut) = builder.previewText(string[...])
                builder.leaf(.string, name: name, preview: preview, truncated: cut, span: .unknown)
            case let number as NSNumber:
                let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                builder.leaf(isBool ? .bool : .number, name: name, preview: isBool ? (number.boolValue ? "true" : "false") : number.stringValue,
                             span: .unknown)
            case let date as Date:
                builder.leaf(.date, name: name, preview: dates.string(from: date), span: .unknown)
            case let data as Data:
                builder.leaf(.data, name: name, preview: byteCount(data.count), span: .unknown)
            default:
                // Keyed-archive UIDs and anything else CF hands back: shown as text, never interpreted.
                let (preview, cut) = builder.previewText(String(describing: value)[...])
                builder.leaf(.string, name: name, preview: preview, truncated: cut, span: .unknown)
            }
        }
    }

    static func byteCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 byte", bundle: .module, comment: "Preview of a data value in a property list: its exact length.")
            : String(localized: "\(n.formatted()) bytes", bundle: .module, comment: "Preview of a data value in a property list: its exact length (not 1).")
    }
}

/// Reads `<plist>` XML in document order: `dict`, `array`, `key`, `string`, `integer`, `real`, `true`, `false`,
/// `date`, `data`.
private final class PlistXMLDelegate: NSObject, XMLParserDelegate {
    var builder: StructuredTreeBuilder
    let options: StructuredOptions
    private let expansionLimit: Int64
    private var delivered: Int64 = 0
    private(set) var abortedForExpansion = false
    private(set) var firstError: StructuredDiagnostic?
    private(set) var structureError: StructuredDiagnostic?

    private struct Frame { var isDict: Bool; var pendingKey: String?; var expectingKey = true }
    private var frames: [Frame] = []
    private var collecting: String?
    private var text: [UInt8] = []
    private var textCut = false
    private var base64Characters = 0
    private var line = 0, column = 0

    init(options: StructuredOptions, inputBytes: Int64) {
        self.options = options
        builder = StructuredTreeBuilder(options: options, pathStyle: .jsonPath)
        expansionLimit = inputBytes * max(1, options.maxEntityExpansionRatio) + 1_048_576
    }

    private func fail(_ reason: String, _ parser: XMLParser) {
        guard structureError == nil else { return }
        structureError = StructuredDiagnostic(.error, reason, at: StructuredLocation(line: parser.lineNumber, column: parser.columnNumber))
        parser.abortParsing()
    }

    private func takeName(_ parser: XMLParser) -> String?? {
        guard let last = frames.indices.last else { return .some(nil) }
        guard frames[last].isDict else { return .some(nil) }
        guard let key = frames[last].pendingKey else {
            fail(String(localized: "a dictionary value needs a <key> before it", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), parser)
            return nil
        }
        frames[last].pendingKey = nil
        frames[last].expectingKey = true
        return .some(key)
    }

    private var span: StructuredSpan { StructuredSpan(line: line, column: column) }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        line = parser.lineNumber
        column = parser.columnNumber
        switch elementName {
        case "plist":
            break
        case "key":
            guard let last = frames.indices.last, frames[last].isDict, frames[last].expectingKey else {
                return fail(String(localized: "<key> is only allowed inside <dict>, before each value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), parser)
            }
            collecting = elementName
        case "dict", "array":
            guard let name = takeName(parser) else { return }
            builder.open(elementName == "dict" ? .object : .array, name: name, span: span)
            frames.append(Frame(isDict: elementName == "dict"))
        case "true", "false":
            guard let name = takeName(parser) else { return }
            builder.leaf(.bool, name: name, preview: elementName, span: span)
        case "string", "integer", "real", "date", "data":
            if let last = frames.indices.last, frames[last].isDict, frames[last].pendingKey == nil {
                return fail(String(localized: "a dictionary value needs a <key> before it", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), parser)
            }
            collecting = elementName
        default:
            fail(String(localized: "<\(elementName)> is not a property list element", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), parser)
        }
        text.removeAll(keepingCapacity: true)
        textCut = false
        base64Characters = 0
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "dict", "array":
            if !frames.isEmpty { frames.removeLast() }
            builder.close()
        case "key":
            var key = text
            if textCut { trimIncompleteUTF8(&key) }
            if let last = frames.indices.last {
                frames[last].pendingKey = String(decoding: key, as: UTF8.self) + (textCut ? "…" : "")
                frames[last].expectingKey = false
            }
        case "string", "integer", "real", "date", "data":
            guard let name = takeName(parser) else { return }
            var bytes = text
            if textCut { trimIncompleteUTF8(&bytes) }
            let value = String(decoding: bytes, as: UTF8.self)
            switch elementName {
            case "string": builder.leaf(.string, name: name, preview: value, truncated: textCut, span: span)
            case "integer", "real":
                let number = value.trimmingCharacters(in: .whitespacesAndNewlines)
                builder.leaf(.number, name: name, preview: number, truncated: textCut, span: span)
            case "date": builder.leaf(.date, name: name, preview: value.trimmingCharacters(in: .whitespacesAndNewlines), span: span)
            default: builder.leaf(.data, name: name, preview: PlistReader.byteCount(base64Characters * 3 / 4), span: span)
            }
        default:
            break
        }
        collecting = nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        delivered += Int64(string.utf8.count)
        if delivered > expansionLimit, !abortedForExpansion {
            abortedForExpansion = true
            parser.abortParsing()
            return
        }
        guard let collecting else { return }
        if collecting == "data" {
            for byte in string.utf8 where (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 43 || byte == 47 {
                base64Characters += 1
            }
            return
        }
        let limit = collecting == "key" ? options.maxKeyBytes : options.maxPreviewBytes
        let room = limit - text.count
        if room > 0 { text += string.utf8.prefix(room) }
        if string.utf8.count > max(0, room) { textCut = true }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard firstError == nil, structureError == nil, !abortedForExpansion else { return }
        firstError = XMLParser.diagnostic(parseError, line: parser.lineNumber, column: parser.columnNumber)
    }
}
