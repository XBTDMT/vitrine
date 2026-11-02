// VitrineDetect — confusable fold (DETECTORS.md §3.6). INVARIANT: one scalar in, one scalar out, so UTF-16
// offsets in the folded line equal offsets in the OCR line. Every mapping below is BMP → BMP (1 UTF-16 unit each).
// Ligatures ﬁ ﬂ are deliberately NOT in the table: they would be 1 → 2.

/// Normalises an OCR line before matching. Applied to lines, never to patterns (patterns are ASCII).
public enum ConfusableFold {
    /// Every row of §3.6, as `(from, to)` scalar pairs. Exposed so the tests can assert the invariant per entry.
    public static let table: [(from: Unicode.Scalar, to: Unicode.Scalar)] = {
        var rows: [(Unicode.Scalar, Unicode.Scalar)] = []
        func pairs(_ from: String, _ to: String) {
            let f = Array(from.unicodeScalars), t = Array(to.unicodeScalars)
            precondition(f.count == t.count, "fold table rows must pair 1:1")
            for (a, b) in zip(f, t) { rows.append((a, b)) }
        }
        // Cyrillic capitals А В Е К М Н О Р С Т Х У І Ј Ѕ
        pairs("АВЕКМНОРСТХУІЈЅ", "ABEKMHOPCTXYIJS")
        // Cyrillic lowercase а е о р с х у і ј ѕ
        pairs("аеорсхуіјѕ", "aeopcxyijs")
        // Greek capitals Α Β Ε Ζ Η Ι Κ Μ Ν Ο Ρ Τ Υ Χ
        pairs("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ", "ABEZHIKMNOPTYX")
        // Greek lowercase ο ν τ
        pairs("οντ", "ovt")
        // Ø ø → 0 0. Menlo and SF Mono draw zero slashed, and Vision reads it back as Ø or ø (measured 2026-10-27 in
        // the image fixtures: `1//0…` read `1//ø…`). 0 sits in every token class o does, and in hex and digit classes too.
        pairs("Øø", "00")
        // The whole Fullwidth ASCII block U+FF01…U+FF5E → U+0021…U+007E: letters, digits and every punctuation mark, each
        // the compatibility (NFKC) form of one ASCII character. Vision returns them on Latin text (measured 2026-10-27:
        // `(212) 555-0199` in Menlo 13 on a dark terminal read `（212）555-0199`). An explicit 1:1 table rather than NFKC
        // itself: NFKC also expands ligatures and other compatibility forms 1 → n, which would move every offset after
        // them, while this table keeps folded offsets equal to OCR offsets (the identity index map).
        for v in 0xFF01...0xFF5E { rows.append((Unicode.Scalar(UInt32(v))!, Unicode.Scalar(UInt32(v - 0xFF01 + 0x21))!)) }
        // Dashes ‐ ‑ ‒ – — −
        pairs("\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}", "------")
        // Quotes “ ” „ → " ; ‘ ’ ‚ → '
        pairs("\u{201C}\u{201D}\u{201E}", "\"\"\"")
        pairs("\u{2018}\u{2019}\u{201A}", "'''")
        // NBSP, narrow NBSP, ideographic space → space
        pairs("\u{00A0}\u{202F}\u{3000}", "   ")
        return rows
    }()

    private static let map: [UInt32: Unicode.Scalar] = {
        var m: [UInt32: Unicode.Scalar] = [:]
        for row in table { m[row.from.value] = row.to }
        return m
    }()

    /// Folds `s`. Guarantees `fold(s).unicodeScalars.count == s.unicodeScalars.count` and
    /// `fold(s).utf16.count == s.utf16.count` for every input (all table entries are BMP → BMP).
    public static func fold(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            out.append(map[scalar.value] ?? scalar)
        }
        return String(out)
    }
}
