import XCTest
@testable import VitrinePreviewKit

/// The hex inspector's pure parts (S-5, code design state 13, E-8): signatures, the byte decoder, the find query,
/// text runs and the Copy-as forms. Every byte here is invented by the test. roadmap: S-5
final class HexFormatTests: XCTestCase {
    func testSignaturesNameTheFormatAndTheirEvidence() {
        func id(_ bytes: [UInt8]) -> HexSignature? { HexSignature.identify(bytes) }
        XCTAssertEqual(id([0xCF, 0xFA, 0xED, 0xFE, 7, 0, 0, 1]), HexSignature(name: "Mach-O 64-bit", evidence: [0..<4]))
        XCTAssertEqual(id([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])?.name, "Mach-O universal")
        XCTAssertEqual(id([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 61])?.name, "Java class")
        XCTAssertEqual(id([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])?.name, "ELF 64-bit")
        XCTAssertEqual(id([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])?.evidence, [0..<8])
        XCTAssertEqual(id(Array("PK".utf8) + [3, 4, 20, 0])?.name, "ZIP archive")
        XCTAssertEqual(id(Array("%PDF-1.7\n".utf8))?.name, "PDF document")
        XCTAssertEqual(id(Array("SQLite format 3\0".utf8) + [16, 0])?.evidence, [0..<16])
        XCTAssertEqual(id([0x1F, 0x8B, 8, 0])?.name, "gzip compressed")
        // A PE file: MZ, the header's offset at 0x3C, and "PE\0\0" there; both pieces are evidence.
        var pe = [UInt8](repeating: 0, count: 0x90)
        pe[0] = 0x4D; pe[1] = 0x5A; pe[0x3C] = 0x80
        pe[0x80] = 0x50; pe[0x81] = 0x45
        XCTAssertEqual(id(pe), HexSignature(name: "PE executable (Windows)", evidence: [0..<2, 0x80..<0x84]))
        var tar = [UInt8](repeating: 0x20, count: 300)
        tar.replaceSubrange(257..<262, with: Array("ustar".utf8))
        XCTAssertEqual(id(tar)?.evidence, [257..<262])
        XCTAssertNil(id([0x13, 0x37, 0x42, 0x00, 0x99]))
        XCTAssertNil(id([]))
    }

    func testDecoderReadsTheDesignsFourBytes() throws {
        // 5B 82 D8 6A is 1,792,574,043 little-endian: a Unix time in October 2026.
        let bytes: [UInt8] = [0x5B, 0x82, 0xD8, 0x6A, 0xF8, 0x00, 0x03, 0x00]
        let rows = HexDecoder.rows(bytes: bytes, selectionLength: 4, endian: .little)
        func value(_ label: String) -> String? { rows.first { $0.label == label }?.value }
        XCTAssertEqual(value("Binary (first byte)"), "01011011")
        XCTAssertEqual(value("UInt8"), "91")
        XCTAssertEqual(value("Int16 LE"), (-32_165).formatted())
        XCTAssertEqual(value("UInt32 LE"), 1_792_574_043.formatted())
        XCTAssertEqual(value("Unix time (UInt32)"), "21 Oct 2026, 09:14:03 UTC")
        let best = rows.filter(\.highlighted).map(\.label)
        XCTAssertEqual(best, ["Unix time (UInt32)"], "four bytes that make a plausible date read as one")
        let big = HexDecoder.rows(bytes: bytes, selectionLength: 4, endian: .big)
        XCTAssertEqual(big.first { $0.label == "UInt32 BE" }?.value, 1_535_301_738.formatted())
        // Big-endian the same bytes are 26 Aug 2018, a plausible date too.
        XCTAssertEqual(big.filter(\.highlighted).map(\.label), ["Unix time (UInt32)"])
        XCTAssertEqual(HexDecoder.rows(bytes: [0xFF, 0xFF, 0xFF, 0xFF], selectionLength: 4, endian: .little).filter(\.highlighted).map(\.label),
                       ["UInt32 LE"], "a date in 2106 is not plausible, so the integer reads best")
    }

    func testDecoderFloatsDatesTextAndShortInput() {
        // 783,000,000 s after 2001 as a little-endian Float64: a Mac absolute time in 2025.
        let mac = withUnsafeBytes(of: Double(783_000_000).bitPattern.littleEndian, Array.init)
        let rows = HexDecoder.rows(bytes: mac, selectionLength: 8, endian: .little)
        func value(_ label: String) -> String? { rows.first { $0.label == label }?.value }
        XCTAssertEqual(value("Float64 LE"), Double(783_000_000).formatted(.number.precision(.significantDigits(1...7))))
        XCTAssertEqual(HexDecoder.float(1.309e26), 1.309e26.formatted(.number.notation(.scientific).precision(.significantDigits(1...4))))
        XCTAssertTrue(value("Mac absolute time (Float64)")?.contains("2025") == true, value("Mac absolute time (Float64)") ?? "")
        XCTAssertEqual(rows.filter(\.highlighted).map(\.label), ["Mac absolute time (Float64)"])

        let one = HexDecoder.rows(bytes: [0xFF], selectionLength: 1, endian: .little)
        XCTAssertEqual(one.first { $0.label == "Int8" }?.value, "-1")
        XCTAssertEqual(one.first { $0.label == "UInt32 LE" }?.value, "needs 4 bytes")

        XCTAssertEqual(HexDecoder.fourCC(Array("ftyp".utf8)), "'ftyp'")
        XCTAssertEqual(HexDecoder.fourCC([0, 1, 2, 3]), "not printable")
        XCTAssertEqual(HexDecoder.utf8(Array("héllo".utf8) + [0xFF], limit: 32), "\"héllo\"…")
        XCTAssertEqual(HexDecoder.utf8([0xFF, 0xFE], limit: 32), "not valid text")
        XCTAssertEqual(HexDecoder.utf16([0x48, 0, 0x69, 0], limit: 32, endian: .little), "\"Hi\"")
        XCTAssertEqual(HexDecoder.utf16([0, 0x48, 0, 0x69], limit: 32, endian: .big), "\"Hi\"")
    }

