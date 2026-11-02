import Foundation
import XCTest
@testable import VitrineData

/// A temporary directory per test, removed afterwards. Every fixture is generated here at run time from invented
/// values; nothing is read from outside it.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("VitrineDataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ text: String, name: String = "fixture.csv") throws -> URL {
        try write(Data(text.utf8), name: name)
    }

    func write(_ data: Data, name: String = "fixture.csv") throws -> URL {
        let file = url.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
}

enum CSVTestParse {
    /// Parses `bytes` in chunks of `chunk` bytes (nil: all at once) and returns every record's fields.
    static func records(_ bytes: [UInt8], delimiter: CSVDelimiter = .comma, quote: CSVQuote = .double,
                        chunk: Int? = nil, encoding: CSVTextEncoding = .utf8) -> (rows: [CSVRow], endedInsideQuotes: Bool) {
        var scanner = CSVScanner(delimiter: delimiter.rawValue, quote: quote.rawValue)
        var collector = CSVRecordCollector(encoding: encoding, maxFieldBytes: 1 << 20, limit: .max)
        let size = max(1, chunk ?? bytes.count)
        var start = 0
        bytes.withUnsafeBufferPointer { all in
            while start < all.count {
                let end = min(all.count, start + size)
                scanner.scan(UnsafeBufferPointer(rebasing: all[start..<end]), into: &collector)
                start = end
            }
        }
        scanner.finish(into: &collector)
        return (collector.rows, scanner.endedInsideQuotes)
    }

    static func fields(_ text: String, delimiter: CSVDelimiter = .comma, chunk: Int? = nil) -> [[String]] {
        records(Array(text.utf8), delimiter: delimiter, chunk: chunk).rows.map(\.fields)
    }
}

/// Deterministic pseudo-random numbers (SplitMix64) so generated fixtures are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
