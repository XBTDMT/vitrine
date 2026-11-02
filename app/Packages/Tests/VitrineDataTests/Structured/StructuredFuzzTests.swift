import XCTest
@testable import VitrineData

/// Hostile input: random truncation, random garbage, byte flips and deep nesting must never crash, hang or break the
/// tree's invariants. Deterministic (seeded) so a failure reproduces.
final class StructuredFuzzTests: XCTestCase {
    static func randomJSON(depth: Int, _ random: inout SeededGenerator) -> String {
        let pick = depth > 4 ? Int(random.next() % 5) : Int(random.next() % 8)
        switch pick {
        case 0: return "\(Int(random.next() % 100_000) - 50_000)"
        case 1: return "\"s\(random.next() % 1000)\\n\\u00e9 é\""
        case 2: return ["true", "false", "null"][Int(random.next() % 3)]
        case 3: return "-\(random.next() % 100).\(random.next() % 1000)e\(random.next() % 9)"
        case 4: return "\"\""
        case 5, 6:
            let n = Int(random.next() % 5)
            return "{" + (0..<n).map { "\"k\($0)\":" + randomJSON(depth: depth + 1, &random) }.joined(separator: ",") + "}"
        default:
            let n = Int(random.next() % 5)
            return "[" + (0..<n).map { _ in randomJSON(depth: depth + 1, &random) }.joined(separator: ",") + "]"
        }
    }

    private static let yamlSample = """
    name: web # comment
    list:
      - a
      - {b: [1, 2], "c": 'd'}
      - |
        literal
        text
    anchor: &x {k: v}
    alias: *x
    folded: >-
      one
      two
    ---
    - second: doc
    """

