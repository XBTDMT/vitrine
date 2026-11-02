import Foundation

/// What an SVG file holds, read without drawing it, running it or loading anything (D-4, data design "SVG preview"):
/// its size (width, height, viewBox), how many elements and how deep, and everything risky inside — script elements,
/// `on…` event handlers, `javascript:` links, `<foreignObject>` HTML, references to files or URLs outside the file,
/// and XML entity declarations. It also says whether the file is well-formed XML with an `<svg>` root, with the line
/// and column of the first problem, because a file that is not is shown as its source rather than as a picture.
///
/// The scan runs over the bytes with the module's forgiving `XMLLexer` (it never expands entities and never fetches),
/// so its cost is linear in the input and a deep or huge file cannot make it recurse or allocate past the input.
/// roadmap: S-6
public struct SVGScan: Sendable, Equatable {
    /// The first reason the file is not a well-formed SVG, at a 1-based line and byte column.
    public struct Problem: Sendable, Equatable {
        public var message: String
        public var line: Int
        public var column: Int
    }

    /// The root element's name as written (`svg`, `svg:svg`); nil when there is none.
    public var rootName: String?
    /// The root's `width` and `height` attributes as written (`240`, `10cm`, `100%`).
    public var width: String?
    public var height: String?
    /// The root's `viewBox`: min-x, min-y, width, height.
    public var viewBox: [Double]?
    /// Start tags, self-closing ones included.
    public var elements = 0
    public var maxDepth = 0
    public var scripts = 0
    public var eventHandlers = 0
    public var javascriptURLs = 0
    public var foreignObjects = 0
    /// href / src values and CSS `url(…)` / `@import` targets that point outside the file (not `#id`, not `data:`).
    public var externalRefs = 0
    /// The first few external targets, shortened, for the warning's detail.
    public var externalExamples: [String] = []
    /// `<!ENTITY …>` declarations in the document type declaration.
    public var entityDeclarations = 0
    /// The root declares the SVG namespace (as the default namespace, or the prefix it uses).
    public var hasSVGNamespace = false
    /// The root has a default `xmlns` of any value.
    public var hasDefaultNamespace = false
    /// An `xlink:` attribute is used but `xmlns:xlink` is declared nowhere.
    public var usesUndeclaredXLink = false
    /// Byte offset just after the root's name in its start tag, where missing namespace declarations go.
    public var rootNameEnd: Int?
    public var problem: Problem?
    /// The scan saw only the start of the file; unclosed elements at the end are not a problem then.
    public var truncated = false

    public var isWellFormed: Bool { problem == nil }
    public var isSVG: Bool { rootName.map { SVGScanner.localName($0) == "svg" } ?? false }
    /// Anything that would run if the file were opened somewhere that runs it.
    public var scriptLike: Int { scripts + eventHandlers + javascriptURLs }

    /// "128 × 128": the root's width and height when both are plain numbers (or px), else the viewBox's size.
    public var dimensions: String? {
        if let w = width.flatMap(SVGScanner.pixels), let h = height.flatMap(SVGScanner.pixels) {
            return "\(SVGScanner.format(w)) × \(SVGScanner.format(h))"
        }
        if let vb = viewBox { return "\(SVGScanner.format(vb[2])) × \(SVGScanner.format(vb[3]))" }
        return nil
    }

    /// Width over height for laying the picture out, from the viewBox first (it is what the drawing is scaled from).
    public var aspectRatio: Double? {
        if let vb = viewBox, vb[2] > 0, vb[3] > 0 { return vb[2] / vb[3] }
        if let w = width.flatMap(SVGScanner.pixels), let h = height.flatMap(SVGScanner.pixels), w > 0, h > 0 { return w / h }
        return nil
    }
}

