import Foundation

extension JQValue {
    /// One-line JSON, as `jq -c` prints it: no spaces, keys in insertion order, numbers as jq 1.7 prints doubles.
    public func compactJSON() -> String { JQJSONWriter.text(self, indent: nil) }

    /// Indented JSON, as `jq --indent n` prints it (`indent` 0 gives the compact form, like jq).
    public func prettyJSON(indent: Int = 2) -> String {
        JQJSONWriter.text(self, indent: indent > 0 ? min(indent, 7) : nil)
    }

    /// Parses one JSON text (RFC 8259, plus jq's `nan`/`NaN` literal) into a value with full fidelity: whole strings,
    /// numbers as doubles. Iterative, so nesting costs heap, never stack; deeper than `maxDepth` is an error.
    public init(json text: String, maxDepth: Int = 1024) throws {
        self = try JQJSONReader.parse(Array(text.utf8), maxDepth: maxDepth)
    }

    /// `init(json:)` over bytes (UTF-8; invalid sequences become U+FFFD, as jq reads them).
    public init(json data: Data, maxDepth: Int = 1024) throws {
        self = try data.withUnsafeBytes { raw in
            try JQJSONReader.parse(raw.bindMemory(to: UInt8.self), maxDepth: maxDepth)
        }
    }
}

/// How jq 1.7 prints a double: the shortest digits that read back to the same double, in plain notation unless the
/// decimal exponent is below -4 or the digits would need more than 15 padding zeros (then `1e+17`, `1e-05`, with at
/// least two exponent digits); `nan` prints as `null` and the infinities as the largest finite double.
/// roadmap: S-5
enum JQNumberFormat {
    static func format(_ d: Double) -> String {
        if d.isNaN { return "null" }
        if d.isInfinite { return d < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308" }
        if d == 0 { return d.sign == .minus ? "-0" : "0" }
        if d == d.rounded(.towardZero), abs(d) < 1e16 { return String(Int64(d)) }
        // Swift's description is the shortest round-trip representation; re-lay its digits jq's way.
        var text = Substring(d.description)
        var negative = false
        if text.first == "-" { negative = true; text = text.dropFirst() }
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        var digits = ""
        var pointPosition = text.count
        if let dot = text.firstIndex(of: ".") {
            pointPosition = text.distance(from: text.startIndex, to: dot)
            digits = String(text[..<dot]) + String(text[text.index(after: dot)...])
        } else {
            digits = String(text)
        }
        // value = 0.digits × 10^decpt
        var decpt = pointPosition + exponent
        while digits.first == "0" { digits.removeFirst(); decpt -= 1 }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        if digits.isEmpty { return negative ? "-0" : "0" }
        let n = digits.count
        var out = negative ? "-" : ""
        if decpt <= -4 || decpt > n + 15 {
            out.append(digits.first!)
            if n > 1 { out += "." + digits.dropFirst() }
            let e = decpt - 1
            out += e < 0 ? "e-" : "e+"
            let magnitude = abs(e)
            out += magnitude < 10 ? "0\(magnitude)" : "\(magnitude)"
        } else if decpt <= 0 {
            out += "0." + String(repeating: "0", count: -decpt) + digits
        } else if decpt >= n {
            out += digits + String(repeating: "0", count: decpt - n)
        } else {
            let split = digits.index(digits.startIndex, offsetBy: decpt)
            out += digits[..<split] + "." + digits[split...]
        }
        return out
    }
}

/// Writes values as JSON text, iteratively (an explicit stack, so depth costs heap). A byte budget stops a write that
/// would grow past it (tojson of a huge value). roadmap: S-5
enum JQJSONWriter {
    struct Overflow: Error {}

    static func text(_ value: JQValue, indent: Int?) -> String {
        var out: [UInt8] = []
        try? write(value, indent: indent, into: &out, budget: Int.max)
        return String(decoding: out, as: UTF8.self)
    }

