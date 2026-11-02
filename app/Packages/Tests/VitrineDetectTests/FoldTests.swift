import Foundation
import Testing
@testable import VitrineDetect

@Suite("Confusable fold (DETECTORS.md §3.6)")
struct FoldTests {
    @Test func everyTableEntryIsOneBMPScalarToOneBMPScalar() {
        #expect(!ConfusableFold.table.isEmpty)
        for row in ConfusableFold.table {
            #expect(row.from.value <= 0xFFFF && row.to.value <= 0xFFFF, "\(row.from) → \(row.to) must stay in the BMP")
            #expect(String(row.from).utf16.count == 1 && String(row.to).utf16.count == 1)
            #expect(row.to.isASCII, "every target is ASCII")
        }
    }

    @Test("§3.6 rows", arguments: [
        ("АВЕКМНОРСТХУІЈЅ", "ABEKMHOPCTXYIJS"), ("аеорсхуіјѕ", "aeopcxyijs"),
        ("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ", "ABEZHIKMNOPTYX"), ("οντ", "ovt"), ("Øø", "00"),
        ("ＡＺａｚ０９＠＿－．／：", "AZaz09@_-./:"),
        ("！＂＃＄％＆＇（）＊＋，；＜＝＞？［＼］＾｀｛｜｝～", "!\"#$%&'()*+,;<=>?[\\]^`{|}~"),   // the rest of U+FF01…U+FF5E
        ("（212）555-0199", "(212)555-0199"),            // Vision on `(212) 555-0199`, Menlo 13, dark (2026-10-27)
        ("\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}", "------"),
        ("\u{201C}\u{201D}\u{201E}\u{2018}\u{2019}\u{201A}", "\"\"\"'''"),
        ("a\u{00A0}b\u{202F}c\u{3000}d", "a b c d"),
        ("ﬁﬂ", "ﬁﬂ"),                     // ligatures NOT folded (1 → 2 would break the invariant)
        ("sk-ant-api０３", "sk-ant-api03"),
        ("plain ASCII stays", "plain ASCII stays"),
    ])
    func rows(input: String, expected: String) {
        #expect(ConfusableFold.fold(input) == expected)
    }

    @Test func propertyLengthInvariantOverRandomUnicode() {
        var rng = SystemRandomNumberGenerator()
        let pools: [ClosedRange<UInt32>] = [0x20...0x7E, 0x400...0x45F, 0x391...0x3C9, 0xFF01...0xFF5E, 0x2010...0x2027, 0xA0...0xFF, 0x1F300...0x1F5FF, 0x4E00...0x4FFF]
        for _ in 0..<2000 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0...40, using: &rng) {
                let pool = pools.randomElement(using: &rng)!
                if let s = Unicode.Scalar(UInt32.random(in: pool, using: &rng)) { scalars.append(s) }
            }
            let s = String(scalars)
            let f = ConfusableFold.fold(s)
            #expect(f.utf16.count == s.utf16.count)
            #expect(f.unicodeScalars.count == s.unicodeScalars.count)
            #expect(ConfusableFold.fold(f) == f, "idempotent")
        }
    }
}
