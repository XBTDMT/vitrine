import Compression
import Foundation
import Testing
@testable import VitrineFormats

// S-16 hardening of the VitrineFormats readers (security findings F6, F16, F17, F26–F31, F41, F48–F51 and their
// siblings). Every fixture is invented and assembled here; pickle streams are only scanned, never loaded.
// roadmap: S-16

// MARK: - Helpers

private func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for byte in data {
        c ^= UInt32(byte)
        for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
    }
    return ~c
}

private func adler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
    return b << 16 | a
}

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
private func be32(_ v: UInt32) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
private func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

/// Raw DEFLATE (RFC 1951), which is what Compression's COMPRESSION_ZLIB writes.
private func deflate(_ plain: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: plain.count + 1024)
    let n = compression_encode_buffer(&out, out.count, plain, plain.count, nil, COMPRESSION_ZLIB)
    precondition(n > 0)
    return Array(out.prefix(n))
}

/// An xz stream (Compression's COMPRESSION_LZMA writes the xz container).
private func xz(_ plain: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: plain.count + 4096)
    let n = compression_encode_buffer(&out, out.count, plain, plain.count, nil, COMPRESSION_LZMA)
    precondition(n > 0)
    return Array(out.prefix(n))
}

/// One gzip member: the fixed header with `flags`, the optional fields given, raw DEFLATE, CRC-32 and ISIZE.
private func gzipMember(_ plain: [UInt8], extra: [UInt8]? = nil, name: String? = nil, comment: String? = nil, headerCRC: Bool = false) -> [UInt8] {
    var flags: UInt8 = 0
    if extra != nil { flags |= 0x04 }
    if name != nil { flags |= 0x08 }
    if comment != nil { flags |= 0x10 }
    if headerCRC { flags |= 0x02 }
    var out: [UInt8] = [0x1F, 0x8B, 0x08, flags, 0, 0, 0, 0, 0, 3]
    if let extra { out += le16(extra.count) + extra }
    if let name { out += Array(name.utf8) + [0] }
    if let comment { out += Array(comment.utf8) + [0] }
    if headerCRC { out += le16(Int(crc32(out) & 0xFFFF)) }
    return out + deflate(plain) + le32(crc32(plain)) + le32(UInt32(plain.count))
}

private func zlibStream(_ plain: [UInt8]) -> [UInt8] { [0x78, 0x9C] + deflate(plain) + be32(adler32(plain)) }

private func pickle(_ bytes: [UInt8], _ name: String) -> PickleSummary? {
    guard case .pickle(let s)? = AIFormatsReader.read(data: Data(bytes), fileName: name, path: nil) else { return nil }
    return s
}