    /// Compact text cut to `budget` bytes, or nil when it would be longer.
    static func compact(_ value: JQValue, budget: Int) -> String? {
        var out: [UInt8] = []
        do { try write(value, indent: nil, into: &out, budget: budget) } catch { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// The value as jq shows it inside an error message: compact JSON cut to 11 characters plus "..." when longer
    /// than 14 bytes.
    static func errorDump(_ value: JQValue) -> String {
        var out: [UInt8] = []
        let full = (try? write(value, indent: nil, into: &out, budget: 64)) != nil
        if full && out.count <= 14 { return String(decoding: out, as: UTF8.self) }
        var cut = min(11, out.count)
        while cut > 0, cut < out.count, out[cut] & 0xC0 == 0x80 { cut -= 1 }
        return String(decoding: out[..<cut], as: UTF8.self) + "..."
    }

    private enum Frame {
        case array([JQValue], Int)
        case object(JQObject, Int)
    }

    static func write(_ root: JQValue, indent: Int?, into out: inout [UInt8], budget: Int) throws {
        var stack: [Frame] = []
        var pending: JQValue? = root

        func newline(_ level: Int) {
            guard let indent else { return }
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: level * indent))
        }

        while true {
            if out.count > budget { throw Overflow() }
            if let value = pending {
                pending = nil
                switch value {
                case .null: out.append(contentsOf: Array("null".utf8))
                case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
                case .number(let d): out.append(contentsOf: Array(JQNumberFormat.format(d).utf8))
                case .string(let s): appendString(s, to: &out)
                case .array(let items):
                    out.append(UInt8(ascii: "["))
                    if items.isEmpty { out.append(UInt8(ascii: "]")) } else { stack.append(.array(items, 0)) }
                case .object(let object):
                    out.append(UInt8(ascii: "{"))
                    if object.isEmpty { out.append(UInt8(ascii: "}")) } else { stack.append(.object(object, 0)) }
                }
                continue
            }
            guard let top = stack.popLast() else { return }
            switch top {
            case .array(let items, let i):
                if i == items.count {
                    newline(stack.count)
                    out.append(UInt8(ascii: "]"))
                    continue
                }
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(stack.count + 1)
                stack.append(.array(items, i + 1))
                pending = items[i]
            case .object(let object, let i):
                if i == object.count {
                    newline(stack.count)
                    out.append(UInt8(ascii: "}"))
                    continue
                }
                if i > 0 { out.append(UInt8(ascii: ",")) }
                newline(stack.count + 1)
                appendString(object.storage.keys[i], to: &out)
                out.append(UInt8(ascii: ":"))
                if indent != nil { out.append(0x20) }
                stack.append(.object(object, i + 1))
                pending = object.storage.values[i]
            }
        }
    }

    static func appendString(_ s: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        let hex = Array("0123456789abcdef".utf8)
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(0x5C); out.append(byte)
            case UInt8(ascii: "\\"): out.append(0x5C); out.append(byte)
            case 0x0A: out.append(0x5C); out.append(UInt8(ascii: "n"))
            case 0x09: out.append(0x5C); out.append(UInt8(ascii: "t"))
            case 0x0D: out.append(0x5C); out.append(UInt8(ascii: "r"))
            case 0x08: out.append(0x5C); out.append(UInt8(ascii: "b"))
            case 0x0C: out.append(0x5C); out.append(UInt8(ascii: "f"))
            case 0..<0x20, 0x7F:
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0xF)])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// A JSON reader straight into `JQValue`: strict RFC 8259 plus the `nan` literal jq accepts. Iterative.
/// roadmap: S-5
enum JQJSONReader {
    struct Failure: Error, Equatable {
        var message: String
    }

    static func parse(_ bytes: [UInt8], maxDepth: Int) throws -> JQValue {
        try bytes.withUnsafeBufferPointer { try parse($0, maxDepth: maxDepth) }
    }

