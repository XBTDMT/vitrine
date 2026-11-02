import XCTest
import Darwin
@testable import VitrineSupport

/// An error type of the kind each engine conforms, so the tests can see which case the shared readers raised.
private enum Failure: ByteReadFailure, Equatable {
    case unreadable(String)
    case truncated(String)
    case malformed(String)
}

final class ByteSourceTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-bytes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = try folder().appendingPathComponent("bytes.bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func failure(_ body: () throws -> Void) -> Failure? {
        do { try body(); return nil } catch let error as Failure { return error } catch {
            XCTFail("unexpected error type \(type(of: error))"); return nil
        }
    }

    // MARK: file source

    func testFileSourceReadsWindowsAndClipsAtTheEnd() throws {
        let bytes = (0..<200).map { UInt8($0) }
        let source = try BoundedFileSource<Failure>(url: try file(bytes))
        XCTAssertEqual(source.size, 200)
        XCTAssertEqual(try source.read(at: 0, count: 4), [0, 1, 2, 3])
        XCTAssertEqual(try source.read(at: 196, count: 100), [196, 197, 198, 199], "fewer bytes only at the end")
        XCTAssertEqual(try source.read(at: 200, count: 1), [], "empty at the end")
        XCTAssertEqual(try source.read(at: 1 << 40, count: 1), [], "empty past the end, never an error")
        XCTAssertEqual(try source.read(at: -1, count: 4), [], "a negative offset reads nothing")
        XCTAssertEqual(try source.read(at: 0, count: 0), [])
        XCTAssertEqual(try source.read(at: 0, count: -5), [])
    }

    func testFileSourceRefusesSpecialFilesAndMissingOnes() throws {
        let dir = try folder()
        let pipe = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertEqual(failure { _ = try BoundedFileSource<Failure>(url: pipe) }, .unreadable("not a regular file"),
                       "a FIFO must be refused without blocking")
        XCTAssertEqual(failure { _ = try BoundedFileSource<Failure>(url: dir) }, .unreadable("not a regular file"))
        guard case .unreadable(let why)? = failure({
            _ = try BoundedFileSource<Failure>(url: dir.appendingPathComponent("missing"))
        }) else { return XCTFail("a missing file must be unreadable") }
        XCTAssertTrue(why.hasPrefix("cannot open the file"), why)
    }

    func testFileAndMemorySourcesAgree() throws {
        let bytes = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let file = try BoundedFileSource<Failure>(url: try file(bytes))
        let memory = MemoryByteSource(Data(bytes))
        XCTAssertEqual(memory.size, file.size)
        for (offset, count) in [(0, 1), (10, 90), (999, 5), (1000, 1), (-3, 3), (500, 0), (0, 5000)] {
            XCTAssertEqual(try file.read(at: Int64(offset), count: count), try memory.read(at: Int64(offset), count: count),
                           "offset \(offset) count \(count)")
        }
    }

    // MARK: slice source

    func testSliceClipsToItsBaseAndNeverCrossesItsEnd() throws {
        let base = MemoryByteSource((0..<100).map { UInt8($0) })
        let slice = SliceByteSource(base, start: 10, length: 5)
        XCTAssertEqual(slice.size, 5)
        XCTAssertEqual(try slice.read(at: 0, count: 100), [10, 11, 12, 13, 14], "never reads the neighbour")
        XCTAssertEqual(try slice.read(at: 5, count: 1), [])
        XCTAssertEqual(try slice.read(at: -1, count: 1), [])
        XCTAssertEqual(SliceByteSource(base, start: 90, length: 1 << 40).size, 10, "a lying length is clipped")
        XCTAssertEqual(SliceByteSource(base, start: 1 << 40, length: 8).size, 0, "a start past the end is empty")
        XCTAssertEqual(SliceByteSource(base, start: -20, length: 3).start, 0)
    }

    // MARK: exact reads

    func testReadExactlyNamesWhatEndedOrWentNegative() throws {
        let source = MemoryByteSource([1, 2, 3])
        XCTAssertEqual(try source.readExactly(3, at: 0, "the header", failing: Failure.self), [1, 2, 3])
        XCTAssertEqual(try source.readExactly(0, at: 99, "nothing", failing: Failure.self), [], "zero is an empty read")
        XCTAssertEqual(failure { _ = try source.readExactly(4, at: 0, "the header", failing: Failure.self) },
                       .truncated("the file ends inside the header"))
        XCTAssertEqual(failure { _ = try source.readExactly(-1, at: 0, "the table", failing: Failure.self) },
                       .malformed("the table has a negative length"))
    }

    // MARK: cursor

    func testCursorReadsBothByteOrders() throws {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        var little = BoundedByteCursor<Failure>(bytes, what: "x")
        XCTAssertEqual(try little.u16(), 0x0201)
        XCTAssertEqual(try little.u8(), 0x03)
        XCTAssertEqual(try little.u32(), 0x0706_0504)
        XCTAssertEqual(little.remaining, 1)
        var big = BoundedByteCursor<Failure>(bytes, bigEndian: true, what: "x")
        XCTAssertEqual(try big.u32(), 0x0102_0304)
        var whole = BoundedByteCursor<Failure>(bytes, bigEndian: true, what: "x")
        XCTAssertEqual(try whole.u64(), 0x0102_0304_0506_0708)
        var wide = BoundedByteCursor<Failure>(bytes, at: 1, what: "x")
        XCTAssertEqual(try wide.uint(width: 3), 0x04_0302)
        XCTAssertEqual(try wide.take(2), [0x05, 0x06])
        try wide.skip(1)
        XCTAssertEqual(wide.index, 7)
        try wide.seek(0)
        XCTAssertEqual(try wide.u8(), 0x01)
        try wide.seek(bytes.count)
        XCTAssertEqual(wide.remaining, 0, "seeking to the end itself is allowed")
    }

    func testCursorThrowsInsteadOfTrapping() {
        let bytes: [UInt8] = [1, 2, 3]
        var c = BoundedByteCursor<Failure>(bytes, at: 2, what: "the record")
        XCTAssertEqual(failure { _ = try c.u16() }, .truncated("the record ends early"))
        XCTAssertEqual(failure { _ = try c.u32() }, .truncated("the record ends early"))
        XCTAssertEqual(failure { _ = try c.u64() }, .truncated("the record ends early"))
        XCTAssertEqual(failure { _ = try c.take(2) }, .truncated("the record ends early"))
        XCTAssertEqual(failure { _ = try c.take(-1) }, .truncated("the record ends early"))
        XCTAssertEqual(failure { try c.skip(2) }, .truncated("the record ends early"))
        XCTAssertEqual(failure { try c.skip(-1) }, .truncated("the record ends early"))
        XCTAssertEqual(failure { _ = try c.uint(width: 9) }, .malformed("the record has a 9-byte number"))
        XCTAssertEqual(failure { _ = try c.uint(width: 0) }, .malformed("the record has a 0-byte number"))
        XCTAssertEqual(failure { try c.seek(4) }, .malformed("the record points outside itself"))
        XCTAssertEqual(failure { try c.seek(-1) }, .malformed("the record points outside itself"))
        XCTAssertEqual(c.index, 2, "a failed read leaves the position where it was")

        // A negative start (a damaged offset) must not reach memory either.
        var negative = BoundedByteCursor<Failure>(bytes, at: -2, what: "the slot")
        XCTAssertEqual(failure { _ = try negative.u8() }, .truncated("the slot ends early"))
        XCTAssertEqual(failure { _ = try negative.take(1) }, .truncated("the slot ends early"))
        XCTAssertEqual(failure { try negative.skip(1) }, .truncated("the slot ends early"))
    }

    func testCursorOverEmptyBytes() {
        var empty = BoundedByteCursor<Failure>([], what: "nothing")
        XCTAssertEqual(empty.remaining, 0)
        XCTAssertEqual(failure { _ = try empty.u8() }, .truncated("nothing ends early"))
        XCTAssertEqual(try empty.take(0), [])
    }
}
