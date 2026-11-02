import Foundation
import XCTest
@testable import VitrineBinary

/// S-16 hardening: hostile torrents, Android string pools and binary property lists, built byte by byte with
/// invented content. Each used to trap the process (F21), or expand a few bytes into gigabytes of work (F20, F39).
/// roadmap: S-16
final class S16ParsersBinaryTests: XCTestCase {
    private func elapsed(_ body: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try body()
        return clock.now - start
    }

    // MARK: F21 — bencode byte-string lengths

    func testByteStringLengthNearIntMaxThrowsInsteadOfTrapping() {
        for bad in ["9223372036854775807:", "d4:info9223372036854775800:", "d8:announce9223372036854775807:x",
                    "l9223372036854775807:e", "d4:infod4:name18446744073709551615:ee"] {
            XCTAssertThrowsError(try TorrentReader.read(bytes: Array(bad.utf8)), bad) { error in
                guard case BinaryError.truncated = error else { return XCTFail("\(bad): \(error)") }
            }
        }
    }

    func testTotalSizeSaturatesInsteadOfWrapping() throws {
        let file = "d6:lengthi9223372036854775807e4:pathl1:aee"
        let torrent = "d4:infod5:filesl\(file)\(file.replacingOccurrences(of: "1:a", with: "1:b"))e4:name1:te6:pieces0:ee"
        let parsed = try TorrentReader.read(bytes: Array(torrent.utf8))
        XCTAssertEqual(parsed.files.count, 2)
        XCTAssertEqual(parsed.totalSize, Int64.max, "two maximal lengths stop at Int64.max, never wrap negative")
    }

    // MARK: F20 — Android binary-XML string pool

    /// A string-pool chunk: `offsets` into a UTF-16 data area.
    private func pool(offsets: [UInt32], data: [UInt8]) -> [UInt8] {
        let headerSize = 28
        let stringsStart = headerSize + offsets.count * 4
        var out: [UInt8] = []
        func le16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) { for i in 0..<4 { out.append(UInt8(v >> (8 * i) & 0xFF)) } }
        le16(0x0001); le16(headerSize); le32(stringsStart + data.count)
        le32(offsets.count); le32(0); le32(0); le32(stringsStart); le32(0)
        for o in offsets { le32(Int(o)) }
        return out + data
    }

    private func utf16String(_ units: Int, unit: UInt16 = 0x0041) -> [UInt8] {
        var out: [UInt8] = []
        if units < 0x8000 {
            out += [UInt8(units & 0xFF), UInt8(units >> 8)]
        } else {
            let high = 0x8000 | (units >> 16), low = units & 0xFFFF
            out += [UInt8(high & 0xFF), UInt8(high >> 8), UInt8(low & 0xFF), UInt8(low >> 8)]
        }
        for _ in 0..<units { out += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        return out + [0, 0]
    }

    func testAliasedOffsetsDecodeOneStringOnce() throws {
        // 200,000 offsets all naming one 100,000-unit string: 2 × 10^10 units decoded before, one string now.
        let chunk = pool(offsets: [UInt32](repeating: 0, count: 200_000), data: utf16String(100_000))
        var strings: [String] = []
        let took = try elapsed { strings = try AndroidBinaryXML.stringPool(chunk) }
        XCTAssertLessThan(took, .seconds(2))
        XCTAssertEqual(strings.count, 200_000)
        XCTAssertEqual(strings.first?.utf16.count, 100_000)
        XCTAssertEqual(strings.last, strings.first)
    }

    func testOverlappingOffsetsThatSayMoreThanThePoolHoldsAreRefused() throws {
        // Every even offset inside a run of 0x4000 units reads as its own 16,384-unit string: 50,000 of them would
        // decode 1.6 GB from a 300 KB chunk.
        let data = [UInt8]((0..<100_000).flatMap { _ in [UInt8(0x00), UInt8(0x40)] })
        let chunk = pool(offsets: (0..<50_000).map { UInt32($0 * 2) }, data: data)
        let took = try elapsed {
            XCTAssertThrowsError(try AndroidBinaryXML.stringPool(chunk)) { error in
                guard case BinaryError.unsupported = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertLessThan(took, .seconds(2))
    }

    func testDistinctStringsStillDecode() throws {
        let a = utf16String(3, unit: 0x0062), b = utf16String(2, unit: 0x0063)
        let chunk = pool(offsets: [0, UInt32(a.count), 0], data: a + b)
        XCTAssertEqual(try AndroidBinaryXML.stringPool(chunk), ["bbb", "cc", "bbb"])
    }

    // MARK: F39 — binary property list "billion laughs"

    /// `bplist00` whose root dictionary's `PayloadContent` is level 1 of `levels` arrays, each holding `fanout`
    /// references to the next level: a few hundred bytes describing fanout^levels leaves.
    static func sharedReferencePlist(levels: Int, fanout: Int = 16) -> [UInt8] {
        var objects: [[UInt8]] = []
        objects.append([0xD1, 1, 2])                                         // {obj1: obj2}
        objects.append([0x5E] + Array("PayloadContent".utf8))                // 14-character ASCII string
        for level in 0..<levels {
            let next = UInt8(3 + level)
            objects.append([0xAF, 0x10, UInt8(fanout)] + [UInt8](repeating: next, count: fanout))
        }
        objects.append([0x51, 0x78])                                         // "x"
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for o in objects { offsets.append(out.count); out += o }
        let tableOffset = out.count
        for o in offsets { out += [UInt8(o >> 8), UInt8(o & 0xFF)] }
        func be64(_ v: Int) -> [UInt8] { (0..<8).reversed().map { UInt8(v >> (8 * $0) & 0xFF) } }
        out += [0, 0, 0, 0, 0, 0, 2, 1] + be64(objects.count) + be64(0) + be64(tableOffset)
        return out
    }

    func testSharedReferencePlistIsTooLargeToShowNotAHang() throws {
        let bytes = Self.sharedReferencePlist(levels: 12)                 // 16^12 leaves from ~250 bytes
        XCTAssertLessThan(bytes.count, 400)
        let took = try elapsed {
            XCTAssertThrowsError(try PropertyListDecoder.dictionary(bytes, limit: 1 << 20, what: "the profile")) { error in
                guard case BinaryError.unsupported(let why) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(why.contains("too large to show"), why)
            }
        }
        XCTAssertLessThan(took, .seconds(5), "500,000 values at most, never 16^12")
        let object = try PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        XCTAssertNil(PlistValue(propertyList: object), "the non-throwing converter refuses it too")
    }

    func testSharedReferencesWithinTheBudgetStillConvert() throws {
        let bytes = Self.sharedReferencePlist(levels: 3)                  // 4,096 leaves: an ordinary size
        let dict = try PropertyListDecoder.dictionary(bytes, limit: 1 << 20, what: "the profile")
        let level1 = try XCTUnwrap(dict["PayloadContent"]?.arrayValue)
        XCTAssertEqual(level1.count, 16)
        XCTAssertEqual(level1.first?.arrayValue?.first?.arrayValue?.first?.stringValue, "x")
    }
}
