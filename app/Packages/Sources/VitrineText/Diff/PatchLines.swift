import Foundation

/// The patch as an index of lines over its bytes. The parser decides what a line is from its first bytes, so it
/// works on bytes and decodes text only for what it keeps: a 10 MB patch is split once, and a line past the detail
/// caps is never turned into a `String`. A patch may mix encodings (a Latin-1 file inside a UTF-8 patch), so
/// decoding is per line: UTF-8 when valid, else Latin-1, which accepts any byte.
struct PatchLines {
    let bytes: [UInt8]
    private(set) var starts: [Int] = []
    /// End of the line's content: before the `\n`, and before a `\r` that precedes it.
    private(set) var ends: [Int] = []
    private(set) var crlf: [Bool] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
        let estimate = bytes.count / 40 + 1
        starts.reserveCapacity(estimate); ends.reserveCapacity(estimate); crlf.reserveCapacity(estimate)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            let count = buffer.count
            while start < count {
                let found = memchr(base + start, 0x0A, count - start)
                let newline = found.map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base } ?? count
                var end = newline
                let cr = end > start && base[end - 1] == 0x0D
                if cr { end -= 1 }
                starts.append(start); ends.append(end); crlf.append(cr)
                start = newline + 1
            }
        }
    }

    var count: Int { starts.count }

    func length(_ i: Int) -> Int { ends[i] - starts[i] }

    func isEmpty(_ i: Int) -> Bool { ends[i] == starts[i] }

    func byte(_ i: Int, _ offset: Int) -> UInt8? {
        let p = starts[i] + offset
        return p < ends[i] ? bytes[p] : nil
    }

    func hasPrefix(_ i: Int, _ prefix: StaticString) -> Bool {
        let n = prefix.utf8CodeUnitCount
        guard length(i) >= n else { return false }
        return prefix.withUTF8Buffer { p in
            let s = starts[i]
            for k in 0..<n where bytes[s + k] != p[k] { return false }
            return true
        }
    }

    func hasSuffix(_ i: Int, _ suffix: StaticString) -> Bool {
        let n = suffix.utf8CodeUnitCount
        guard length(i) >= n else { return false }
        return suffix.withUTF8Buffer { p in
            let s = ends[i] - n
            for k in 0..<n where bytes[s + k] != p[k] { return false }
            return true
        }
    }

    func equals(_ i: Int, _ text: StaticString) -> Bool {
        length(i) == text.utf8CodeUnitCount && hasPrefix(i, text)
    }

    /// The line from `offset`, decoded; cut at `maxBytes` on a UTF-8 character boundary when longer.
    func text(_ i: Int, from offset: Int = 0, maxBytes: Int = .max) -> (text: String, truncated: Bool, latin1: Bool) {
        let s = min(starts[i] + offset, ends[i])
        var e = ends[i]
        var truncated = false
        if e - s > maxBytes {
            truncated = true
            e = s + maxBytes
            // Back off continuation bytes (10xxxxxx) so the cut never splits a character.
            var back = 0
            while e > s, back < 3, bytes[e] & 0xC0 == 0x80 { e -= 1; back += 1 }
        }
        let slice = bytes[s..<e]
        if let utf8 = String(validating: slice, as: UTF8.self) { return (utf8, truncated, false) }
        return (String(slice.map { Character(Unicode.Scalar($0)) }), truncated, true)
    }

    /// The whole line decoded, no cap: headers and paths.
    func string(_ i: Int, from offset: Int = 0) -> String { text(i, from: offset).text }

    /// Raw bytes of lines `range`, joined with `\n`, for re-parsing a decoded email body.
    func joinedBytes(_ range: Range<Int>) -> [UInt8] {
        var out: [UInt8] = []
        for i in range {
            out.append(contentsOf: bytes[starts[i]..<ends[i]])
            out.append(0x0A)
        }
        return out
    }
}
