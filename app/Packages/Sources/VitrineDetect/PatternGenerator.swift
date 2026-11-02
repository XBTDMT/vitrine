// VitrineDetect — the five pattern generators of DETECTORS.md §3, including the "Looks like this" generaliser (§3.5).
import Foundation

/// Turns a `PatternSpec` into `(regex, description)`. Pure functions; every emitted regex is compile-tested.
enum PatternGenerator {
    struct Generated: Equatable {
        let regex: String
        let description: String
    }

    static func generate(_ spec: PatternSpec) throws -> Generated {
        let value = spec.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated: Generated
        switch spec.kind {
        case .exactText: generated = try exactText(value, caseSensitive: spec.caseSensitive)
        case .prefix: generated = try prefix(value, tokenLength: spec.tokenLength ?? PatternSpec.defaultTokenLength)
        case .label: generated = try label(value)
        case .example: generated = try example(value)
        case .regex:
            guard let source = spec.pattern, !source.isEmpty else { throw PatternError.missingRegex }
            // Security scan F23: a source too long, or with a repeat inside a repeat, is refused before it is compiled or
            // run, whoever wrote it (a built-in, the person, a rules file from someone else). `MatchBudget` bounds the rest.
            try RegexComplexity.check(source)
            generated = Generated(regex: source, description: "whatever your regular expression matches")
        }
        // Compile test with options [] (§1 principle 5). The generated kinds always compile; `.regex` may not.
        do {
            _ = try NSRegularExpression(pattern: generated.regex, options: [])
        } catch {
            throw PatternError.invalidRegex(generated.regex)
        }
        return generated
    }

    // MARK: §3.1 exactText

    static func exactText(_ value: String, caseSensitive: Bool) throws -> Generated {
        guard value.count >= 1 else { throw PatternError.valueTooShort(minimum: 1) }
        let regex = (caseSensitive ? "" : "(?i)") + escapedWithFlexibleWhitespace(value)
        let description = "“\(value)”, " + (caseSensitive ? "exact case" : "in any letter case")
        return Generated(regex: regex, description: description)
    }

    // MARK: §3.2 prefix

    static let prefixTokenClass = #"[A-Za-z0-9_\-]"#

    static func prefix(_ value: String, tokenLength: Int) throws -> Generated {
        guard value.count >= 2 else { throw PatternError.valueTooShort(minimum: 2) }
        let n = max(1, tokenLength)
        let regex = NSRegularExpression.escapedPattern(for: value) + prefixTokenClass + "{\(n),}"
        let description = "\(value) followed by at least \(n) letters, digits, _ or -"
        return Generated(regex: regex, description: description)
    }

    // MARK: §3.3 label

    static let labelSecretTail = #"\s*[:=#\-]?\s*["']?(?<secret>[^\s,;"']+)"#

    static func label(_ value: String) throws -> Generated {
        guard value.count >= 1 else { throw PatternError.valueTooShort(minimum: 1) }
        let regex = "(?i)" + escapedWithFlexibleWhitespace(value) + labelSecretTail
        return Generated(regex: regex, description: "the value written after “\(value)”")
    }

    // MARK: §3.5 example — the generaliser