/// One coloured run of SVG source, in UTF-16 offsets of the text it was made from (what NSTextView counts in).
public struct SVGSyntaxSpan: Sendable, Equatable {
    public enum Role: UInt8, Sendable { case punctuation, tagName, attributeName, attributeValue, comment, declaration, cdata, entity }
    public var range: Range<Int>
    public var role: Role
}

public enum SVGScanner {
    static let svgNamespace = "http://www.w3.org/2000/svg"
    static let xlinkNamespace = "http://www.w3.org/1999/xlink"
    private static let maxExamples = 3

    // MARK: Scan

    /// Scans `data`; pass `truncated` when it is only the start of the file.
    public static func scan(_ data: Data, truncated: Bool = false) -> SVGScan {
        var scan = SVGScan()
        scan.truncated = truncated
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var state = ScanState()
            var lexer = XMLLexer(bytes: b)
            var lastLine = 1, lastColumn = 1
            while let token = lexer.next() {
                lastLine = token.line; lastColumn = token.column
                visit(token, in: b, scan: &scan, state: &state)
            }
            if !truncated {
                if let open = state.stack.last {
                    fail(&scan, String(localized: "<\(open)> is never closed", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), lastLine, lastColumn)
                } else if scan.rootName == nil {
                    fail(&scan, String(localized: "there is no root element", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), lastLine, lastColumn)
                }
            }
            scan.usesUndeclaredXLink = state.usesXLink && !state.declaresXLink
        }
        if scan.problem == nil, scan.rootName != nil, !scan.isSVG {
            scan.problem = SVGScan.Problem(message: String(localized: "the root element is <\(scan.rootName ?? "")>, not <svg>", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), line: 1, column: 1)
        }
        return scan
    }

    private struct ScanState {
        var stack: [String] = []
        var rootClosed = false
        var declaredEntities: Set<String> = []
        var inStyle = false
        var usesXLink = false
        var declaresXLink = false
    }

    private static func fail(_ scan: inout SVGScan, _ message: String, _ line: Int, _ column: Int) {
        if scan.problem == nil { scan.problem = SVGScan.Problem(message: message, line: line, column: column) }
    }

    private static func visit(_ t: XMLToken, in b: UnsafeBufferPointer<UInt8>, scan: inout SVGScan, state: inout ScanState) {
        let text = { String(decoding: UnsafeBufferPointer(rebasing: b[t.range]), as: UTF8.self) }
        if t.unterminated, !scan.truncated {
            let what: String
            switch t.kind {
            case .comment: what = String(localized: "a comment", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            case .cdata: what = String(localized: "a CDATA section", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            case .processingInstruction: what = String(localized: "a processing instruction", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            case .declaration: what = String(localized: "a declaration", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            case .startTag(let name, _, _): what = String(localized: "the <\(name)> tag", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            case .endTag(let name): what = String(localized: "the </\(name)> tag", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            case .text: what = String(localized: "text", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            }
            fail(&scan, String(localized: "\(what) is never finished", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column)
        }
        switch t.kind {
        case .declaration:
            let s = text()
            if scan.rootName != nil { fail(&scan, String(localized: "a declaration inside the document", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column) }
            for name in entityNames(in: s) {
                scan.entityDeclarations += 1
                state.declaredEntities.insert(name)
            }
        case .processingInstruction:
            // <?xml-stylesheet href="…"?> is a load the file asks for.
            let s = text()
            if s.hasPrefix("<?xml-stylesheet"), let href = pseudoAttribute("href", in: s) { classify(href, scan: &scan) }
        case .comment:
            break
        case .cdata:
            if state.stack.isEmpty { fail(&scan, String(localized: "CDATA outside the root element", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column) }
            if state.inStyle { scanCSS(text(), scan: &scan) }
        case .text:
            let s = text()
            if state.stack.isEmpty {
                if s.contains(where: { !$0.isWhitespace }) { fail(&scan, String(localized: "text outside the root element", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column) }
                return
            }
            if let bad = badEntity(in: s, declared: state.declaredEntities) { fail(&scan, bad, t.line, t.column) }
            if state.inStyle { scanCSS(s, scan: &scan) }
        case .startTag(let name, _, let selfClosing):
            let isRoot = state.stack.isEmpty
            if isRoot {
                if state.rootClosed || scan.rootName != nil {
                    fail(&scan, String(localized: "a second root element <\(name)>", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column)
                } else {
                    scan.rootName = name
                    scan.rootNameEnd = t.range.lowerBound + 1 + name.utf8.count
                }
            }
            scan.elements += 1
            let local = localName(name)
            switch local {
            case "script": scan.scripts += 1
            case "foreignObject": scan.foreignObjects += 1
            case "style": state.inStyle = !selfClosing
            default: break
            }
            let (attributes, problem) = parseAttributes(in: b, tag: t.range, nameLength: name.utf8.count)
            if let problem { fail(&scan, problem, t.line, t.column) }
            var seen: Set<String> = []
            for a in attributes {
                let attrName = String(decoding: UnsafeBufferPointer(rebasing: b[a.name]), as: UTF8.self)
                let value = a.value.map { String(decoding: UnsafeBufferPointer(rebasing: b[$0]), as: UTF8.self) } ?? ""
                if !seen.insert(attrName).inserted { fail(&scan, String(localized: "the attribute \(attrName) appears twice", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column) }
                if value.contains("<") { fail(&scan, String(localized: "a < inside the value of \(attrName)", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column) }
                if let bad = badEntity(in: value, declared: state.declaredEntities) { fail(&scan, bad, t.line, t.column) }
                inspect(attribute: attrName, value: value, element: local, isRoot: isRoot, rootName: name, scan: &scan, state: &state)
            }
            if selfClosing {
                scan.maxDepth = max(scan.maxDepth, state.stack.count + 1)
                if isRoot { state.rootClosed = true }
            } else {
                state.stack.append(name)
                scan.maxDepth = max(scan.maxDepth, state.stack.count)
            }
        case .endTag(let name):
            guard let open = state.stack.last else {
                fail(&scan, String(localized: "</\(name)> closes nothing", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column)
                return
            }
            if open != name {
                fail(&scan, String(localized: "</\(name)> where </\(open)> was expected", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are."), t.line, t.column)
                // Recover: close up to the matching element when there is one, so the counts stay sensible.
                if let i = state.stack.lastIndex(of: name) { state.stack.removeSubrange(i...) }
            } else {
                state.stack.removeLast()
            }
            if localName(name) == "style" { state.inStyle = false }
            if state.stack.isEmpty { state.rootClosed = true }
        }
    }

    private static func inspect(attribute name: String, value: String, element: String, isRoot: Bool, rootName: String,
                                scan: inout SVGScan, state: inout ScanState) {
        let lower = name.lowercased()
        if lower.hasPrefix("on"), lower.count > 2 { scan.eventHandlers += 1 }
        if lower == "xmlns:xlink" { state.declaresXLink = true }
        if lower.hasPrefix("xlink:") { state.usesXLink = true }
        if isRoot {
            switch lower {
            case "width": scan.width = value.trimmingCharacters(in: .whitespaces)
            case "height": scan.height = value.trimmingCharacters(in: .whitespaces)
            case "viewbox":
                let parts = value.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\n" || $0 == "\r" }).compactMap { Double($0) }
                if parts.count == 4 { scan.viewBox = parts }
            case "xmlns":
                scan.hasDefaultNamespace = true
                if value == svgNamespace, !rootName.contains(":") { scan.hasSVGNamespace = true }
            default:
                if lower.hasPrefix("xmlns:"), value == svgNamespace, rootName.hasPrefix(String(name.dropFirst(6)) + ":") {
                    scan.hasSVGNamespace = true
                }
            }
        }
        if lower == "href" || lower.hasSuffix(":href") || lower == "src" {
            classify(value, scan: &scan)
        } else if lower == "style" {
            scanCSS(value, scan: &scan)
        } else if ["to", "from", "by", "values"].contains(lower), value.lowercased().contains("javascript:") {
            scan.javascriptURLs += 1
        }
    }

    /// Sorts one reference: in-file (`#id`, empty), embedded (`data:`), script (`javascript:`), or external.
    private static func classify(_ raw: String, scan: inout SVGScan) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
        let lower = value.lowercased()
        if value.isEmpty || value.hasPrefix("#") || lower.hasPrefix("data:") { return }
        if lower.hasPrefix("javascript:") { scan.javascriptURLs += 1; return }
        scan.externalRefs += 1
        if scan.externalExamples.count < maxExamples {
            scan.externalExamples.append(value.count > 80 ? String(value.prefix(79)) + "…" : value)
        }
    }

    /// CSS `url(…)` targets and `@import` targets.
    private static func scanCSS(_ css: String, scan: inout SVGScan) {
        let lower = css.lowercased()
        var search = lower.startIndex
        while let r = lower.range(of: "url(", range: search..<lower.endIndex) {
            let close = lower[r.upperBound...].firstIndex(of: ")") ?? lower.endIndex
            classify(String(css[r.upperBound..<close]), scan: &scan)
            search = close
        }
        search = lower.startIndex
        while let r = lower.range(of: "@import", range: search..<lower.endIndex) {
            let rest = lower[r.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
            if let q = rest.first, q == "\"" || q == "'" {
                let start = rest.index(after: rest.startIndex)
                let end = rest[start...].firstIndex(of: q) ?? rest.endIndex
                classify(String(css[start..<end]), scan: &scan)
            }
            search = r.upperBound
        }
    }

    /// `<!ENTITY name …>` names in a document type declaration (parameter entities `% name` included).
    static func entityNames(in declaration: String) -> [String] {
        var names: [String] = []
        var search = declaration.startIndex
        while let r = declaration.range(of: "<!ENTITY", range: search..<declaration.endIndex) {
            var rest = declaration[r.upperBound...].drop(while: { $0.isWhitespace })
            if rest.first == "%" { rest = rest.dropFirst().drop(while: { $0.isWhitespace }) }
            let name = rest.prefix(while: { !$0.isWhitespace && $0 != ">" })
            if !name.isEmpty { names.append(String(name)) }
            search = r.upperBound
        }
        return names
    }

    /// The first entity reference XML would refuse: a bare `&`, or a name that is neither predefined nor declared.
    static func badEntity(in s: String, declared: Set<String>) -> String? {
        guard s.contains("&") else { return nil }
        var i = s.startIndex
        while let amp = s[i...].firstIndex(of: "&") {
            let after = s.index(after: amp)
            guard let semi = s[after...].prefix(64).firstIndex(of: ";") else { return String(localized: "a bare & (write &amp;)", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.") }
            let name = s[after..<semi]
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                if name.count < 3 || !name.dropFirst(2).allSatisfy(\.isHexDigit) { return String(localized: "a malformed character reference &\(name);", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.") }
            } else if name.hasPrefix("#") {
                if name.count < 2 || !name.dropFirst().allSatisfy(\.isASCII) || !name.dropFirst().allSatisfy(\.isNumber) { return String(localized: "a malformed character reference &\(name);", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.") }
            } else if name.isEmpty || name.contains(where: { $0.isWhitespace || $0 == "&" || $0 == "<" }) {
                return String(localized: "a bare & (write &amp;)", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            } else if !["amp", "lt", "gt", "quot", "apos"].contains(String(name)), !declared.contains(String(name)) {
                return String(localized: "the entity &\(name); is not declared", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.")
            }
            i = s.index(after: semi)
        }
        return nil
    }

    /// `href="…"` inside a processing instruction's text.
    private static func pseudoAttribute(_ name: String, in s: String) -> String? {
        guard let r = s.range(of: name + "=") else { return nil }
        let rest = s[r.upperBound...]
        guard let q = rest.first, q == "\"" || q == "'" else { return nil }
        let start = rest.index(after: rest.startIndex)
        guard let end = rest[start...].firstIndex(of: q) else { return nil }
        return String(rest[start..<end])
    }

    // MARK: Attributes

    struct Attribute {
        var name: Range<Int>
        /// The value without its quotes; nil when the attribute had no `=`.
        var value: Range<Int>?
        /// The value with its quotes, for colouring.
        var quotedValue: Range<Int>?
        var equals: Int?
    }

    /// The attributes of the start tag at `tag` (whose name is `nameLength` bytes after the `<`), and the first thing
    /// XML would refuse in it (a value without quotes, an attribute without a value).
    static func parseAttributes(in b: UnsafeBufferPointer<UInt8>, tag: Range<Int>, nameLength: Int) -> ([Attribute], String?) {
        var out: [Attribute] = []
        var problem: String?
        var p = tag.lowerBound + 1 + nameLength
        let end = tag.upperBound
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func isNameChar(_ c: UInt8) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 58 || c == 45 || c == 46 || c >= 0x80
        }
        while p < end {
            let c = b[p]
            if isSpace(c) || c == UInt8(ascii: "/") || c == UInt8(ascii: ">") { p += 1; continue }
            guard isNameChar(c) else { p += 1; continue }
            let nameStart = p
            while p < end, isNameChar(b[p]) { p += 1 }
            var attribute = Attribute(name: nameStart..<p)
            var q = p
            while q < end, isSpace(b[q]) { q += 1 }
            if q < end, b[q] == UInt8(ascii: "=") {
                attribute.equals = q
                q += 1
                while q < end, isSpace(b[q]) { q += 1 }
                if q < end, b[q] == 0x22 || b[q] == 0x27 {
                    let quote = b[q]
                    let valueStart = q + 1
                    var r = valueStart
                    while r < end, b[r] != quote { r += 1 }
                    attribute.value = valueStart..<min(r, end)
                    attribute.quotedValue = q..<min(r + 1, end)
                    p = min(r + 1, end)
                } else {
                    let valueStart = q
                    while q < end, !isSpace(b[q]), b[q] != UInt8(ascii: ">") { q += 1 }
                    attribute.value = valueStart..<q
                    attribute.quotedValue = valueStart..<q
                    p = q
                    if problem == nil { problem = String(localized: "an attribute value without quotes", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.") }
                }
            } else {
                p = q
                if problem == nil { problem = String(localized: "an attribute without a value", bundle: .module, comment: "A problem found in an SVG file's markup, shown in the preview; lower-case, no final period. Tags, attribute names and entities stay as they are.") }
            }
            out.append(attribute)
        }
        return (out, problem)
    }

    // MARK: Drawing input

    /// The bytes to draw: the file itself, with the namespace declarations a browser needs added to the root's start
    /// tag when the file leaves them out (many hand-written SVGs omit `xmlns`, and an undeclared `xlink:` prefix
    /// is an XML error). Nothing else is changed.
    public static func drawable(_ data: Data, scan: SVGScan) -> Data {
        guard let at = scan.rootNameEnd, at <= data.count, let root = scan.rootName else { return data }
        var insert = ""
        if !scan.hasDefaultNamespace, !root.contains(":") { insert += " xmlns=\"\(svgNamespace)\"" }
        if scan.usesUndeclaredXLink { insert += " xmlns:xlink=\"\(xlinkNamespace)\"" }
        guard !insert.isEmpty else { return data }
        var out = data
        out.insert(contentsOf: Data(insert.utf8), at: out.startIndex + at)
        return out
    }

    // MARK: Syntax colours

    /// Coloured runs for the first `limit` bytes of `text`, as XML: tag names, attribute names and values,
    /// punctuation, comments, declarations, CDATA and entity references. Plain text between tags gets no run.
    public static func syntaxSpans(_ text: String, limit: Int = .max) -> [SVGSyntaxSpan] {
        let utf8 = Array(text.utf8.prefix(limit))
        // Byte offset → UTF-16 offset: one step per scalar start, two for a 4-byte scalar (a surrogate pair).
        var utf16 = [Int](repeating: 0, count: utf8.count + 1)
        var u = 0
        for (i, byte) in utf8.enumerated() {
            utf16[i] = u
            if byte & 0xC0 != 0x80 { u += byte >= 0xF0 ? 2 : 1 }
        }
        utf16[utf8.count] = u
        var spans: [SVGSyntaxSpan] = []
        func add(_ r: Range<Int>, _ role: SVGSyntaxSpan.Role) {
            guard !r.isEmpty, r.upperBound <= utf8.count else { return }
            spans.append(SVGSyntaxSpan(range: utf16[r.lowerBound]..<utf16[r.upperBound], role: role))
        }
        utf8.withUnsafeBufferPointer { b in
            var lexer = XMLLexer(bytes: b)
            while let t = lexer.next() {
                let r = t.range
                switch t.kind {
                case .comment: add(r, .comment)
                case .processingInstruction, .declaration: add(r, .declaration)
                case .cdata: add(r, .cdata)
                case .text:
                    var p = r.lowerBound
                    while p < r.upperBound {
                        if b[p] == UInt8(ascii: "&") {
                            var q = p + 1
                            while q < r.upperBound, q - p < 64, b[q] != UInt8(ascii: ";"), b[q] != UInt8(ascii: "<") { q += 1 }
                            if q < r.upperBound, b[q] == UInt8(ascii: ";") { add(p..<(q + 1), .entity); p = q + 1; continue }
                        }
                        p += 1
                    }
                case .endTag(let name):
                    add(r.lowerBound..<min(r.lowerBound + 2, r.upperBound), .punctuation)
                    add((r.lowerBound + 2)..<min(r.lowerBound + 2 + name.utf8.count, r.upperBound), .tagName)
                    if r.upperBound - 1 >= r.lowerBound + 2 + name.utf8.count, b[r.upperBound - 1] == UInt8(ascii: ">") {
                        add((r.upperBound - 1)..<r.upperBound, .punctuation)
                    }
                case .startTag(let name, _, _):
                    let nameEnd = min(r.lowerBound + 1 + name.utf8.count, r.upperBound)
                    add(r.lowerBound..<(r.lowerBound + 1), .punctuation)
                    add((r.lowerBound + 1)..<nameEnd, .tagName)
                    let (attributes, _) = parseAttributes(in: b, tag: r, nameLength: name.utf8.count)
                    for a in attributes {
                        add(a.name, .attributeName)
                        if let e = a.equals { add(e..<(e + 1), .punctuation) }
                        if let v = a.quotedValue { add(v, .attributeValue) }
                    }
                    var close = r.upperBound
                    if close > nameEnd, b[close - 1] == UInt8(ascii: ">") {
                        close -= 1
                        if close > nameEnd, b[close - 1] == UInt8(ascii: "/") { close -= 1 }
                        add(close..<r.upperBound, .punctuation)
                    }
                }
            }
        }
        return spans
    }

    // MARK: Helpers

    /// `svg:rect` → `rect`.
    public static func localName(_ name: String) -> String {
        name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
    }

    /// A length in user units when it is a plain number or px; nil for %, em, cm and the like.
    static func pixels(_ value: String) -> Double? {
        let v = value.hasSuffix("px") ? String(value.dropLast(2)) : value
        return Double(v.trimmingCharacters(in: .whitespaces))
    }

    /// 128 → "128", 12.5 → "12.5", 1200 → "1,200".
    static func format(_ n: Double) -> String {
        n.rounded() == n ? Int(n).formatted() : n.formatted(.number.precision(.fractionLength(0...2)))
    }
}
