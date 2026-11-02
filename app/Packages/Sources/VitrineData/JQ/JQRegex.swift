import Foundation

/// jq's regular-expression built-ins (`test`, `match`, `capture`, `scan`, `split/2`, `sub`, `gsub`) over
/// NSRegularExpression (ICU syntax, close to the Oniguruma Perl syntax jq uses). Offsets and lengths are in code
/// points, as jq reports them. Flags: g (all matches), i (ignore case), x (extended), n (skip empty matches),
/// s (single line: already ICU's default for ^ and $), p (s plus `.` matching newlines), l (accepted, no effect).
/// roadmap: S-5
enum JQRegex {
    struct Compiled {
        let regex: NSRegularExpression
        let global: Bool
        let skipEmpty: Bool
        /// Name of each capture group by number (index 0 unused), nil when unnamed.
        let groupNames: [String?]
    }

    static func compile(_ pattern: JQValue, _ flags: JQValue, _ interp: JQInterpreter, forceGlobal: Bool = false) throws -> Compiled {
        var re = pattern
        var flagValue = flags
        if case .array(let pair) = pattern {
            guard let first = pair.first else { throw JQThrown("\(JQOps.described(pattern)) cannot be matched, as it is not a string") }
            re = first
            if pair.count > 1 { flagValue = pair[1] }
        }
        guard case .string(let source) = re else {
            throw JQThrown("\(JQOps.described(re)) cannot be matched, as it is not a string")
        }
        var flagText = ""
        switch flagValue {
        case .null: break
        case .string(let s): flagText = s
        default: throw JQThrown("\(JQOps.described(flagValue)) is not a string")
        }
        var options: NSRegularExpression.Options = []
        var global = forceGlobal, skipEmpty = false
        for flag in flagText {
            switch flag {
            case "g": global = true
            case "i": options.insert(.caseInsensitive)
            case "x": options.insert(.allowCommentsAndWhitespace)
            case "n": skipEmpty = true
            case "p": options.insert(.dotMatchesLineSeparators)
            case "s", "l": break
            default: throw JQThrown("\(flagText) is not a valid modifier string")
            }
        }
        let key = "\(options.rawValue)/\(source)"
        let regex: NSRegularExpression
        if let cached = interp.regexCache[key] {
            regex = cached
        } else {
            do {
                regex = try NSRegularExpression(pattern: source, options: options)
            } catch {
                throw JQThrown("\(source) (at offset 0) is not a valid regex")
            }
            if interp.regexCache.count > 64 { interp.regexCache.removeAll() }
            interp.regexCache[key] = regex
        }
        return Compiled(regex: regex, global: global, skipEmpty: skipEmpty, groupNames: groupNames(source, count: regex.numberOfCaptureGroups))
    }

