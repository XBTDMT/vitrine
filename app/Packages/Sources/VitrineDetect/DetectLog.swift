import OSLog

// G-22: Obscura's logger stands in here for the detector engine ported from Obscura (ObscuraDetect, the same author's code).
// The same rule holds: log lines carry counts and ids, never matched text. roadmap: S-11, S-20

enum Log {
    static let detect = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "detect")
}

/// A value that is safe to log: a count or an identifier, never content.
struct Count: Sendable, CustomStringConvertible {
    let value: Int
    init(_ value: Int) { self.value = value }
    var description: String { String(value) }
}