    static func example(_ value: String) throws -> Generated {
        guard value.count >= 3 else { throw PatternError.valueTooShort(minimum: 3) }
        var fragments: [String] = []
        var descriptions: [String] = []
        for run in segment(value) {
            let (fragment, description) = emit(run)
            fragments.append(fragment)
            descriptions.append(description)
        }
        let scalars = Array(value.unicodeScalars)
        var regex = fragments.joined()
        if let first = scalars.first, isASCIIAlphanumeric(first) { regex = #"\b"# + regex }
        if let last = scalars.last, isASCIIAlphanumeric(last) { regex += #"\b"# }
        return Generated(regex: regex, description: descriptions.joined(separator: ", "))
    }

    enum RunClass: Equatable {
        case digits, upper, lower, mixed, whitespace, other
    }

    struct Run: Equatable {
        let runClass: RunClass
        let text: String
        var count: Int { text.unicodeScalars.count }
    }

    /// Segments the example into maximal runs. A maximal alphanumeric run containing both a letter and a
    /// digit is one `mixed` run; otherwise it is split into digit / uppercase / lowercase runs. Whitespace
    /// runs collapse to one `whitespace`; every other scalar is its own `other` run.
    static func segment(_ value: String) -> [Run] {
        var runs: [Run] = []
        var alnumBuffer: [Unicode.Scalar] = []
        var whitespaceBuffer: [Unicode.Scalar] = []

        func flushAlnum() {
            guard !alnumBuffer.isEmpty else { return }
            let hasLetter = alnumBuffer.contains { isASCIILetter($0) }
            let hasDigit = alnumBuffer.contains { isASCIIDigit($0) }
            if hasLetter && hasDigit {
                runs.append(Run(runClass: .mixed, text: string(alnumBuffer)))
            } else {
                var current: [Unicode.Scalar] = []
                var currentClass: RunClass?
                for s in alnumBuffer {
                    let cls: RunClass = isASCIIDigit(s) ? .digits : (isASCIIUpper(s) ? .upper : .lower)
                    if cls != currentClass, !current.isEmpty {
                        runs.append(Run(runClass: currentClass!, text: string(current)))
                        current = []
                    }
                    currentClass = cls
                    current.append(s)
                }
                if let cls = currentClass, !current.isEmpty { runs.append(Run(runClass: cls, text: string(current))) }
            }
            alnumBuffer = []
        }
        func flushWhitespace() {
            guard !whitespaceBuffer.isEmpty else { return }
            runs.append(Run(runClass: .whitespace, text: string(whitespaceBuffer)))
            whitespaceBuffer = []
        }

        for s in value.unicodeScalars {
            if isASCIIAlphanumeric(s) {
                flushWhitespace()
                alnumBuffer.append(s)
            } else if s.properties.isWhitespace {
                flushAlnum()
                whitespaceBuffer.append(s)
            } else {
                flushAlnum()
                flushWhitespace()
                runs.append(Run(runClass: .other, text: String(Character(s))))
            }
        }
        flushAlnum()
        flushWhitespace()
        return runs
    }

    static func emit(_ run: Run) -> (fragment: String, description: String) {
        let n = run.count
        switch run.runClass {
        case .digits:
            return (#"\d{\#(n)}"#, n == 1 ? "1 digit" : "\(n) digits")
        case .upper where n >= 4:
            return ("[A-Z]{\(n)}", "\(n) capital letters")
        case .lower where n >= 4:
            return ("[a-z]{\(n)}", "\(n) lowercase letters")
        case .upper, .lower:
            return (NSRegularExpression.escapedPattern(for: run.text), "“\(run.text)”")
        case .mixed:
            let slack = max(1, n / 10)
            return ("[A-Za-z0-9]{\(n - slack),\(n + slack)}", "about \(n) letters and digits")
        case .whitespace:
            return (#"\s+"#, "a space")
        case .other:
            return (NSRegularExpression.escapedPattern(for: run.text), "“\(run.text)”")
        }
    }

    // MARK: helpers

    /// Escapes the value for ICU and replaces every whitespace run with `\s+`.
    static func escapedWithFlexibleWhitespace(_ value: String) -> String {
        let pieces = value.split(whereSeparator: { $0.isWhitespace })
        return pieces.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return String(s)
    }

    static func isASCIIDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }
    static func isASCIIUpper(_ s: Unicode.Scalar) -> Bool { s.value >= 0x41 && s.value <= 0x5A }
    static func isASCIILower(_ s: Unicode.Scalar) -> Bool { s.value >= 0x61 && s.value <= 0x7A }
    static func isASCIILetter(_ s: Unicode.Scalar) -> Bool { isASCIIUpper(s) || isASCIILower(s) }
    static func isASCIIAlphanumeric(_ s: Unicode.Scalar) -> Bool { isASCIILetter(s) || isASCIIDigit(s) }
}