    /// Capture group names in order of their opening parenthesis: `(?<name>…)`, `(?P<name>…)`, `(?'name'…)`.
    static func groupNames(_ pattern: String, count: Int) -> [String?] {
        var names: [String?] = [nil]
        let chars = Array(pattern.unicodeScalars)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            if c == "[" { inClass = true; i += 1; continue }
            if c == "(" {
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    var j = i + 2
                    if j < chars.count, chars[j] == "P" { j += 1 }
                    if j < chars.count, chars[j] == "<" || chars[j] == "'",
                       j + 1 < chars.count, chars[j + 1] != "=", chars[j + 1] != "!" {
                        let close: Unicode.Scalar = chars[j] == "<" ? ">" : "'"
                        var k = j + 1
                        var name = ""
                        while k < chars.count, chars[k] != close { name.unicodeScalars.append(chars[k]); k += 1 }
                        names.append(name)
                    }
                } else {
                    names.append(nil)
                }
            }
            i += 1
        }
        while names.count < count + 1 { names.append(nil) }
        return Array(names.prefix(count + 1))
    }

    /// A string with a UTF-16 → code point offset table, for NSRegularExpression ranges.
    struct Subject {
        let text: String
        let ns: NSString
        /// codePoint[u] = code points before UTF-16 offset u.
        let codePoint: [Int]

        init(_ text: String) {
            self.text = text
            ns = text as NSString
            var table: [Int] = []
            table.reserveCapacity(text.utf16.count + 1)
            var count = 0
            for scalar in text.unicodeScalars {
                table.append(count)
                if scalar.value > 0xFFFF { table.append(count) }
                count += 1
            }
            table.append(count)
            codePoint = table
        }

        func substring(_ range: NSRange) -> String { ns.substring(with: range) }
    }

    static func matches(_ compiled: Compiled, _ subject: Subject, _ interp: JQInterpreter) throws -> [NSTextCheckingResult] {
        let whole = NSRange(location: 0, length: subject.ns.length)
        var results: [NSTextCheckingResult] = []
        if compiled.global {
            for m in compiled.regex.matches(in: subject.text, options: [], range: whole) {
                try interp.tick()
                if compiled.skipEmpty, m.range.length == 0 { continue }
                results.append(m)
            }
        } else {
            for m in compiled.regex.matches(in: subject.text, options: [], range: whole) {
                if compiled.skipEmpty, m.range.length == 0 { continue }
                results.append(m)
                break
            }
        }
        return results
    }

    /// jq's match object: {offset, length, string, captures: [{offset, length, string, name}]}.
    static func matchObject(_ m: NSTextCheckingResult, _ compiled: Compiled, _ subject: Subject) -> JQValue {
        func offset(_ u: Int) -> Int { subject.codePoint[min(u, subject.codePoint.count - 1)] }
        let start = offset(m.range.location), end = offset(m.range.location + m.range.length)
        var captures: [JQValue] = []
        for group in 1..<max(1, m.numberOfRanges) {
            let r = m.range(at: group)
            let name: JQValue = compiled.groupNames[group].map(JQValue.string) ?? .null
            if r.location == NSNotFound {
                captures.append(.object(JQObject([("offset", .number(-1)), ("length", .number(0)), ("string", .null), ("name", name)])))
            } else {
                let cs = offset(r.location), ce = offset(r.location + r.length)
                captures.append(.object(JQObject([("offset", .number(Double(cs))), ("length", .number(Double(ce - cs))),
                                                   ("string", .string(subject.substring(r))), ("name", name)])))
            }
        }
        return .object(JQObject([("offset", .number(Double(start))), ("length", .number(Double(end - start))),
                                 ("string", .string(subject.substring(m.range))), ("captures", .array(captures))]))
    }

    static func subject(_ value: JQValue) throws -> Subject {
        guard case .string(let text) = value else {
            throw JQThrown("\(JQOps.described(value)) cannot be matched, as it is not a string")
        }
        return Subject(text)
    }

    static func test(_ input: JQValue, _ re: JQValue, _ flags: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        let s = try subject(input)
        let compiled = try compile(re, flags, interp)
        return .bool(!(try matches(Compiled(regex: compiled.regex, global: false, skipEmpty: compiled.skipEmpty,
                                             groupNames: compiled.groupNames), s, interp)).isEmpty)
    }

    static func match(_ input: JQValue, _ re: JQValue, _ flags: JQValue, _ interp: JQInterpreter,
                      forceGlobal: Bool = false, _ emit: (JQValue) throws -> Void) throws {
        let s = try subject(input)
        let compiled = try compile(re, flags, interp, forceGlobal: forceGlobal)
        for m in try matches(compiled, s, interp) { try emit(matchObject(m, compiled, s)) }
    }

    /// The named captures of a match as an object (unmatched groups are null).
    static func captureObject(_ m: NSTextCheckingResult, _ compiled: Compiled, _ subject: Subject) -> JQObject {
        var object = JQObject()
        for group in 1..<max(1, m.numberOfRanges) {
            guard let name = compiled.groupNames[group] else { continue }
            let r = m.range(at: group)
            object.set(name, r.location == NSNotFound ? .null : .string(subject.substring(r)))
        }
        return object
    }

    static func capture(_ input: JQValue, _ re: JQValue, _ flags: JQValue, _ interp: JQInterpreter, _ emit: (JQValue) throws -> Void) throws {
        let s = try subject(input)
        let compiled = try compile(re, flags, interp)
        for m in try matches(compiled, s, interp) { try emit(.object(captureObject(m, compiled, s))) }
    }

    static func scan(_ input: JQValue, _ re: JQValue, _ flags: JQValue, _ interp: JQInterpreter, _ emit: (JQValue) throws -> Void) throws {
        let s = try subject(input)
        let compiled = try compile(re, flags, interp, forceGlobal: true)
        for m in try matches(compiled, s, interp) {
            if m.numberOfRanges > 1 {
                var groups: [JQValue] = []
                for group in 1..<m.numberOfRanges {
                    let r = m.range(at: group)
                    groups.append(r.location == NSNotFound ? .null : .string(s.substring(r)))
                }
                try emit(.array(groups))
            } else {
                try emit(.string(s.substring(m.range)))
            }
        }
    }

    /// `split(re; flags)`: the pieces between matches.
    static func split(_ input: JQValue, _ re: JQValue, _ flags: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        let s = try subject(input)
        let compiled = try compile(re, flags, interp, forceGlobal: true)
        var pieces: [JQValue] = []
        var previous = 0
        for m in try matches(compiled, s, interp) {
            pieces.append(.string(s.substring(NSRange(location: previous, length: m.range.location - previous))))
            previous = m.range.location + m.range.length
        }
        pieces.append(.string(s.substring(NSRange(location: previous, length: s.ns.length - previous))))
        return .array(pieces)
    }

    /// `sub(re; replacement; flags)`: `replacement` runs with the named captures as its input; when it has several
    /// outputs, each combination gives one result (earlier matches varying slowest).
    static func substitute(_ input: JQValue, _ re: JQValue, _ flags: JQValue, global: Bool, _ interp: JQInterpreter,
                           _ replacement: (JQValue, (JQValue) throws -> Void) throws -> Void,
                           _ emit: (JQValue) throws -> Void) throws {
        let s = try subject(input)
        let compiled = try compile(re, flags, interp, forceGlobal: global)
        var results = [""]
        var previous = 0
        for m in try matches(compiled, s, interp) {
            let gap = s.substring(NSRange(location: previous, length: m.range.location - previous))
            var replacements: [String] = []
            try replacement(.object(captureObject(m, compiled, s))) { v in
                guard case .string(let text) = v else {
                    throw JQThrown("\(JQOps.described(.string(gap))) and \(JQOps.described(v)) cannot be added")
                }
                replacements.append(text)
            }
            var next: [String] = []
            for r in results {
                for text in replacements {
                    let combined = r + gap + text
                    try interp.checkStringSize(combined.utf8.count)
                    next.append(combined)
                }
            }
            results = next
            previous = m.range.location + m.range.length
        }
        let tail = s.substring(NSRange(location: previous, length: s.ns.length - previous))
        for r in results { try emit(.string(r + tail)) }
    }
}