    static func parse(_ b: UnsafeBufferPointer<UInt8>, maxDepth: Int) throws -> JQValue {
        var pos = 0
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { pos = 3 }
        // Open containers, innermost last. Arrays and objects sit on their own stacks and are mutated in place
        // (never copied out and back), so appending stays amortized O(1) however large a container grows.
        var isArray: [Bool] = []
        var arrays: [[JQValue]] = []
        var arrayDepths: [Int] = []
        var objects: [JQObject] = []
        var pendingKeys: [String?] = []
        var result: JQValue?

        func fail(_ message: String) -> Failure {
            var line = 1, column = 1
            for i in 0..<min(pos, b.count) {
                if b[i] == 0x0A { line += 1; column = 1 } else if b[i] & 0xC0 != 0x80 { column += 1 }
            }
            return Failure(message: "\(message) at line \(line), column \(column)")
        }

        func skipSpace() {
            while pos < b.count, b[pos] == 0x20 || b[pos] == 0x0A || b[pos] == 0x0D || b[pos] == 0x09 { pos += 1 }
        }

        func literal(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard pos + w.count <= b.count else { return false }
            for i in 0..<w.count where b[pos + i] != w[i] { return false }
            pos += w.count
            return true
        }

        func readString() throws -> String {
            pos += 1  // opening quote
            let start = pos
            while pos < b.count {
                let c = b[pos]
                if c == UInt8(ascii: "\"") {
                    let s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<pos]), as: UTF8.self)
                    pos += 1
                    return s
                }
                if c == UInt8(ascii: "\\") || c < 0x20 { break }
                pos += 1
            }
            var buffer = Array(b[start..<pos])
            while pos < b.count {
                let c = b[pos]
                if c == UInt8(ascii: "\"") {
                    pos += 1
                    return String(decoding: buffer, as: UTF8.self)
                }
                if c < 0x20 { throw fail("unescaped control character in a string") }
                if c != UInt8(ascii: "\\") { buffer.append(c); pos += 1; continue }
                pos += 1
                guard pos < b.count else { break }
                let e = b[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar), pos + 1 < b.count, b[pos] == 0x5C, b[pos + 1] == UInt8(ascii: "u") {
                        let save = pos
                        pos += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            pos = save
                        }
                    }
                    let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw fail("invalid escape in a string")
                }
            }
            throw fail("unfinished string")
        }

        func hex4() throws -> UInt32 {
            guard pos + 4 <= b.count else { throw fail("invalid \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[pos]
                let d: UInt8
                switch c {
                case 0x30...0x39: d = c - 0x30
                case 0x41...0x46: d = c - 0x41 + 10
                case 0x61...0x66: d = c - 0x61 + 10
                default: throw fail("invalid \\u escape")
                }
                v = v << 4 | UInt32(d)
                pos += 1
            }
            return v
        }

        func readNumber() throws -> Double {
            let start = pos
            if pos < b.count, b[pos] == UInt8(ascii: "-") { pos += 1 }
            let intStart = pos
            while pos < b.count, (0x30...0x39).contains(b[pos]) { pos += 1 }
            if pos == intStart { throw fail("invalid numeric literal") }
            if pos < b.count, b[pos] == UInt8(ascii: ".") {
                pos += 1
                let fracStart = pos
                while pos < b.count, (0x30...0x39).contains(b[pos]) { pos += 1 }
                if pos == fracStart { throw fail("invalid numeric literal") }
            }
            if pos < b.count, b[pos] == UInt8(ascii: "e") || b[pos] == UInt8(ascii: "E") {
                pos += 1
                if pos < b.count, b[pos] == UInt8(ascii: "+") || b[pos] == UInt8(ascii: "-") { pos += 1 }
                let expStart = pos
                while pos < b.count, (0x30...0x39).contains(b[pos]) { pos += 1 }
                if pos == expStart { throw fail("invalid numeric literal") }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<pos]), as: UTF8.self)
            guard let d = Double(text) else { throw fail("invalid numeric literal") }
            return d
        }

        /// Hands a finished value to its container (or makes it the result).
        func finish(_ value: JQValue, depth: Int) throws {
            guard let array = isArray.last else { result = value; return }
            if array {
                arrays[arrays.count - 1].append(value)
                if depth > arrayDepths[arrayDepths.count - 1] { arrayDepths[arrayDepths.count - 1] = depth }
            } else {
                objects[objects.count - 1].set(pendingKeys[pendingKeys.count - 1] ?? "", value, valueDepth: depth)
                pendingKeys[pendingKeys.count - 1] = nil
            }
        }

        while true {
            skipSpace()
            if result != nil {
                if pos < b.count { throw fail("unexpected extra JSON values") }
                return result!
            }
            guard pos < b.count else { throw fail("unfinished JSON term") }
            // After a value inside a container: a separator or the close.
            if let array = isArray.last {
                let c = b[pos]
                if array {
                    if c == UInt8(ascii: "]") {
                        pos += 1
                        isArray.removeLast()
                        let items = arrays.removeLast()
                        let deepest = arrayDepths.removeLast()
                        try finish(.array(items), depth: 1 + deepest)
                        continue
                    }
                    if !arrays[arrays.count - 1].isEmpty {
                        guard c == UInt8(ascii: ",") else { throw fail("expected ',' or ']'") }
                        pos += 1
                        skipSpace()
                    }
                } else if pendingKeys[pendingKeys.count - 1] == nil {
                    if c == UInt8(ascii: "}") {
                        pos += 1
                        isArray.removeLast()
                        pendingKeys.removeLast()
                        let object = objects.removeLast()
                        try finish(.object(object), depth: object.depth)
                        continue
                    }
                    if !objects[objects.count - 1].isEmpty {
                        guard c == UInt8(ascii: ",") else { throw fail("expected ',' or '}'") }
                        pos += 1
                        skipSpace()
                    }
                    guard pos < b.count, b[pos] == UInt8(ascii: "\"") else { throw fail("object keys must be strings") }
                    let name = try readString()
                    skipSpace()
                    guard pos < b.count, b[pos] == UInt8(ascii: ":") else { throw fail("expected ':' after an object key") }
                    pos += 1
                    pendingKeys[pendingKeys.count - 1] = name
                    skipSpace()
                }
            }
            guard pos < b.count else { throw fail("unfinished JSON term") }
            let c = b[pos]
            switch c {
            case UInt8(ascii: "["):
                pos += 1
                guard isArray.count < maxDepth else { throw fail("exceeds depth limit for parsing") }
                isArray.append(true)
                arrays.append([])
                arrayDepths.append(0)
            case UInt8(ascii: "{"):
                pos += 1
                guard isArray.count < maxDepth else { throw fail("exceeds depth limit for parsing") }
                isArray.append(false)
                objects.append(JQObject())
                pendingKeys.append(nil)
            case UInt8(ascii: "\""):
                try finish(.string(try readString()), depth: 0)
            case UInt8(ascii: "-"), 0x30...0x39:
                try finish(.number(try readNumber()), depth: 0)
            default:
                if literal("true") { try finish(.bool(true), depth: 0) }
                else if literal("false") { try finish(.bool(false), depth: 0) }
                else if literal("null") { try finish(.null, depth: 0) }
                else if literal("nan") || literal("NaN") { try finish(.number(.nan), depth: 0) }
                else if c == UInt8(ascii: "]") || c == UInt8(ascii: "}") { throw fail("unmatched '\(Character(Unicode.Scalar(c)))'") }
                else { throw fail("invalid literal") }
            }
        }
    }
}

/// Approximate compact-JSON size of a value, walked iteratively and stopped once past `budget`.
/// roadmap: S-5
enum JQSize {
    static func estimate(_ value: JQValue, budget: Int) -> Int {
        var total = 0
        var stack: [JQValue] = [value]
        while let v = stack.popLast() {
            switch v {
            case .null: total += 4
            case .bool: total += 5
            case .number: total += 8
            case .string(let s): total += s.utf8.count + 2
            case .array(let items):
                total += 2 + items.count
                stack.append(contentsOf: items)
            case .object(let object):
                total += 2 + object.count
                for key in object.storage.keys { total += key.utf8.count + 3 }
                stack.append(contentsOf: object.storage.values)
            }
            if total > budget { return total }
        }
        return total
    }
}
