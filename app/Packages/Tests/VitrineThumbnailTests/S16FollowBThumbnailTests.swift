import Foundation
import Testing
import VitrineSupport
@testable import VitrineThumbnail

/// S-16 follow-up B, the class of F39: a binary property list's thumbnail is drawn from its XML form, and Core
/// Foundation writes a shared object out once per reference, so a 20 KB file could become hundreds of megabytes of
/// XML in the thumbnail process, which Finder runs without being asked. Every sample is invented bytes. roadmap: S-16
@Suite("S-16 follow-up B: binary plist thumbnails are budgeted")
struct S16FollowBThumbnailTests {
    static func be(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    static func bplist(_ objects: [[UInt8]]) -> Data {
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for object in objects { offsets.append(out.count); out += object }
        let table = out.count
        for o in offsets { out += be(o, 4) }
        out += [0, 0, 0, 0, 0, 0, 4, 1] + be(objects.count, 8) + be(0, 8) + be(table, 8)
        return Data(out)
    }

    static func arrayHeader(_ count: Int) -> [UInt8] { count < 15 ? [0xA0 | UInt8(count)] : [0xAF, 0x12] + be(count, 4) }

    /// 11 references to one array of 20,000 references to one 1,000-character string: 220 MB of XML from 21 KB.
    static var sharedString: Data {
        bplist([arrayHeader(11) + [UInt8](repeating: 1, count: 11),
                arrayHeader(20_000) + [UInt8](repeating: 2, count: 20_000),
                [0x5F, 0x12] + be(1_000, 4) + [UInt8](repeating: UInt8(ascii: "a"), count: 1_000)])
    }

    /// 12 nested arrays of 14 references each: 14^12 values in 274 bytes.
    static var laughs: Data {
        var objects: [[UInt8]] = []
        for level in 0..<12 { objects.append(arrayHeader(14) + [UInt8](repeating: UInt8(level + 1), count: 14)) }
        objects.append([0x51, 0x78])
        return bplist(objects)
    }

    static func page(_ data: Data) -> ThumbnailPage {
        ThumbnailPage.make(data: data, fileName: "Shared.plist", fileSize: Int64(data.count), kind: .code(language: "plist"))
    }

    @Test func aSharedStringIsTooLargeToDraw() {
        let data = Self.sharedString
        #expect(data.count < 64 << 10, "within what a thumbnail reads")
        let start = ContinuousClock.now
        let page = Self.page(data)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(page.mark == .caution(ThumbnailPage.tooLargeToShow))
        guard case .text(let lines, _, _) = page.layout else { Issue.record("not text"); return }
        #expect(lines.isEmpty, "nothing of the expansion is drawn")
    }

    @Test func aTinyExponentialPlistIsTooLargeToDraw() {
        let start = ContinuousClock.now
        let page = Self.page(Self.laughs)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(page.mark == .caution(ThumbnailPage.tooLargeToShow))
    }

    @Test func anOrdinaryBinaryPlistIsStillDrawnAsXML() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Name": "Harbor", "Items": Array(repeating: "same", count: 200)],
                                                      format: .binary, options: 0)
        let page = Self.page(data)
        #expect(page.mark == .none)
        guard case .text(let lines, _, _) = page.layout else { Issue.record("not text"); return }
        let text = lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
        #expect(text.contains("<key>Items</key>"))
    }
}