    private static let tomlSample = #"""
    title = "x"
    [a.b]
    c = [1, 2, { d = "e" }]
    ml = """
    multi \
      line"""
    [[t]]
    when = 1979-05-27T07:32:00Z
    f = 1_000.5e-3
    """#

    private static let xmlSample = #"<?xml version="1.0"?><!DOCTYPE r [<!ENTITY e "x">]><r a="1" b='2'><!-- c --><x>t&amp;&e;</x><![CDATA[raw]]><?pi d?></r>"#

    private static let plistSample = "<plist><dict><key>a</key><array><integer>1</integer><data>AAEC</data><date>2026-01-01T00:00:00Z</date></array><key>b</key><true/></dict></plist>"

    private func check(_ data: Data, _ format: StructuredFormat, truncated: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        var options = StructuredOptions()
        options.maxNodes = 5_000
        let result = StructuredParser.parse(data, format: format, options: options, fileSize: truncated ? Int64(data.count) + 10 : nil)
        let issues = ST.problems(result.tree)
        XCTAssertEqual(issues, [], "\(format) \(data.count) bytes", file: file, line: line)
        XCTAssertLessThanOrEqual(result.tree.count, 5_000, file: file, line: line)
        if !result.coverage.isComplete { XCTAssertNotNil(result.coverage.note, file: file, line: line) }
        for i in result.tree.nodes.indices.prefix(50) { _ = result.tree.path(of: i) }
        _ = result.facts.entries()
        _ = StructuredFormatter.format(data, as: format)
    }

    func testRandomTruncationOfValidInput() {
        var random = SeededGenerator(seed: 0xF00D)
        var samples: [(String, StructuredFormat)] = [(Self.yamlSample, .yaml), (Self.tomlSample, .toml), (Self.xmlSample, .xml),
                                                    (Self.plistSample, .propertyList)]
        for _ in 0..<6 { samples.append((Self.randomJSON(depth: 0, &random), .json)) }
        samples.append(((0..<20).map { _ in Self.randomJSON(depth: 2, &random) }.joined(separator: "\n"), .jsonLines))
        for (text, format) in samples {
            let bytes = Array(text.utf8)
            for _ in 0..<60 {
                let cut = Int(random.next() % UInt64(bytes.count + 1))
                check(Data(bytes.prefix(cut)), format)
                check(Data(bytes.prefix(cut)), format, truncated: true)
            }
        }
    }

    func testByteFlipsAndInsertions() {
        var random = SeededGenerator(seed: 0xBEEF)
        let alphabet = Array("{}[]:,\"'\\/*#-?&!|>%@`=.\n\t \r0xe+<>![CDATA[".utf8) + [0x00, 0xFF, 0xC3, 0xE2, 0x80]
        let samples: [(String, StructuredFormat)] = [(Self.randomJSON(depth: 0, &random), .json), (Self.yamlSample, .yaml),
                                                    (Self.tomlSample, .toml), (Self.xmlSample, .xml), (Self.plistSample, .propertyList),
                                                    ("{\"a\":1}\n[2]\n\"x\"\n", .jsonLines)]
        for (text, format) in samples {
            for _ in 0..<150 {
                var bytes = Array(text.utf8)
                for _ in 0..<(1 + Int(random.next() % 4)) where !bytes.isEmpty {
                    let at = Int(random.next() % UInt64(bytes.count))
                    let byte = alphabet[Int(random.next() % UInt64(alphabet.count))]
                    if random.next() % 2 == 0 { bytes[at] = byte } else { bytes.insert(byte, at: at) }
                }
                check(Data(bytes), format)
            }
        }
    }

    func testPureGarbage() {
        var random = SeededGenerator(seed: 0xD1CE)
        for _ in 0..<80 {
            let count = Int(random.next() % 600)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            for format in StructuredFormat.allCases { check(Data(bytes), format) }
        }
        let binaryish = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30] + (0..<64).map { _ in UInt8(truncatingIfNeeded: random.next()) })
        check(binaryish, .propertyList)
    }

    /// A million levels of nesting, on a 512 KB stack: every parser is iterative, so this costs heap and finishes.
    func testDeepNestingNeverTouchesTheStack() {
        let depth = 200_000
        let cases: [(String, StructuredFormat)] = [
            (String(repeating: "[", count: depth) + String(repeating: "]", count: depth), .json),
            (String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth), .json),
            (String(repeating: "[", count: depth), .json),
            (String(repeating: "[", count: depth) + String(repeating: "]", count: depth), .yaml),
            (String(repeating: "- ", count: 2_000) + "x", .yaml),
            ("a = " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth), .toml),
            ("a = " + String(repeating: "{b = ", count: 20_000) + "1" + String(repeating: "}", count: 20_000), .toml),
            ("[" + (0..<20_000).map { "k\($0)" }.joined(separator: ".") + "]", .toml),
            (String(repeating: "<a>", count: 20_000) + String(repeating: "</a>", count: 20_000), .xml),
            ("<plist>" + String(repeating: "<array>", count: 20_000) + String(repeating: "</array>", count: 20_000) + "</plist>", .propertyList),
        ]
        let box = Box<[String]>()
        ST.onSmallStack {
            var lines: [String] = []
            let clock = ContinuousClock()
            for (text, format) in cases {
                var result: StructuredParseResult?
                let parse = clock.measure { result = StructuredParser.parse(Data(text.utf8), format: format) }
                guard let result else { continue }
                let issues = ST.problems(result.tree)
                let format = clock.measure { _ = StructuredFormatter.format(Data(text.utf8), as: format) }
                lines.append("\(result.format) depth \(result.maxDepth) stored \(result.tree.maxStoredDepth) issues \(issues.count) "
                    + "error \(result.error?.reason ?? "-") parse \(parse) format \(format)")
            }
            box.value = lines
        }
        let lines = box.value ?? []
        XCTAssertEqual(lines.count, cases.count)
        for line in lines {
            XCTAssertTrue(line.contains("issues 0"), line)
            XCTAssertTrue(line.contains("stored 512") || line.contains("error"), line)
        }
        print("deep nesting:\n" + lines.joined(separator: "\n"))
    }

    /// A binary plist whose arrays nest `count - 1` deep, built by hand: object n is a one-element array referring
    /// to object n + 1 (two-byte refs and offsets), the last is the integer 1.
    private func nestedBinaryPlist(_ count: Int) -> Data {
        var body: [UInt8] = Array("bplist00".utf8)
        var offsets: [Int] = []
        for n in 0..<count {
            offsets.append(body.count)
            body += n < count - 1 ? [0xA1, UInt8((n + 1) >> 8), UInt8((n + 1) & 0xFF)] : [0x10, 0x01]
        }
        let tableOffset = body.count
        for offset in offsets { body += [UInt8(offset >> 8), UInt8(offset & 0xFF)] }
        body += [0, 0, 0, 0, 0, 0, 2, 2]   // 5 unused, sort version, offset size, ref size
        body += withUnsafeBytes(of: UInt64(count).bigEndian, Array.init)
        body += withUnsafeBytes(of: UInt64(0).bigEndian, Array.init)
        body += withUnsafeBytes(of: UInt64(tableOffset).bigEndian, Array.init)
        return Data(body)
    }

    /// PropertyListSerialization parses binary plists recursively; on a 512 KB stack it must read a deep-but-legal one
    /// and refuse a hostile one (it stops at a few hundred levels on its own) without crashing.
    func testDeepBinaryPlistIsReadSafely() throws {
        let readable = nestedBinaryPlist(100), hostile = nestedBinaryPlist(20_000)
        let box = Box<[String]>()
        ST.onSmallStack {
            box.value = [readable, hostile].map { data in
                let result = StructuredParser.parse(data, format: .propertyList)
                return "depth \(result.maxDepth) nodes \(result.tree.count) issues \(ST.problems(result.tree).count) error \(result.error?.reason ?? "-")"
            }
        }
        let summaries = try XCTUnwrap(box.value)
        XCTAssertEqual(summaries.first, "depth 99 nodes 100 issues 0 error -")
        XCTAssertEqual(summaries.last, "depth 0 nodes 0 issues 0 error not a readable binary property list (damaged, or nested deeper than the system reader allows)")
    }
}
