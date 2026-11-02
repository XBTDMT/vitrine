import Foundation
import XCTest
@testable import VitrineText

/// Fixtures are made at test time in a fresh temporary folder from invented content. The only tool run is
/// `/usr/bin/diff`; no test runs `git` (ruled 2026-10-29, option A: git's output is kept as saved sample patches in
/// PatchParserSampleTests). Nothing outside the folder is read.
final class DiffFixtureFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitrine-diff-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    func write(_ relative: String, _ text: String) throws { try write(relative, Data(text.utf8)) }

    func write(_ relative: String, _ data: Data) throws {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    func remove(_ relative: String) throws { try FileManager.default.removeItem(at: path(relative)) }

    func symlink(_ relative: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative).path, withDestinationPath: target)
    }

    func chmod(_ relative: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path(relative).path)
    }

    /// Runs `/usr/bin/diff` in the folder with `arguments`; returns stdout. Exit 1 (files differ) is success.
    @discardableResult
    func diff(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": url.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard [0, 1].contains(process.terminationStatus) else {
            throw DiffFixtureError.toolFailed("diff \(arguments.joined(separator: " ")) → \(process.terminationStatus): "
                                              + String(decoding: errors, as: UTF8.self))
        }
        return output
    }

    /// `diff -u` of two files in the folder; exit 1 (files differ) is success.
    func diffU(_ a: String, _ b: String, extra: [String] = []) throws -> Data {
        try diff((extra.contains { $0.hasPrefix("-U") } ? extra : extra + ["-u"]) + [a, b])
    }
}

enum DiffFixtureError: Error { case toolFailed(String) }

/// Deterministic pseudo-random numbers (xorshift64*), so random tests are the same on every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}

/// Applies a file's hunks to the old text's lines and returns the new lines: the proof that a diff is correct.
func apply(_ file: DiffFile, to old: [String]) -> [String]? {
    var out: [String] = []
    var cursor = 0                                       // 0-based index into old
    for hunk in file.hunks {
        let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
        guard start >= cursor, start <= old.count else { return nil }
        out += old[cursor..<start]
        cursor = start
        for line in hunk.lines {
            switch line.kind {
            case .context:
                guard cursor < old.count, old[cursor] == line.text else { return nil }
                out.append(line.text); cursor += 1
            case .deleted:
                guard cursor < old.count, old[cursor] == line.text else { return nil }
                cursor += 1
            case .added:
                out.append(line.text)
            }
        }
    }
    out += old[cursor...]
    return out
}

/// Lines of a text as the diff sees them (terminators dropped, no phantom empty line after a final newline).
func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
}

/// Checks the invariants every parsed file must hold, whatever the input: numbering steps by one, counts match.
func assertConsistent(_ patch: Patch, file: StaticString = #filePath, line: UInt = #line) {
    for f in patch.files {
        if !f.isDetailOmitted {
            XCTAssertEqual(f.additions, f.hunks.reduce(0) { $0 + $1.additions }, "additions of \(f.path)", file: file, line: line)
            XCTAssertEqual(f.deletions, f.hunks.reduce(0) { $0 + $1.deletions }, "deletions of \(f.path)", file: file, line: line)
        }
        for h in f.hunks {
            var old = h.oldStart, new = h.newStart
            for l in h.lines {
                switch l.kind {
                case .context:
                    if !f.isCombined { XCTAssertEqual(l.oldNumber, old, file: file, line: line) }
                    XCTAssertEqual(l.newNumber, new, file: file, line: line)
                    old += 1; new += 1
                case .deleted:
                    if !f.isCombined { XCTAssertEqual(l.oldNumber, old, file: file, line: line) }
                    XCTAssertNil(l.newNumber, file: file, line: line)
                    old += 1
                case .added:
                    XCTAssertNil(l.oldNumber, file: file, line: line)
                    XCTAssertEqual(l.newNumber, new, file: file, line: line)
                    new += 1
                }
            }
        }
    }
    XCTAssertEqual(patch.totals.files, patch.coverage.filesSeen, file: file, line: line)
    XCTAssertLessThanOrEqual(patch.files.count, patch.totals.files, file: file, line: line)
}
