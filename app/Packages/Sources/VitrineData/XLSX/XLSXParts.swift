import Foundation

/// The small SpreadsheetML parts (ECMA-376 Part 1 §18: relationships, workbook, shared strings, styles) read with
/// XMLParser. Element names are matched by their local name, so a writer's namespace prefix does not matter.
/// roadmap: S-21
enum XLSXParts {
    struct Relationship { var id: String; var type: String; var target: String }
    struct WorkbookSheet { var name: String; var relationship: String; var hidden: Bool }

    /// Refuses a part that declares a DTD: SpreadsheetML never does, and entities are the only way XML can grow.
    static func checkNoDTD(_ data: Data) throws {
        let head = data.prefix(8_192)
        if head.range(of: Data("<!DOCTYPE".utf8)) != nil || head.range(of: Data("<!ENTITY".utf8)) != nil {
            throw ColumnarError.unsupported(String(localized: "an XML part that declares a DTD", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
    }

    static func local(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// An XMLParser run with `start`, `end` and `text` callbacks on local names; throws the parser's error.
    final class Walker: NSObject, XMLParserDelegate {
        var start: ((String, [String: String]) -> Void)?
        var end: ((String) -> Void)?
        var text: ((String) -> Void)?
        var stop: (() -> Bool)?
        private(set) var failure: Error?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            start?(XLSXParts.local(elementName), attributeDict)
            if stop?() == true { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            end?(XLSXParts.local(elementName))
            if stop?() == true { parser.abortParsing() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text?(string) }
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { if failure == nil { failure = parseError } }
    }

    /// Runs `walker` over `data`. A parse stopped by `walker.stop` is not an error.
    static func run(_ data: Data, _ walker: Walker, what: String) throws {
        try checkNoDTD(data)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = walker
        let ok = parser.parse()
        if !ok, walker.stop?() != true {
            throw ColumnarError.malformed(String(localized: "\(what) is not well-formed XML (\(walker.failure?.localizedDescription ?? String(localized: "parse error", bundle: .module, comment: "Fallback when the XML parser gives no reason."))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
    }

    static func relationships(_ data: Data) -> [Relationship] {
        let w = Walker()
        var out: [Relationship] = []
        w.start = { name, a in
            if name == "Relationship", let id = a["Id"], let target = a["Target"] {
                out.append(Relationship(id: id, type: a["Type"] ?? "", target: target))
            }
        }
        try? run(data, w, what: String(localized: "a relationships part", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        return out
    }

    /// `target` relative to the folder `base` ("xl"), or absolute from the package root ("/xl/…").
    static func resolve(_ target: String, base: String) -> String {
        var parts: [String] = target.hasPrefix("/") ? [] : base.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
        }
        return parts.joined(separator: "/")
    }

    static func workbook(_ data: Data) throws -> (sheets: [WorkbookSheet], date1904: Bool) {
        let w = Walker()
        var sheets: [WorkbookSheet] = []
        var date1904 = false
        w.start = { name, a in
            switch name {
            case "workbookPr": date1904 = ["1", "true"].contains(a["date1904"]?.lowercased() ?? "")
            case "sheet":
                let rel = a.first { $0.key == "id" || $0.key.hasSuffix(":id") }?.value ?? ""
                sheets.append(WorkbookSheet(name: a["name"] ?? String(localized: "Sheet \(sheets.count + 1)", bundle: .module, comment: "Name of a workbook sheet that has none; the argument is its 1-based number."), relationship: rel,
                                            hidden: (a["state"] ?? "visible") != "visible"))
            default: break
            }
        }
        try run(data, w, what: String(localized: "the workbook part", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        return (sheets, date1904)
    }

    /// The shared string table (`<sst><si>`): each item's text runs joined, phonetic runs (`<rPh>`) left out.
    static func sharedStrings(_ data: Data, limit: Int) throws -> [String] {
        let w = Walker()
        var out: [String] = []
        var current = ""
        var inItem = false, inText = false, inPhonetic = false
        var overflow = false
        w.start = { name, _ in
            switch name {
            case "si": inItem = true; current = ""
            case "t": inText = inItem && !inPhonetic
            case "rPh": inPhonetic = true
            default: break
            }
        }
        w.end = { name in
            switch name {
            case "si":
                inItem = false
                if out.count < limit { out.append(current) } else { overflow = true }
            case "t": inText = false
            case "rPh": inPhonetic = false
            default: break
            }
        }
        w.text = { s in if inText { current += s } }
        w.stop = { overflow }
        try run(data, w, what: String(localized: "the shared strings part", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        if overflow { throw ColumnarError.tooLarge(String(localized: "more than \(limit.formatted()) shared strings", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return out
    }

    /// What each cell format (`<cellXfs><xf numFmtId>`) shows: a number, a date (with or without a time), or a time
    /// of day alone.
    enum NumberStyle: Sendable { case number, date, time }

    static func dateStyles(_ data: Data) throws -> [NumberStyle] {
        let w = Walker()
        var custom: [Int: String] = [:]
        var formats: [Int] = []
        var inCellXfs = false
        w.start = { name, a in
            switch name {
            case "numFmt": if let id = a["numFmtId"].flatMap(Int.init) { custom[id] = a["formatCode"] ?? "" }
            case "cellXfs": inCellXfs = true
            case "xf": if inCellXfs { formats.append(a["numFmtId"].flatMap(Int.init) ?? 0) }
            default: break
            }
        }
        w.end = { name in if name == "cellXfs" { inCellXfs = false } }
        try run(data, w, what: String(localized: "the styles part", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        return formats.map { id in
            if let code = custom[id] { return isDateFormat(code) ? (isTimeOnly(code) ? .time : .date) : .number }
            if builtInTimeFormats.contains(id) { return .time }
            return builtInDateFormats.contains(id) ? .date : .number
        }
    }

    static let builtInTimeFormats: Set<Int> = [18, 19, 20, 21, 45, 46, 47]

    /// A date format with hours or seconds but no year or day.
    static func isTimeOnly(_ code: String) -> Bool {
        var plain = ""
        var inQuote = false
        for ch in code.lowercased() {
            if ch == "\"" { inQuote.toggle(); continue }
            if !inQuote { plain.append(ch) }
        }
        let section = plain.split(separator: ";").first.map(String.init) ?? ""
        return (section.contains("h") || section.contains("s")) && !section.contains("y") && !section.contains("d")
    }

    /// Built-in number formats that are dates or times (ECMA-376 Part 1 §18.8.30, and the East Asian ones).
    static let builtInDateFormats: Set<Int> = Set(14...22).union(27...36).union(45...47).union(50...58)

    /// A format code shows a date when it has day, month, year, hour or second tokens outside quoted text, escapes
    /// and brackets (`[Red]`, `[$-409]`); elapsed-time brackets (`[h]`, `[mm]`) count.
    static func isDateFormat(_ code: String) -> Bool {
        var stripped = ""
        var inQuote = false, inBracket = false, escape = false
        var bracket = ""
        for ch in code {
            if escape { escape = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket {
                if ch == "]" {
                    inBracket = false
                    if bracket.lowercased().allSatisfy({ "hms".contains($0) }), !bracket.isEmpty { stripped += "h" }
                } else { bracket.append(ch) }
                continue
            }
            switch ch {
            case "\\", "_", "*": escape = true
            case "\"": inQuote = true
            case "[": inBracket = true; bracket = ""
            default: stripped.append(ch)
            }
        }
        let section = stripped.split(separator: ";").first.map(String.init)?.lowercased() ?? ""
        return section.contains { "ymdhs".contains($0) } && !section.contains("general")
    }

    /// The used range a worksheet states, from its first bytes.
    static func dimension(_ head: Data) -> String? {
        let text = String(decoding: head, as: UTF8.self)
        guard let r = text.range(of: "<dimension ref=\"") ?? text.range(of: ":dimension ref=\"") else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Rows a dimension such as "A1:H120" spans.
    static func rows(inDimension ref: String) -> Int? {
        let ends = ref.split(separator: ":").map { XLSXCellReference.parse(String($0)) }
        guard let first = ends.first??.row else { return nil }
        let last = (ends.count > 1 ? ends[1]?.row : first) ?? first
        return max(0, last - first + 1)
    }

    /// The writing application from `docProps/app.xml`.
    static func application(_ data: Data) -> String? {
        let w = Walker()
        var name: String?, version: String?
        var field = ""
        var buffer = ""
        w.start = { n, _ in field = n; buffer = "" }
        w.text = { buffer += $0 }
        w.end = { n in
            if n == "Application", field == "Application" { name = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
            if n == "AppVersion", field == "AppVersion" { version = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        try? run(data, w, what: "docProps/app.xml")
        guard let name, !name.isEmpty else { return nil }
        return version.map { "\(name) \($0)" } ?? name
    }
}

/// "AB12" → column 27 (0-based), row 12 (1-based).
enum XLSXCellReference {
    static func parse(_ ref: String) -> (column: Int, row: Int?)? {
        var column = 0, letters = 0
        var row = 0, digits = 0
        for u in ref.utf8 {
            switch u {
            case UInt8(ascii: "$"): continue
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"):
                guard digits == 0, letters < 4 else { return nil }
                column = column * 26 + Int((u | 0x20) - UInt8(ascii: "a")) + 1
                letters += 1
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                guard digits < 8 else { return nil }
                row = row * 10 + Int(u - UInt8(ascii: "0"))
                digits += 1
            default: return nil
            }
        }
        guard letters > 0 else { return nil }
        return (column - 1, digits > 0 ? row : nil)
    }

    /// 0 → "A", 27 → "AB".
    static func letters(_ column: Int) -> String {
        var n = column + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }
}
