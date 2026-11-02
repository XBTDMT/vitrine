import Foundation

/// CVSS base scores from vector strings, for advisories whose record carries no severity word (A-12, G-26).
/// CVSS v3.0 and v3.1 are computed with the specification's base equations and Roundup. CVSS v4.0 is not scored:
/// its base score comes from the specification's macro-vector lookup table, which Vitrine does not carry, so a
/// v4-only record keeps `.unknown` rather than an approximation that could overstate or understate it.
/// roadmap: S-22
enum CVSSScore {
    /// The base score of a `CVSS:3.0/…` or `CVSS:3.1/…` vector; nil for other versions or a malformed vector.
    static func v3BaseScore(_ vector: String) -> Double? {
        guard vector.utf8.count <= 256 else { return nil }
        let parts = vector.split(separator: "/")
        guard let head = parts.first, head == "CVSS:3.1" || head == "CVSS:3.0" else { return nil }
        var m: [Substring: Substring] = [:]
        for p in parts.dropFirst() {
            let kv = p.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            m[kv[0]] = kv[1]
        }
        guard let scope = m["S"], scope == "U" || scope == "C" else { return nil }
        let changed = scope == "C"
        let av: Double, ac: Double, pr: Double, ui: Double
        switch m["AV"] { case "N": av = 0.85; case "A": av = 0.62; case "L": av = 0.55; case "P": av = 0.2; default: return nil }
        switch m["AC"] { case "L": ac = 0.77; case "H": ac = 0.44; default: return nil }
        switch m["PR"] {
        case "N": pr = 0.85
        case "L": pr = changed ? 0.68 : 0.62
        case "H": pr = changed ? 0.5 : 0.27
        default: return nil
        }
        switch m["UI"] { case "N": ui = 0.85; case "R": ui = 0.62; default: return nil }
        func cia(_ key: Substring) -> Double? {
            switch m[key] { case "H": return 0.56; case "L": return 0.22; case "N": return 0; default: return nil }
        }
        guard let c = cia("C"), let i = cia("I"), let a = cia("A") else { return nil }
        let iss = 1 - (1 - c) * (1 - i) * (1 - a)
        let impact = changed ? 7.52 * (iss - 0.029) - 3.25 * pow(iss - 0.02, 15) : 6.42 * iss
        guard impact > 0 else { return 0 }
        let exploitability = 8.22 * av * ac * pr * ui
        return roundUp(min(changed ? 1.08 * (impact + exploitability) : impact + exploitability, 10))
    }

    /// CVSS v3.1's Roundup: the smallest number with one decimal place that is at least the input, computed on
    /// integers so floating-point noise never rounds a whole tenth up.
    static func roundUp(_ x: Double) -> Double {
        let scaled = Int((x * 100_000).rounded())
        if scaled % 10_000 == 0 { return Double(scaled) / 100_000 }
        return (Double(scaled / 10_000) + 1) / 10
    }

    /// The qualitative rating of a score: 0.1–3.9 low, 4.0–6.9 moderate (CVSS "medium"), 7.0–8.9 high,
    /// 9.0–10 critical; 0 (CVSS "none") is reported as low, the mildest rating the card has.
    static func severity(_ score: Double) -> Advisory.Severity {
        switch score {
        case 9.0...: return .critical
        case 7.0..<9.0: return .high
        case 4.0..<7.0: return .moderate
        default: return .low
        }
    }
}
