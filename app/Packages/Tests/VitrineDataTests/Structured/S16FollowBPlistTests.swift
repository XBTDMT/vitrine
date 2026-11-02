import XCTest
@testable import VitrineData

/// S-16 follow-up B, the class of F39: a binary property list can point to one object from many places, and Core
/// Foundation hands that one shared object back for every reference, so walking or re-serializing it follows each
/// reference again. A few hundred bytes then stand for 14^12 values, and a 20 KB file for hundreds of megabytes of XML.
/// Every sample is invented and built here as bytes. roadmap: S-16
final class S16FollowBPlistTests: XCTestCase {
    // MARK: Crafted binary property lists

    /// `bplist00` from objects (object 0 is the top), one-byte object references and four-byte offsets.
    static func bplist(_ objects: [[UInt8]]) -> Data {
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for object in objects { offsets.append(out.count); out += object }
        let table = out.count
        for o in offsets { out += be(o, 4) }
        out += [0, 0, 0, 0, 0, 0, 4, 1] + be(objects.count, 8) + be(0, 8) + be(table, 8)
        return Data(out)
    }

    static func be(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// An array marker for `count` one-byte references (the count inline below 15, else a following integer).
    static func arrayHeader(_ count: Int) -> [UInt8] { count < 15 ? [0xA0 | UInt8(count)] : [0xAF, 0x12] + be(count, 4) }

    /// `levels` nested arrays, each holding `fanout` references to the next, the last pointing at one short string:
    /// fanout^levels values in 274 bytes for 12 levels of 14.
    static func laughs(levels: Int = 12, fanout: Int = 14) -> Data {
        var objects: [[UInt8]] = []
        for level in 0..<levels { objects.append(arrayHeader(fanout) + [UInt8](repeating: UInt8(level + 1), count: fanout)) }
        objects.append([0x51, 0x78])                    // "x"
        return bplist(objects)
    }

    /// `parents` references to one array of `references` references to one string of `length` characters: few values,
    /// and parents × references × length characters of XML from a file of about `references` bytes.
    static func sharedString(parents: Int = 11, references: Int = 20_000, length: Int = 1_000) -> Data {
        bplist([arrayHeader(parents) + [UInt8](repeating: 1, count: parents),
                arrayHeader(references) + [UInt8](repeating: 2, count: references),
                [0x5F, 0x12] + be(length, 4) + [UInt8](repeating: UInt8(ascii: "a"), count: length)])
    }

    static let tooLarge = "the property list is too large to show: its shared parts expand past what a preview can hold"

    func testTheCraftedFilesAreWhatTheySayTheyAre() throws {
        let tiny = Self.laughs()
        XCTAssertLessThan(tiny.count, 300, "under 300 bytes")
        let parsed = try XCTUnwrap(PropertyListSerialization.propertyList(from: tiny, format: nil) as? NSArray)
        XCTAssertEqual(parsed.count, 14)
        XCTAssertTrue(parsed[0] as AnyObject === parsed[1] as AnyObject, "Core Foundation shares the referenced object")
        XCTAssertLessThan(Self.sharedString().count, 22_000)
    }

    // MARK: Plist → XML text (StructuredFormatter)

    func testATinyExponentialPlistIsTooLargeToShowAsText() {
        let start = ContinuousClock.now
        let formatted = StructuredFormatter.propertyListXML(Self.laughs())
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertFalse(formatted.isComplete)
        XCTAssertEqual(formatted.text, "")
        XCTAssertEqual(formatted.stoppedAt?.reason, Self.tooLarge)
    }

    /// 20 KB that Core Foundation writes out as 220 MB of XML before the fix.
    func testASharedStringThatExpandsToHundredsOfMegabytesIsTooLargeToShowAsText() {
        let start = ContinuousClock.now
        let formatted = StructuredFormatter.propertyListXML(Self.sharedString())
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertFalse(formatted.isComplete)
        XCTAssertLessThan(formatted.text.utf8.count, 1_000_000)
        XCTAssertEqual(formatted.stoppedAt?.reason, Self.tooLarge)
    }

    func testOrdinaryBinaryPlistsStillBecomeXML() throws {
        // Shared values are normal (Core Foundation writes equal strings once); within the budget they are written out.
        let strings = Array(repeating: "the same string", count: 10_000)
        let binary = try PropertyListSerialization.data(fromPropertyList: ["list": strings, "n": 3], format: .binary, options: 0)
        let formatted = StructuredFormatter.propertyListXML(binary)
        XCTAssertTrue(formatted.isComplete, formatted.stoppedAt?.reason ?? "")
        XCTAssertEqual(formatted.text.components(separatedBy: "<string>the same string</string>").count - 1, 10_000)
        // One value per input byte is allowed past the floor: a large file that shares nothing is never refused.
        XCTAssertEqual(PlistExpansion.maxValues(inputBytes: 10), 500_000)
        XCTAssertEqual(PlistExpansion.maxValues(inputBytes: 3_000_000), 3_000_000)
    }

    // MARK: Plist → tree (PlistReader)

    func testATinyExponentialPlistIsTooLargeForTheTree() {
        let start = ContinuousClock.now
        let result = StructuredParser.parse(Self.laughs(), format: .propertyList)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(result.error?.reason, Self.tooLarge)
    }

    /// 7.5 million values from 100 bytes: the tree walk followed every one of them before the fix.
    func testAMillionfoldPlistIsTooLargeForTheTree() {
        let result = StructuredParser.parse(Self.laughs(levels: 6, fanout: 14), format: .propertyList)
        XCTAssertEqual(result.error?.reason, Self.tooLarge)
    }

    func testTheBudgetWalkStopsAtTheFirstBudgetPassed() {
        let parsed = (try? PropertyListSerialization.propertyList(from: Self.laughs(), format: nil)) ?? []
        let start = ContinuousClock.now
        XCTAssertFalse(PlistExpansion.fits(parsed, maxValues: 500_000))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        let shared = (try? PropertyListSerialization.propertyList(from: Self.sharedString(), format: nil)) ?? []
        XCTAssertTrue(PlistExpansion.fits(shared, maxValues: 500_000), "220,012 values are within the value budget")
        XCTAssertFalse(PlistExpansion.fits(shared, maxValues: 500_000, maxTextBytes: 64 << 20), "the text budget catches it")
    }
}