    func testQueriesAreBytesTextOrAJump() {
        XCTAssertEqual(HexQuery("DE AD BE EF"), .bytes([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(HexQuery("0xCAFE"), .bytes([0xCA, 0xFE]))
        XCTAssertEqual(HexQuery("cafe"), .text(Array("cafe".utf8), caseInsensitive: true), "a lone word stays text")
        XCTAssertEqual(HexQuery("12 34"), .bytes([0x12, 0x34]))
        XCTAssertEqual(HexQuery("n_0091"), .text(Array("n_0091".utf8), caseInsensitive: true))
        XCTAssertEqual(HexQuery("1234"), .text(Array("1234".utf8), caseInsensitive: false))
        XCTAssertEqual(HexQuery(":4096"), .offset(4096))
        XCTAssertEqual(HexQuery(":0x1F00"), .offset(0x1F00))
        XCTAssertEqual(HexQuery(": 1F00h"), .offset(0x1F00))
        XCTAssertEqual(HexQuery(":nowhere"), .invalidOffset)
    }

    func testRunsFormsAndCopyFormats() {
        let bytes = Array("ab\0cdef\0ghijkl".utf8) + [0x01]
        XCTAssertEqual(HexFormat.runs(in: bytes, base: 0x100).map(\.text), ["cdef", "ghijkl"])
        XCTAssertEqual(HexFormat.runs(in: bytes, base: 0x100).first?.offset, 0x103)
        XCTAssertEqual(HexFormat.inRun(Array("xx\0abcd\0".utf8)), [false, false, false, true, true, true, true, false])

        let dead: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        XCTAssertEqual(HexFormat.hex(dead), "DE AD BE EF")
        XCTAssertEqual(HexFormat.cArray(dead), "const unsigned char bytes[4] = {\n    0xDE, 0xAD, 0xBE, 0xEF\n};")
        XCTAssertEqual(HexFormat.base64(dead), "3q2+7w==")
        XCTAssertEqual(HexFormat.rawText(Array("hi\0there".utf8)), "hithere")
        XCTAssertEqual(HexFormat.dump(Array("ACMEPKG1".utf8) + [1, 0, 0, 0, 0x5B, 0x82, 0xD8, 0x6A]),
                       "00000000  41 43 4D 45 50 4B 47 31  01 00 00 00 5B 82 D8 6A  |ACMEPKG1....[..j|")
        XCTAssertEqual(HexFormat.offset(0xC), "0x0C")
        XCTAssertEqual(HexFormat.selection(0xC...0xF), "Offset 0x0C–0x0F · 4 bytes selected")
        XCTAssertEqual(HexFormat.selection(0x10...0x10), "Offset 0x10 · 1 byte selected")
        XCTAssertEqual(HexFormat.digits(forSize: 0x1_0000_0001), 9, "a file over 4 GB needs a ninth digit")
        XCTAssertEqual(HexFormat.entropy([UInt8](repeating: 7, count: 1024)), 0)
        XCTAssertEqual(HexFormat.entropy((0..<1024).map { UInt8($0 & 0xFF) }) ?? 0, 8, accuracy: 0.0001)
    }
}

/// The streaming search (S-5): matches across chunk edges, either case, the match cap and stopping. roadmap: S-5
final class HexSearchTests: XCTestCase {
    func testFindsAcrossChunkEdgesOnceEach() {
        // Chunks of 8 bytes; "DE AD BE" straddles the first edge.
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes.replaceSubrange(6..<9, with: [0xDE, 0xAD, 0xBE])
        bytes.replaceSubrange(30..<33, with: [0xDE, 0xAD, 0xBE])
        let source = HexByteSource(data: Data(bytes))
        let outcome = HexSearcher.search([0xDE, 0xAD, 0xBE], caseInsensitive: false, in: source, chunkSize: 8)
        XCTAssertEqual(outcome.matches, [6, 30])
        XCTAssertTrue(outcome.complete)
        XCTAssertEqual(outcome.searched, 40)
    }

    func testTextIgnoresCaseAndOverlapsCount() {
        let source = HexByteSource(data: Data("Weekly PLAN, weekly plan\0aaaa".utf8))
        XCTAssertEqual(HexSearcher.search(Array("plan".utf8), caseInsensitive: true, in: source, chunkSize: 5).matches, [7, 20])
        XCTAssertEqual(HexSearcher.search(Array("aa".utf8), caseInsensitive: false, in: source).matches, [25, 26, 27])
    }

    func testCapAndStop() {
        let source = HexByteSource(data: Data(repeating: 0xAB, count: 1000))
        let capped = HexSearcher.search([0xAB], caseInsensitive: false, in: source, chunkSize: 100, matchLimit: 50)
        XCTAssertEqual(capped.matches.count, 50)
        XCTAssertTrue(capped.capped)
        var calls = 0
        let stopped = HexSearcher.search([0xCD], caseInsensitive: false, in: source, chunkSize: 100) { _ in calls += 1; return calls < 3 }
        XCTAssertTrue(stopped.cancelled)
        XCTAssertEqual(stopped.searched, 300, "stopped after the third chunk")
    }
}