/// Wall-clock seconds `work` takes.
private func seconds(_ work: () -> Void) -> Double {
    let start = ContinuousClock.now
    work()
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Protocol-4 pickle opcodes.
private enum Op {
    static let proto4: [UInt8] = [0x80, 0x04]
    static func short(_ s: String) -> [UInt8] { [0x8C, UInt8(s.utf8.count)] + Array(s.utf8) }
    static func global(_ module: String, _ name: String) -> [UInt8] { [0x63] + Array("\(module)\n\(name)\n".utf8) }
    static let tuple1: [UInt8] = [0x85], reduce: [UInt8] = [0x52], stop: [UInt8] = [0x2E], none: [UInt8] = [0x4E]
}

// MARK: - F6: compressed pickles are followed exactly as Python reads them

@Suite struct S16PickleCompressionTests {
    /// GLOBAL os.system, then REDUCE: what loading it would run. Scanned only.
    static let malicious = Op.proto4 + Op.global("os", "system") + Op.short("echo invented") + Op.tuple1 + Op.reduce + Op.stop
    static let harmless = Op.proto4 + Op.none + Op.stop

    static func isNotClean(_ s: PickleSummary) -> Bool {
        AIDocument.pickle(s).highestLevel == .danger && s.headline != "Pickle with no imports"
            && s.headline != "Pickle using only known-safe imports"
    }

    /// The F6 exploit: XLEN bytes FE 01 (510). `(2 + 254) | 256` = 256 made the old scanner inflate a harmless
    /// stream hidden at offset 266 inside the extra field; Python skips all 510 bytes and unpickles os.system.
    static func fextraDecoy() -> [UInt8] {
        var extra = [UInt8](repeating: 0x41, count: 510)
        let decoy = deflate(harmless)
        extra.replaceSubrange(254..<(254 + decoy.count), with: decoy)
        var file: [UInt8] = [0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0, 3] + [0xFE, 0x01] + extra
        #expect(file.count == 522)
        file += deflate(malicious) + le32(crc32(malicious)) + le32(UInt32(malicious.count))
        return file
    }

    @Test func fextraLengthIsSkippedInFullAsPythonDoes() throws {
        let s = try #require(pickle(Self.fextraDecoy(), "model.joblib"))
        #expect(s.container == .compressed("gzip"))
        #expect(s.dangerousImports.map(\.name) == ["os.system"])
        #expect(s.headline.hasPrefix("Pickle that can run commands"))
        #expect(!s.warnings.contains { $0.reason.contains("could not be followed") })
        // The same bytes named .pkl take the same path.
        #expect(pickle(Self.fextraDecoy(), "model.pkl")?.dangerousImports.map(\.name) == ["os.system"])
    }

    @Test func everyGzipHeaderFieldIsFollowed() throws {
        let variants: [[UInt8]] = [
            gzipMember(Self.malicious),
            gzipMember(Self.malicious, extra: [UInt8](repeating: 7, count: 300)),
            gzipMember(Self.malicious, name: "model.pkl"),
            gzipMember(Self.malicious, comment: "invented comment"),
            gzipMember(Self.malicious, headerCRC: true),
            gzipMember(Self.malicious, extra: [1, 2, 3, 4], name: "n", comment: "c", headerCRC: true),
        ]
        for file in variants {
            let s = try #require(pickle(file, "m.joblib"))
            #expect(s.dangerousImports.map(\.name) == ["os.system"])
            #expect(!s.warnings.contains { $0.reason.contains("could not be followed") })
        }
    }

    @Test func multiMemberGzipIsReadAsOneStreamLikePython() throws {
        // The pickle is split across two members with zero padding between them; Python's GzipFile joins them.
        let cut = 5
        let file = gzipMember(Array(Self.malicious.prefix(cut))) + [0, 0, 0, 0] + gzipMember(Array(Self.malicious.dropFirst(cut)))
        let s = try #require(pickle(file, "m.joblib"))
        #expect(s.dangerousImports.map(\.name) == ["os.system"])
        #expect(!s.warnings.contains { $0.reason.contains("could not be followed") })
    }

    @Test func gzipThatCannotBeFollowedIsNeverClean() throws {
        let good = gzipMember(Self.harmless)
        let cases: [(String, [UInt8])] = [
            ("trailing garbage", good + Array("not another member".utf8)),
            ("cut inside the deflate data", Array(gzipMember(Self.malicious).prefix(16))),
            ("cut before the trailer", Array(good.dropLast(3))),
            ("unknown method", [0x1F, 0x8B, 0x07, 0] + Array(good.dropFirst(4))),
            ("cut inside the header", Array(good.prefix(8))),
            ("cut inside FEXTRA", [0x1F, 0x8B, 0x08, 0x04, 0, 0, 0, 0, 0, 3, 0xFF, 0x7F, 1, 2, 3]),
            ("unterminated FNAME", [0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 3] + Array("name".utf8)),
            ("damaged deflate", [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
        ]
        for (label, file) in cases {
            let s = try #require(pickle(file, "m.pkl"), "\(label)")
            #expect(Self.isNotClean(s), "\(label): \(s.headline)")
        }
        // A harmless first member followed by garbage still scans the member, but says the rest was not followed.
        let s = try #require(pickle(good + Array("trailing".utf8), "m.joblib"))
        #expect(s.headline == "Compressed pickle (only partly scanned)")
        #expect(s.warnings.contains { $0.level == .danger && $0.reason.contains("Treat it as unsafe") })
    }

    @Test func zlibStreamsFollowJoblib() throws {
        let one = try #require(pickle(zlibStream(Self.malicious), "m.joblib"))
        #expect(one.container == .compressed("zlib") && one.dangerousImports.map(\.name) == ["os.system"])
        #expect(!one.warnings.contains { $0.reason.contains("could not be followed") })
        // joblib's BinaryZlibFile reads one zlib stream after another.
        let split = zlibStream(Array(Self.malicious.prefix(6))) + zlibStream(Array(Self.malicious.dropFirst(6)))
        #expect(pickle(split, "m.joblib")?.dangerousImports.map(\.name) == ["os.system"])
        // A wrong Adler-32 or bytes after the stream: not followed, never clean.
        var badCheck = zlibStream(Self.harmless); badCheck[badCheck.count - 1] ^= 0xFF
        #expect(try Self.isNotClean(#require(pickle(badCheck, "m.joblib"))))
        #expect(try Self.isNotClean(#require(pickle(zlibStream(Self.harmless) + [1, 2, 3], "m.joblib"))))
    }

    @Test func oldJoblibZFHeaderIsParsedByItsFixedLayout() throws {
        // "ZF", the length as a hex literal padded to 19 bytes, then the zlib stream (the hex "0x" holds an "x",
        // 0x78, which the old reader mistook for the zlib header).
        let header = Array("ZF".utf8) + Array(String("0x\(String(Self.malicious.count, radix: 16))".padding(toLength: 19, withPad: " ", startingAt: 0)).utf8)
        #expect(header.count == 21)
        let s = try #require(pickle(header + zlibStream(Self.malicious), "old.pkl"))
        #expect(s.dangerousImports.map(\.name) == ["os.system"])
        // Python's zlib.decompress ignores what follows the one stream, so trailing bytes are not a problem here.
        let t = try #require(pickle(header + [0x20] + zlibStream(Self.malicious) + [9, 9], "old.pkl"))
        #expect(t.dangerousImports.map(\.name) == ["os.system"] && !t.warnings.contains { $0.reason.contains("could not be followed") })
        // A length field that is not hex makes the file unloadable: unscanned, never clean.
        let bad = Array("ZF0xZZZZ".utf8) + [UInt8](repeating: 0x20, count: 13) + zlibStream(Self.harmless)
        #expect(try Self.isNotClean(#require(pickle(bad, "old.pkl"))))
    }

    @Test func xzMustBeExactlyOneStream() throws {
        let one = try #require(pickle(xz(Self.malicious), "m.joblib"))
        #expect(one.container == .compressed("xz") && one.dangerousImports.map(\.name) == ["os.system"])
        #expect(!one.warnings.contains { $0.reason.contains("could not be followed") })
        // Two streams (the system decoder stops after the first) or trailing bytes: not followed, never clean.
        let split = xz(Array(Self.malicious.prefix(6))) + xz(Array(Self.malicious.dropFirst(6)))
        #expect(try Self.isNotClean(#require(pickle(split, "m.joblib"))))
        #expect(try Self.isNotClean(#require(pickle(xz(Self.harmless) + [0, 0, 0, 0], "m.joblib"))))
    }

    @Test func decompressedOutputPastTheCapIsReported() {
        var out: [UInt8] = []
        let big = [UInt8](repeating: 0x2E, count: 10_000)
        let end = PickleDecompression.inflate(deflate(big)[...], windowBits: -15, into: &out, limit: 4_096)
        #expect(out.count == 4_096)
        if case .stopped(let why) = end { #expect(why.contains("cap")) } else { Issue.record("not stopped") }
        // Exactly at the cap still ends cleanly.
        var exact: [UInt8] = []
        #expect(PickleDecompression.inflate(deflate(big)[...], windowBits: -15, into: &exact, limit: 10_000) != .stopped("cap"))
        #expect(exact.count == 10_000)
    }
}

// MARK: - F16, F17, F26–F31, F41: numbers from files never trap

@Suite struct S16NumberTests {
    @Test func formatMathHelpers() {
        #expect(FormatMath.saturatingAdd(Int.max, 1) == Int.max)
        #expect(FormatMath.saturatingAdd(Int.min, -1) == Int.min)
        #expect(FormatMath.saturatingSum([Int.max, Int.max, -5]) == Int.max - 5)
        #expect(FormatMath.end(Int.max - 1, 2) == nil && FormatMath.end(10, 5) == 15)
        #expect(FormatMath.int(.nan) == nil && FormatMath.int(.infinity) == nil && FormatMath.int(-.infinity) == nil)
        #expect(FormatMath.int(9_223_372_036_854_775_808.0) == nil)
        #expect(FormatMath.int(-9_223_372_036_854_775_808.0) == Int.min)
        #expect(FormatMath.int(rounding: 2.5) == 3 && FormatMath.int(-2.9) == -2)
    }

    /// F16: an hours field of 23 digits made `clock` trap.
    @Test func hugeSubtitleTimestampShowsNoClock() throws {
        let srt = "1\n00:00:00,000 --> 99999999999999999999999:00:00,000\nInvented line\n"
        guard case .subtitles(let s)? = EverydayReader.read(data: Data(srt.utf8), fileName: "x.srt") else { Issue.record("not subtitles"); return }
        let duration = try #require(s.facts.first { $0.label == "Duration" })
        #expect(duration.value == "—")
        #expect(SubtitleSummary.clock(.nan) == "—" && SubtitleSummary.clock(.infinity) == "—" && SubtitleSummary.clock(3.6e26) == "—")
        #expect(SubtitleSummary.clock(3725) == "1:02:05" && SubtitleSummary.clock(-4) == "0:00")
    }

    private func atom(_ type: String, _ body: [UInt8]) -> [UInt8] { be32(UInt32(8 + body.count)) + Array(type.utf8) + body }
    private var ftyp: [UInt8] { atom("ftyp", Array("M4A ".utf8) + be32(0) + Array("M4A isom".utf8)) }

    /// F17: an mvhd v1 duration of 2^64−1 over a timescale of 1 made the Duration fact trap.
    @Test func hugeAudioDurationShowsNoClock() throws {
        let mvhd = [1, 0, 0, 0] + be64(0) + be64(0) + be32(1) + be64(UInt64.max) + [UInt8](repeating: 0, count: 80)
        let file = Data(ftyp + atom("moov", atom("mvhd", mvhd)))
        guard case .audio(let s) = MediaReader.read(data: file, fileName: "x.m4a") else { Issue.record("not audio"); return }
        let duration = try #require(s.facts.first { $0.label == "Duration" })
        #expect(duration.value == "—")
        #expect(MediaText.duration(1.8e19) == "—" && MediaText.duration(.nan) == "—" && MediaText.duration(-1) == "—")
        #expect(MediaText.duration(185) == "3:05")
    }

    /// F28: a 64-bit largesize near Int.max at a non-zero offset overflowed `o + size`.
    @Test func hugeMP4AtomSizeIsTruncatedNotSummed() {
        let large = be32(1) + Array("free".utf8) + be64(0x7FFF_FFFF_FFFF_FFF0)
        let file = Data(ftyp + large + [UInt8](repeating: 0, count: 16))
        guard case .audio(let s) = MediaReader.read(data: file, fileName: "x.m4a") else { Issue.record("not audio"); return }
        #expect(s.truncated)
    }

    private enum PB {
        static func varint(_ v: UInt64) -> [UInt8] {
            var v = v, out: [UInt8] = []
            repeat { var byte = UInt8(v & 0x7F); v >>= 7; if v != 0 { byte |= 0x80 }; out.append(byte) } while v != 0
            return out
        }
        static func bytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] { varint(UInt64(field << 3 | 2)) + varint(UInt64(payload.count)) + payload }
        static func uint(_ field: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(v) }
    }

    /// F26: a 10-byte elem_type varint with the top bit set made `Int(tt.value)` trap.
    @Test func onnxElemTypeAboveIntMaxIsShownAsANumber() throws {
        let tensorType = PB.uint(1, UInt64.max)
        let input = PB.bytes(1, Array("pixels".utf8)) + PB.bytes(2, PB.bytes(1, tensorType))
        let graph = PB.bytes(2, Array("g".utf8)) + PB.bytes(11, input)
        let model = PB.uint(1, 9) + PB.bytes(7, graph) + PB.bytes(8, PB.uint(2, 17))
        guard case .onnx(let s)? = AIFormatsReader.read(data: Data(model), fileName: "net.onnx", path: nil) else { Issue.record("not ONNX"); return }
        let io = try #require(s.inputs.first)
        #expect(io.type == "type \(UInt64.max)")
    }

    /// F27: a negative structured sub-shape made the item size Int.min and `available - expected` trap.
    @Test func negativeNumpySubShapeIsRejected() throws {
        var header = "{'descr': [('a', '<i8', (-1152921504606846976,))], 'fortran_order': False, 'shape': (1,), }"
        while (10 + header.utf8.count + 1) % 64 != 0 { header += " " }
        header += "\n"
        let file = [0x93] + Array("NUMPY".utf8) + [1, 0] + le16(header.utf8.count) + Array(header.utf8) + [UInt8](repeating: 0, count: 8)
        guard case .numpyArray(let s)? = AIDataReader.read(data: Data(file), fileName: "x.npy") else { Issue.record("not npy"); return }
        #expect(s.dtype == nil && s.expectedDataBytes == nil)
        // A sub-shape whose product overflows gives no size rather than a wrong one.
        let huge = NumpyProbe.dtype("[('a', '<i8', (4611686018427387904, 4))]")
        #expect(huge != nil && huge?.itemSize == nil)
        #expect(NumpyProbe.dtype("[('a', '<i8', (2, 3))]")?.itemSize == 48)
    }

    /// F29: a 21-digit day count in a VALARM TRIGGER made `Int(abs(offset))` trap.
    @Test func hugeAlarmTriggerIsShownAsWritten() throws {
        for trigger in ["-P999999999999999999999D", "-P" + String(repeating: "9", count: 400) + "W"] {
            let ics = ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "SUMMARY:Invented", "DTSTART:20261103T090000Z",
                       "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:\(trigger)", "END:VALARM", "END:VEVENT", "END:VCALENDAR"].joined(separator: "\r\n")
            guard case .calendar(let c)? = EverydayReader.read(data: Data(ics.utf8), fileName: "x.ics") else { Issue.record("not a calendar"); return }
            let alarm = try #require(c.events.first?.alarms.first)
            #expect(alarm.trigger == trigger && alarm.offset == nil)
        }
        #expect(EverydayCalendar.parseDuration("P10000000W") == nil)    // past 10,000 years
        #expect(EverydayCalendar.parseDuration("-PT15M") == -900)
        #expect(EverydayCalendar.offsetWords(.infinity, relatedToEnd: false) == nil)
    }

    /// F30: stats counts of Int.max and 1 were added unchecked.
    @Test func promptfooStatsSumSaturates() throws {
        let json = #"{"evalId":"x","results":{"results":[],"stats":{"successes":9223372036854775807,"failures":1,"errors":-5}}}"#
        guard case .promptfoo(let s)? = AIDataReader.read(data: Data(json.utf8), fileName: "results.json") else { Issue.record("not promptfoo"); return }
        #expect(s.facts.contains { $0.value.contains("9,223,372,036,854,775,807") || $0.value.contains("9223372036854775807") })
    }

    /// F31: two spans of Int.max input tokens were summed unchecked.
    @Test func traceTokenSumSaturates() throws {
        func span(_ id: String) -> String {
            #"{"traceId":"t","spanId":"\#(id)","name":"chat","startTimeUnixNano":"1","endTimeUnixNano":"2","attributes":[{"key":"gen_ai.operation.name","value":{"stringValue":"chat"}},{"key":"gen_ai.usage.input_tokens","value":{"intValue":"9223372036854775807"}}]}"#
        }
        let json = #"{"resourceSpans":[{"scopeSpans":[{"spans":["# + span("a") + "," + span("b") + "]}]}]}"
        guard case .trace(let s)? = AIDataReader.read(data: Data(json.utf8), fileName: "trace.json") else { Issue.record("not a trace"); return }
        #expect(s.inputTokens == Int.max)
    }

    /// F41: input_tokens Int.max plus output_tokens 1 with no total_tokens.
    @Test func inspectTokenSumSaturates() throws {
        let log = #"{"version": 2, "status": "success", "eval": {"task": "t", "model": "m"}, "stats": {"model_usage": {"m": {"input_tokens": 9223372036854775807, "output_tokens": 1}}}, "samples": []}"#
        guard case .inspectEval(let s)? = AIDataReader.read(data: Data(log.utf8), fileName: "log.json") else { Issue.record("not Inspect"); return }
        #expect(s.facts.contains { $0.label.hasPrefix("Tokens") })
    }
}

/// Reaches the internal NumPy dtype parser for the sub-shape checks.
private enum NumpyProbe {
    static func dtype(_ descr: String) -> NPYDtype? {
        let header = "{'descr': \(descr), 'fortran_order': False, 'shape': (1,), }"
        var padded = header
        while (10 + padded.utf8.count + 1) % 64 != 0 { padded += " " }
        padded += "\n"
        let file = [0x93] + Array("NUMPY".utf8) + [1, 0] + le16(padded.utf8.count) + Array(padded.utf8)
        guard case .numpyArray(let s)? = AIDataReader.read(data: Data(file), fileName: "p.npy") else { return nil }
        return s.dtype
    }
}

// MARK: - F48–F51 and the rm -rf sibling: linear scans, proved on pathological input

@Suite struct S16LinearScanTests {
    /// F48: `# a` + spaces + `b` made `\s+#+$` quadratic in the run of spaces.
    @Test func headingWithAHugeRunOfSpacesIsLinear() {
        let doc = "# a" + String(repeating: " ", count: 400_000) + "b\n\nText.\n"
        let t = seconds { _ = AIFormatsReader.read(data: Data(doc.utf8), fileName: "CLAUDE.md", path: nil) }
        #expect(t < 2, "took \(t) s")
        #expect(RulesFileReader.closingSequenceRemoved("Title ##") == "Title")
        #expect(RulesFileReader.closingSequenceRemoved("Title\t#") == "Title")
        #expect(RulesFileReader.closingSequenceRemoved("Title#") == "Title#")
        #expect(RulesFileReader.closingSequenceRemoved("a ## #") == "a ##")
        #expect(RulesFileReader.closingSequenceRemoved("###") == "")
        #expect(RulesFileReader.closingSequenceRemoved("C# notes") == "C# notes")
    }

    /// F49: a From display name of letters with no `@` made the address regex quadratic.
    @Test func hugeFromDisplayNameIsLinear() {
        let eml = "From: " + String(repeating: "a", count: 400_000) + " <x@example.com>\r\nTo: y@example.com\r\nSubject: s\r\n\r\nbody\r\n"
        let t = seconds { _ = EverydayReader.read(data: Data(eml.utf8), fileName: "x.eml") }
        #expect(t < 2, "took \(t) s")
        #expect(EverydayMail.firstAddress(in: "support@bank.example")?.domain == "bank.example")
        #expect(EverydayMail.firstAddress(in: "Help <x.y+z@mail.bank.co.uk>")! == ("x.y+z@mail.bank.co.uk", "mail.bank.co.uk"))
        #expect(EverydayMail.firstAddress(in: "a@b") == nil)                       // no dot group
        #expect(EverydayMail.firstAddress(in: "a@b. c@d.e")! == ("c@d.e", "d.e"))   // the first that matches
        #expect(EverydayMail.firstAddress(in: "@x.y") == nil && EverydayMail.firstAddress(in: "Ana Lima") == nil)
        #expect(EverydayMail.firstAddress(in: "q@a.b.")! == ("q@a.b", "a.b"))
    }

    /// F50: cue text of repeated `<lang ` with no `>` made `<lang ([^>]+)>` quadratic.
    @Test func repeatedUnclosedLangTagsAreLinear() {
        let vtt = "WEBVTT\n\n00:00.000 --> 00:01.000\n" + String(repeating: "<lang ", count: 200_000) + "\n"
        let t = seconds { _ = EverydayReader.read(data: Data(vtt.utf8), fileName: "x.vtt") }
        #expect(t < 2, "took \(t) s")
        #expect(EverydaySubtitles.languageTags("<lang en>Hi</lang> <lang fr-CA>Salut") == ["en", "fr-CA"])
        #expect(EverydaySubtitles.languageTags("<lang >x <lang de>y") == ["de"])
        #expect(EverydaySubtitles.languageTags("<lang en") == [])
    }

    /// F51: a STYLE block of repeated `::cue(` made the selector regex quadratic, with or without a final `)`.
    @Test func repeatedUnclosedCueSelectorsAreLinear() {
        for tail in ["", ")"] {
            let vtt = "WEBVTT\n\nSTYLE\n" + String(repeating: "::cue(", count: 200_000) + tail + "\n\n00:00.000 --> 00:01.000\nhi\n"
            let t = seconds { _ = EverydayReader.read(data: Data(vtt.utf8), fileName: "x.vtt") }
            #expect(t < 2, "took \(t) s")
        }
        #expect(EverydaySubtitles.cssSelectors("::cue(.yellow) { color: yellow }\n::cue { x }\n::cue(v[voice=\"Ana\"]){}") == ["yellow", "cue", "v[voice=\"Ana\"]"])
        #expect(EverydaySubtitles.cssSelectors("::cue(.a) ::cue(.b) {}") == ["b"])
        // As the regex did: `[^)]*` runs to the first ")", so the first selector swallows the second.
        #expect(EverydaySubtitles.cssSelectors("::cue(.a {} ::cue(.b) {}") == ["a {} ::cue(.b"])
        #expect(EverydaySubtitles.cssSelectors("::cue (x) {}") == [])
    }

    /// Sibling: `\brm\s+-[a-z]*r[a-z]*f` backtracked quadratically over a long flag run with no `f`.
    @Test func longRmFlagRunIsLinear() {
        let config = #"{"mcpServers": {"x": {"command": "sh", "args": ["-c", "rm -"# + String(repeating: "r", count: 200_000) + #""]}}}"#
        let t = seconds { _ = AIFormatsReader.read(data: Data(config.utf8), fileName: "mcp.json", path: nil) }
        #expect(t < 2, "took \(t) s")
        for yes in ["rm -rf /", "sudo rm -fr x", "rm  -vrf a", "x;rm\t-rvf", "rm -rmrf"] { #expect(MCPConfigReader.deletesRecursively(yes), "\(yes)") }
        for no in ["rm -r x", "rm -f x", "farm -rf", "rm -r -f", "rm-rf", "rm -R f"] { #expect(!MCPConfigReader.deletesRecursively(no), "\(no)") }
    }
}

// MARK: - Sibling sites of the same classes, found by sweeping the module

@Suite struct S16SiblingTests {
    /// MediaAudio WAV: an RF64 ds64 data size of UInt64.max overflowed `UInt64(body) + d`.
    @Test func rf64HugeDataSizeIsReportedAsCut() {
        let ds64 = Array("ds64".utf8) + le32(28) + [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 12)
        let fmt = Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8_000) + le32(16_000) + le16(2) + le16(16)
        let file = Array("RF64".utf8) + le32(0xFFFF_FFFF) + Array("WAVE".utf8) + ds64 + fmt + Array("data".utf8) + le32(0xFFFF_FFFF) + [1, 2, 3, 4]
        guard case .audio(let s) = MediaReader.read(data: Data(file), fileName: "x.wav") else { Issue.record("not audio"); return }
        #expect(s.truncated)
    }

    /// MediaModel glTF: accessor counts of Int.max summed into the triangle total.
    @Test func gltfHugeAccessorCountsSaturate() {
        let json = #"{"asset":{"version":"2.0"},"accessors":[{"count":9223372036854775807}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"mode":5},{"attributes":{"POSITION":0},"mode":5},{"attributes":{"POSITION":0},"mode":4},{"attributes":{"POSITION":0},"mode":4}]}]}"#
        #expect(MediaReader.read(data: Data(json.utf8), fileName: "x.gltf") != nil)
    }

    /// MediaC2PA JUMBF: a child box's 64-bit XLBox near Int.max overflowed `o + length`.
    @Test func jumbfHugeXLBoxIsCutToTheParent() {
        let child = be32(1) + Array("jumd".utf8) + be64(0x7FFF_FFFF_FFFF_FFFE) + [UInt8](repeating: 0, count: 8)
        let jumbf = be32(UInt32(8 + child.count)) + Array("jumb".utf8) + child
        let chunk = be32(UInt32(jumbf.count)) + Array("caBX".utf8) + jumbf + be32(0)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk
        _ = MediaReader.provenance(data: Data(png))
    }

    /// MediaProvenance ISO BMFF: a 64-bit largesize near Int.max made `o += size` and `o + 8` overflow.
    @Test func isobmffHugeLargesizeIsCutToTheFile() {
        for lead in [[UInt8](), be32(16) + Array("ftyp".utf8) + Array("heic".utf8) + be32(0)] {
            let big = be32(1) + Array((lead.isEmpty ? "ftyp" : "free").utf8) + be64(0x7FFF_FFFF_FFFF_FFFE) + [UInt8](repeating: 0, count: 8)
            _ = MediaReader.provenance(data: Data(lead + big))
        }
    }
}

// MARK: - The linear scans give exactly what the regexes they replace gave

/// Random token strings from a fixed seed, compared against the original regex on input short enough for it.
@Suite struct S16RegexEquivalenceTests {
    struct Seeded {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        mutating func text(_ tokens: [String], maxTokens: Int = 14) -> String {
            (0..<next(maxTokens + 1)).map { _ in tokens[next(tokens.count)] }.joined()
        }
    }

    @Test func headingClosingSequence() {
        var r = Seeded(state: 48)
        for _ in 0..<3_000 {
            let text = r.text(["#", "##", " ", "\t", "a", "b c"]).trimmingCharacters(in: .whitespaces)
            var expected = text
            if let range = expected.range(of: #"\s+#+$"#, options: .regularExpression) { expected.removeSubrange(range) }
            else if expected.allSatisfy({ $0 == "#" }) { expected = "" }
            #expect(RulesFileReader.closingSequenceRemoved(text) == expected, "\(text.debugDescription)")
        }
    }

    @Test func fromAddress() {
        var r = Seeded(state: 49)
        for _ in 0..<3_000 {
            let text = r.text(["a", "Z9", "@", ".", "-", "%", "+", "_", " ", "é", "<", ">", "b.c", "x@y"])
            let m = text.firstMatch(of: /[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)/)
            let got = EverydayMail.firstAddress(in: text)
            #expect(got?.address == m.map { String($0.0) } && got?.domain == m.map { String($0.1) }, "\(text.debugDescription)")
        }
    }

    @Test func vttLanguageTags() {
        var r = Seeded(state: 50)
        for _ in 0..<3_000 {
            let text = r.text(["<lang ", ">", "en", " ", "<", "x", "\n", "<lang>"])
            let expected = text.matches(of: /<lang ([^>]+)>/).map { String($0.1) }
            #expect(EverydaySubtitles.languageTags(text) == expected, "\(text.debugDescription)")
        }
    }

    @Test func vttCueSelectors() {
        var r = Seeded(state: 51)
        for _ in 0..<3_000 {
            let text = r.text(["::cue", "(", ")", "{", " ", ".a", "b", "\n", ":", "::cue("])
            var expected: [String] = []
            for match in text.matches(of: /::cue(\(([^)]*)\))?\s*\{/) {
                var name = match.2.map(String.init) ?? "cue"
                if name.hasPrefix(".") { name.removeFirst() }
                if !expected.contains(name) { expected.append(name) }
            }
            #expect(EverydaySubtitles.cssSelectors(text) == expected, "\(text.debugDescription)")
        }
    }

    @Test func recursiveDelete() {
        var r = Seeded(state: 52)
        for _ in 0..<3_000 {
            let text = r.text(["rm", " ", "\t", "-", "r", "f", "a", "_", ";", "é", "x", "rm -"])
            let expected = text.range(of: #"\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r"#, options: .regularExpression) != nil
            #expect(MCPConfigReader.deletesRecursively(text) == expected, "\(text.debugDescription)")
        }
    }
}
