import Foundation

/// XML into the tree through Foundation's XMLParser, locked down for untrusted input (ARCHITECTURE §8): it is given
/// bytes, never a URL (so nothing relative can be fetched); external entities are never resolved and DTDs never
/// loaded (`externalEntityResolvingPolicy = .never`, `shouldResolveExternalEntities = false`, and the resolver
/// delegate returns nothing); and character data is metered, so internal entities that expand far past the input's
/// size (billion laughs) abort the parse with a coverage note.
///
/// Elements are `.object` nodes with `role: .element`; their attributes come first as `.attribute` children (in source
/// order, recovered by `XMLLexer`), then text, CDATA, comments, processing instructions and child elements in document
/// order. Namespaces are not processed: names keep their prefixes (`atom:link`) and `xmlns` declarations stay
/// attributes, which is what a reader of the file sees. Whitespace-only text between tags is formatting and is dropped.
enum XMLTreeReader {
    static func read(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        let startTags = data.withUnsafeBytes { raw -> (tags: [XMLLexer.StartTag], hasDTD: Bool) in
            XMLLexer.startTags(in: raw.bindMemory(to: UInt8.self))
        }
        let delegate = XMLTreeDelegate(options: options, startTags: startTags.tags, inputBytes: Int64(data.count))
        let parser = XMLParser.locked(data)
        parser.delegate = delegate
        let ok = parser.parse()

        var output = ReaderOutput(builder: delegate.builder, dialect: .xml)
        output.diagnostics = delegate.notes
        if startTags.hasDTD {
            output.note(StructuredDiagnostic(.warning, String(localized: "the document type declaration was read but not loaded or validated", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")),
                        cap: options.maxDiagnostics)
        }
        if delegate.internalEntityCount > 0 {
            let names = delegate.internalEntities.map { "&\($0);" }.joined(separator: ", ")
                + (delegate.internalEntityCount > delegate.internalEntities.count ? ", …" : "")
            output.note(StructuredDiagnostic(.unsupported, String(localized: "entities declared in the DTD (\(names)) are not expanded; their references are left out of the text", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")),
                        cap: options.maxDiagnostics)
        }
        if delegate.abortedForExpansion {
            output.extraLimits.append(.entityExpansionLimit)
        } else if !ok, let error = delegate.firstError ?? XMLParser.diagnostic(parser.parserError, line: parser.lineNumber, column: parser.columnNumber) {
            let lastLine = data.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }
            if truncated, (error.location?.line ?? 0) >= lastLine - 1 {
                output.endedEarly = true
            } else {
                output.fail(error, cap: options.maxDiagnostics)
            }
        }
        output.documentCount = 1
        return output
    }
}

extension XMLLexer {
    struct StartTag {
        var name: String
        var attributes: [String]
        var offset: Int
        var length: Int
        var line: Int
        var column: Int
    }

    /// Every start tag in document order, and whether a `<!DOCTYPE` was seen.
    static func startTags(in bytes: UnsafeBufferPointer<UInt8>) -> (tags: [StartTag], hasDTD: Bool) {
        var lexer = XMLLexer(bytes: bytes)
        var tags: [StartTag] = []
        var hasDTD = false
        while let token = lexer.next() {
            switch token.kind {
            case .startTag(let name, let attributes, _):
                tags.append(StartTag(name: name, attributes: attributes, offset: token.range.lowerBound,
                                     length: token.range.count, line: token.line, column: token.column))
            case .declaration:
                if !hasDTD, token.range.count >= 9 {
                    let head = String(decoding: UnsafeBufferPointer(rebasing: bytes[token.range.lowerBound..<(token.range.lowerBound + 9)]), as: UTF8.self)
                    hasDTD = head.uppercased() == "<!DOCTYPE"
                }
            default: break
            }
        }
        return (tags, hasDTD)
    }
}

extension XMLParser {
    /// A parser over bytes with every outward reach switched off.
    static func locked(_ data: Data) -> XMLParser {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        return parser
    }

    /// A short reason for an XMLParser error: libxml2's own message when it gave one ("Opening and ending tag
    /// mismatch: a line 1 and b"), else the error code's meaning.
    static func diagnostic(_ error: Error?, line: Int, column: Int) -> StructuredDiagnostic? {
        guard let error = error as NSError? else { return nil }
        var reason = (error.userInfo["NSXMLParserErrorMessage"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reason.isEmpty {
            switch XMLParser.ErrorCode(rawValue: error.code) {
            case .prematureDocumentEndError: reason = String(localized: "unexpected end of document", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .emptyDocumentError: reason = String(localized: "empty document", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .tagNameMismatchError: reason = String(localized: "the closing tag does not match the open element", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .attributeNotStartedError, .attributeNotFinishedError: reason = String(localized: "an attribute value must be quoted", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .ltRequiredError: reason = String(localized: "expected '<'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .gtRequiredError: reason = String(localized: "expected '>'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .entityRefLoopError, .entityReferenceWithoutNameError: reason = String(localized: "invalid entity reference", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .undeclaredEntityError: reason = String(localized: "undeclared entity", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            case .extraContentError: reason = String(localized: "content after the document element", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            default: reason = String(localized: "XML error \(error.code)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
            }
        }
        if let first = reason.first { reason = first.lowercased() + reason.dropFirst() }
        return StructuredDiagnostic(.error, reason, at: StructuredLocation(line: max(1, line), column: column > 0 ? column : nil))
    }
}

/// XMLParser's delegate: turns its callbacks into builder calls. Lives only for one synchronous parse.
private final class XMLTreeDelegate: NSObject, XMLParserDelegate {
    var builder: StructuredTreeBuilder
    let options: StructuredOptions
    private let startTags: [XMLLexer.StartTag]
    private var tagCursor = 0
    private var tagsAligned = true
    private let expansionLimit: Int64
    private var delivered: Int64 = 0
    private(set) var abortedForExpansion = false
    private(set) var firstError: StructuredDiagnostic?
    private(set) var notes: [StructuredDiagnostic] = []

    private var text: [UInt8] = []
    private var textHasContent = false
    private var textTruncated = false
    private var textLine = 0
    private var textColumn = 0
    /// Per open element: whether it has had a child other than an attribute (its text then is not its "value").
    private var hasContent: [Bool] = []

    init(options: StructuredOptions, startTags: [XMLLexer.StartTag], inputBytes: Int64) {
        self.options = options
        self.startTags = startTags
        builder = StructuredTreeBuilder(options: options, pathStyle: .xpath)
        expansionLimit = inputBytes * max(1, options.maxEntityExpansionRatio) + 1_048_576
    }

    private func meter(_ count: Int, _ parser: XMLParser) -> Bool {
        delivered += Int64(count)
        guard delivered > expansionLimit else { return true }
        if !abortedForExpansion {
            abortedForExpansion = true
            parser.abortParsing()
        }
        return false
    }

    private func flushText() {
        defer { text.removeAll(keepingCapacity: true); textHasContent = false; textTruncated = false }
        guard textHasContent else { return }
        let trimmed = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let (preview, cut) = builder.previewText(trimmed[...])
        markContent(textValue: preview, truncated: cut || textTruncated)
        builder.leaf(.string, role: .text, name: nil, preview: preview, truncated: cut || textTruncated,
                     span: StructuredSpan(line: textLine, column: textColumn))
    }

    /// The first text of an element without other content becomes the element's preview (`<title>Hi</title>` reads
    /// "title  Hi" in the outline).
    private func markContent(textValue: String? = nil, truncated: Bool = false) {
        guard let last = hasContent.indices.last else { return }
        if !hasContent[last], let textValue, let element = builder.currentContainer {
            builder.setPreview(element, textValue, truncated: truncated)
        }
        hasContent[last] = true
    }

    private func note(_ diagnostic: StructuredDiagnostic) {
        if notes.count < options.maxDiagnostics { notes.append(diagnostic) }
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        flushText()
        markContent()
        var span = StructuredSpan(line: parser.lineNumber, column: parser.columnNumber)
        var order = attributes.keys.sorted()
        if tagsAligned, tagCursor < startTags.count, startTags[tagCursor].name == elementName {
            let tag = startTags[tagCursor]
            span = StructuredSpan(byteOffset: Int64(tag.offset), byteLength: Int64(tag.length), line: tag.line, column: tag.column)
            let known = tag.attributes.filter { attributes[$0] != nil }
            order = known + order.filter { !known.contains($0) }
            tagCursor += 1
        } else {
            // Entity-expanded markup or input the lexer read differently: stop trusting the alignment.
            tagsAligned = false
        }
        builder.open(.object, role: .element, name: elementName, span: span)
        hasContent.append(false)
        for name in order {
            let value = attributes[name] ?? ""
            guard meter(value.utf8.count, parser) else { return }
            let (preview, cut) = builder.previewText(value[...])
            builder.leaf(.string, role: .attribute, name: name, preview: preview, truncated: cut, span: span)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        flushText()
        hasContent.removeLast()
        builder.close()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard meter(string.utf8.count, parser) else { return }
        if !textHasContent {
            textLine = parser.lineNumber
            textColumn = parser.columnNumber
        }
        if !textHasContent, string.allSatisfy({ $0.isWhitespace }) {
            // Keep leading whitespace out; it is formatting until real text arrives.
            return
        }
        textHasContent = true
        let room = options.maxPreviewBytes * 2 + 64 - text.count
        if room > 0 { text += string.utf8.prefix(room) } else { textTruncated = true }
        if string.utf8.count > room { textTruncated = true }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard meter(CDATABlock.count, parser) else { return }
        flushText()
        var bytes = [UInt8](CDATABlock.prefix(options.maxPreviewBytes))
        let cut = CDATABlock.count > options.maxPreviewBytes
        if cut { trimIncompleteUTF8(&bytes) }
        let preview = String(decoding: bytes, as: UTF8.self)
        markContent(textValue: preview, truncated: cut)
        builder.leaf(.string, role: .cdata, name: nil, preview: preview, truncated: cut,
                     span: StructuredSpan(line: parser.lineNumber, column: parser.columnNumber))
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        guard meter(comment.utf8.count, parser) else { return }
        flushText()
        markContent()
        let (preview, cut) = builder.previewText(comment.trimmingCharacters(in: .whitespacesAndNewlines)[...])
        builder.leaf(.string, role: .comment, name: nil, preview: preview, truncated: cut,
                     span: StructuredSpan(line: parser.lineNumber, column: parser.columnNumber))
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        flushText()
        markContent()
        let (preview, cut) = builder.previewText((data ?? "")[...])
        builder.leaf(.string, role: .processingInstruction, name: target, preview: preview, truncated: cut,
                     span: StructuredSpan(line: parser.lineNumber, column: parser.columnNumber))
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        note(StructuredDiagnostic(.warning, String(localized: "external entity '\(name)' was not loaded", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."),
                                  at: StructuredLocation(line: parser.lineNumber, column: parser.columnNumber)))
        return nil
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        note(StructuredDiagnostic(.warning, String(localized: "external entity '\(name)' is declared; it is never loaded", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."),
                                  at: StructuredLocation(line: parser.lineNumber, column: parser.columnNumber)))
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        if internalEntities.count < 3 { internalEntities.append(name) }
        internalEntityCount += 1
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard firstError == nil, !abortedForExpansion else { return }
        firstError = XMLParser.diagnostic(parseError, line: parser.lineNumber, column: parser.columnNumber)
    }

    /// Custom entities from the internal DTD subset. XMLParser substitutes them only when external entity resolution
    /// is on, which stays off; their references are left out of the text, and this says so.
    private(set) var internalEntities: [String] = []
    private(set) var internalEntityCount = 0
}
