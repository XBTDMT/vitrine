import Foundation

/// A small element tree built with Foundation's `XMLParser` for the XML a package carries (the xar table of
/// contents, Distribution, PackageInfo). External entities are never resolved, input size is capped by the caller,
/// and depth and element count are capped here, so a hostile document costs a bounded amount.
struct MarkupElement: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    var children: [MarkupElement]
    var text: String

    /// The first child with `name`.
    func child(_ name: String) -> MarkupElement? { children.first { $0.name == name } }
    /// Every child with `name`.
    func children(_ name: String) -> [MarkupElement] { children.filter { $0.name == name } }
    /// The trimmed text of the first child with `name`.
    func value(_ name: String) -> String? {
        child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    /// Every descendant (depth first) with `name`.
    func descendants(_ name: String) -> [MarkupElement] {
        var out: [MarkupElement] = []
        var stack = Array(children.reversed())
        while let next = stack.popLast() {
            if next.name == name { out.append(next) }
            stack.append(contentsOf: next.children.reversed())
        }
        return out
    }

    static let maxDepth = 128
    static let maxElements = 500_000

    static func parse(_ bytes: [UInt8], what: String) throws -> MarkupElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: Data(bytes))
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        let ok = parser.parse()
        if let limit = builder.limitHit { throw BinaryError.unsupported("\(what) \(limit)") }
        guard ok, let root = builder.root else { throw BinaryError.malformed("\(what) is not well-formed XML") }
        return root
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [MarkupElement] = []
        var root: MarkupElement?
        var count = 0
        var limitHit: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            count += 1
            if count > MarkupElement.maxElements { limitHit = "holds more than \(MarkupElement.maxElements) elements" }
            if stack.count >= MarkupElement.maxDepth { limitHit = "nests deeper than \(MarkupElement.maxDepth) elements" }
            if limitHit != nil { parser.abortParsing(); return }
            stack.append(MarkupElement(name: elementName, attributes: attributeDict, children: [], text: ""))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let done = stack.popLast() else { return }
            if stack.isEmpty { root = done } else { stack[stack.count - 1].children.append(done) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty, stack[stack.count - 1].text.utf8.count < 16 * 1024 * 1024 else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}
