import Foundation

/// One RFC 5545 / RFC 6350 content line: `group.NAME;PARAM=a,b;PARAM2="c":value`.
struct EverydayContentLine: Equatable {
    var group: String?
    /// Uppercased.
    var name: String
    /// Parameter names uppercased; values unquoted, in order. vCard 2.1's bare parameters (`TEL;WORK;VOICE:`) are
    /// stored under `TYPE`.
    var parameters: [(name: String, values: [String])]
    /// The raw value: not unescaped and not decoded.
    var value: String

    static func == (a: EverydayContentLine, b: EverydayContentLine) -> Bool {
        a.group == b.group && a.name == b.name && a.value == b.value
            && a.parameters.map(\.name) == b.parameters.map(\.name) && a.parameters.map(\.values) == b.parameters.map(\.values)
    }

    func parameter(_ name: String) -> String? {
        parameters.first { $0.name == name }?.values.first
    }

    func parameterValues(_ name: String) -> [String] {
        parameters.filter { $0.name == name }.flatMap(\.values)
    }

    /// TYPE values lowercased, without duplicates, `pref` included when PREF= is set.
    var types: [String] {
        var out: [String] = []
        for value in parameterValues("TYPE") {
            for part in value.split(separator: ",") {
                let lower = part.trimmingCharacters(in: .whitespaces).lowercased()
                if !lower.isEmpty, !out.contains(lower) { out.append(lower) }
            }
        }
        if parameter("PREF") != nil, !out.contains("pref") { out.append("pref") }
        return out
    }

    /// The value with RFC 5545/6350 escapes undone (`\n`, `\,`, `\;`, `\\`).
    var text: String { Self.unescape(value) }

    /// The value split on unescaped `sep`, each part unescaped.
    func components(_ sep: Character = ";") -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for c in value {
            if escaped { current.append("\\"); current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == sep { parts.append(Self.unescape(current)); current = ""; continue }
            current.append(c)
        }
        if escaped { current.append("\\") }
        parts.append(Self.unescape(current))
        return parts
    }

    static func unescape(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var out = ""
        var escaped = false
        for c in raw {
            if escaped {
                switch c {
                case "n", "N": out.append("\n")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}

/// Unfolds and splits iCalendar and vCard text into content lines.
enum EverydayContentLines {
    /// The most content lines read from one file.
    static let maxLines = 500_000

    /// Lines unfolded: a line starting with a space or tab continues the one before (the space is removed). vCard
    /// 2.1 quoted-printable values that end in `=` continue on the next line too.
    static func unfold(_ text: String) -> (lines: [String], truncated: Bool) {
        var result: [String] = []
        var truncated = false
        var qpContinues = false
        for line in EverydayText.lines(text) {
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
                continue
            }
            if qpContinues, !result.isEmpty {
                result[result.count - 1].removeLast()   // the soft-break "="
                result[result.count - 1] += line
                qpContinues = line.hasSuffix("=")
                continue
            }
            if line.isEmpty { continue }
            if result.count >= maxLines { truncated = true; break }
            result.append(String(line))
            qpContinues = line.hasSuffix("=") && line.uppercased().contains("QUOTED-PRINTABLE")
        }
        return (result, truncated)
    }

    static func parse(_ line: String) -> EverydayContentLine? {
        // The name and parameters end at the first ":" outside double quotes.
        var inQuotes = false
        var colon: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() } else if c == ":", !inQuotes { colon = i; break }
        }
        guard let colon else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        var pieces: [String] = []
        var current = ""
        inQuotes = false
        for c in head {
            if c == "\"" { inQuotes.toggle(); current.append(c); continue }
            if c == ";", !inQuotes { pieces.append(current); current = ""; continue }
            current.append(c)
        }
        pieces.append(current)
        var fullName = pieces.removeFirst().trimmingCharacters(in: .whitespaces)
        guard !fullName.isEmpty else { return nil }
        var group: String?
        if let dot = fullName.lastIndex(of: ".") {
            group = String(fullName[..<dot])
            fullName = String(fullName[fullName.index(after: dot)...])
        }
        var parameters: [(String, [String])] = []
        for piece in pieces where !piece.isEmpty {
            if let eq = piece.firstIndex(of: "=") {
                let name = piece[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
                let rawValues = String(piece[piece.index(after: eq)...])
                var values: [String] = []
                var buffer = ""
                inQuotes = false
                for c in rawValues {
                    if c == "\"" { inQuotes.toggle(); continue }
                    if c == ",", !inQuotes { values.append(buffer); buffer = ""; continue }
                    buffer.append(c)
                }
                values.append(buffer)
                parameters.append((name, values))
            } else {
                // vCard 2.1 bare parameter: a type or an encoding.
                let bare = piece.trimmingCharacters(in: .whitespaces)
                switch bare.uppercased() {
                case "QUOTED-PRINTABLE", "BASE64", "8BIT", "7BIT": parameters.append(("ENCODING", [bare]))
                default: parameters.append(("TYPE", [bare]))
                }
            }
        }
        return EverydayContentLine(group: group, name: fullName.uppercased(), parameters: parameters, value: value)
    }
}
