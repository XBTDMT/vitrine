import Foundation
import Synchronization
import XCTest
@testable import VitrineBinary

/// Every fixture is made at test time in a fresh temporary folder from invented names: binaries compiled by
/// `/usr/bin/clang` (never run), universal files by `lipo`, ad-hoc signatures by `codesign -s -`, packages by
/// `pkgbuild`/`productbuild` (never installed), disk images by `hdiutil create` (never attached), CMS messages and
/// certificates by `/usr/bin/openssl`. Hostile cases are built byte by byte.
final class FixtureFolder: @unchecked Sendable {
    let url: URL

    init(_ tag: String = "vitrine-binary-tests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL { try write(relative, Data(text.utf8)) }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    @discardableResult
    func write(_ relative: String, bytes: [UInt8]) throws -> URL { try write(relative, Data(bytes)) }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: path(relative), withIntermediateDirectories: true)
    }

    func copy(_ from: String, _ to: String) throws {
        try FileManager.default.createDirectory(at: path(to).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: path(from), to: path(to))
    }

    func bytes(_ relative: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: path(relative))) }

    /// Runs a system tool inside the folder (never a fixture) and throws with its stderr when it exits non-zero.
    @discardableResult
    func run(_ tool: String, _ arguments: [String], input: Data? = nil, allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                               "TMPDIR": FileManager.default.temporaryDirectory.path]
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            throw FixtureError.toolFailed("\(tool) \(arguments.joined(separator: " ")): "
                                          + String(decoding: errors, as: UTF8.self))
        }
        return String(decoding: output + errors, as: UTF8.self)
    }

    func compile(_ output: String, source: String = "int main(void){return 0;}\n", arch: [String] = ["arm64"],
                 extra: [String] = []) throws {
        let name = "src-\(UUID().uuidString).c"
        try write(name, source)
        try run("/usr/bin/clang", arch.flatMap { ["-arch", $0] } + ["-o", output, name] + extra)
    }
}

enum FixtureError: Error { case toolFailed(String) }

/// Folders that live for the whole test run (shared fixtures) are removed when the test bundle finishes, so nothing
/// is left in the temporary directory.
final class BundleCleanup: NSObject, XCTestObservation, @unchecked Sendable {
    private static let pending = Mutex<[FixtureFolder]?>(nil)

    static func keep(_ folder: FixtureFolder) {
        let first = pending.withLock { list -> Bool in
            defer { list = (list ?? []) + [folder] }
            return list == nil
        }
        if first {
            let observer = BundleCleanup()
            if Thread.isMainThread {
                MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(observer) }
            } else {
                DispatchQueue.main.sync { XCTestObservationCenter.shared.addTestObserver(observer) }
            }
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let folders = Self.pending.withLock { list -> [FixtureFolder] in defer { list = [] }; return list ?? [] }
        for folder in folders { try? FileManager.default.removeItem(at: folder.url) }
    }
}

/// Fixtures several test classes share, built once per test process (compiling and signing take a second or two).
final class SharedFixtures: @unchecked Sendable {
    let folder: FixtureFolder
    /// arm64 executable with an rpath, linked weakly against `libfx.dylib`.
    let thin: URL
    /// arm64 + x86_64 executable, minimum macOS 12.0, 32-bit fat header.
    let fat: URL
    /// The same two slices behind a 64-bit fat header.
    let fat64: URL
    /// A dylib with an install name and versions.
    let dylib: URL
    /// A copy of `thin` signed ad-hoc with entitlements, hardened runtime and an identifier.
    let signed: URL
    /// x86_64 built for macOS 10.13, which ld describes with LC_VERSION_MIN_MACOSX.
    let old: URL
    let arm64e: URL
    /// The entitlements `signed` and the app carry.
    let entitlements: [String: PlistValue]

    private static let lock = Mutex<SharedFixtures?>(nil)

    static func get() throws -> SharedFixtures {
        try lock.withLock { cached in
            if let cached { return cached }
            let built = try SharedFixtures()
            cached = built
            return built
        }
    }

    static let entitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
    <key>com.example.count</key><integer>42</integer>
    <key>com.example.groups</key><array><string>group.one</string><string>group.two</string></array>
    <key>com.example.nested</key><dict><key>flag</key><false/><key>name</key><string>inner</string></dict>
    </dict></plist>
    """

    private init() throws {
        let f = try FixtureFolder("vitrine-binary-shared")
        BundleCleanup.keep(f)
        folder = f
        try f.compile("libfx.dylib", source: "int fx(void){return 7;}\n", extra: [
            "-dynamiclib", "-install_name", "@rpath/libfx.dylib", "-current_version", "2.3.4",
            "-compatibility_version", "2.0"])
        dylib = f.path("libfx.dylib")
        try f.compile("thin", source: "extern int fx(void) __attribute__((weak_import));\nint main(void){return fx ? fx() : 0;}\n",
                      extra: ["-Wl,-rpath,@loader_path/../Frameworks", "-Wl,-weak_library,libfx.dylib",
                              "-mmacosx-version-min=13.0"])
        thin = f.path("thin")
        try f.compile("fat", arch: ["arm64", "x86_64"], extra: ["-mmacosx-version-min=12.0"])
        fat = f.path("fat")
        try f.compile("arm64.part", extra: ["-mmacosx-version-min=12.0"])
        try f.compile("x86.part", arch: ["x86_64"], extra: ["-mmacosx-version-min=12.0"])
        try f.run("/usr/bin/lipo", ["-create", "-fat64", "arm64.part", "x86.part", "-output", "fat64"])
        fat64 = f.path("fat64")
        try f.compile("old", arch: ["x86_64"], extra: ["-mmacosx-version-min=10.13"])
        old = f.path("old")
        try f.compile("arm64e", arch: ["arm64e"])
        arm64e = f.path("arm64e")
        try f.write("ent.plist", Self.entitlementsXML)
        try f.copy("thin", "signed")
        try f.run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", "ent.plist", "-o", "runtime",
                                        "-i", "com.example.signed", "signed"])
        signed = f.path("signed")
        entitlements = try PropertyListDecoder.dictionary(Array(Self.entitlementsXML.utf8), limit: 1 << 20, what: "x")
    }
}

/// Writes Mach-O bytes directly, for what no linker will make: impossible sizes, absurd counts, names pointing
/// outside their command, encrypted ranges, big-endian slices.
struct MachOBuilder {
    var bigEndian = false
    var is64 = true
    var cpuType: UInt32 = 0x0100_000C
    var cpuSubtype: UInt32 = 0
    var fileType: UInt32 = 2
    var flags: UInt32 = 0x0020_0085
    var commands: [[UInt8]] = []
    /// Override the header's command count and size (hostile cases).
    var declaredCount: UInt32?
    var declaredSize: UInt32?
    var trailing: [UInt8] = []

    func word(_ v: UInt32) -> [UInt8] {
        let b = [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        return bigEndian ? b.reversed() : b
    }

    func quad(_ v: UInt64) -> [UInt8] {
        let lo = word(UInt32(v & 0xFFFF_FFFF)), hi = word(UInt32(v >> 32))
        return bigEndian ? hi + lo : lo + hi
    }

    /// A load command: cmd, cmdsize (padded to 8 unless `size` is given), body.
    func command(_ cmd: UInt32, _ body: [UInt8], size: UInt32? = nil) -> [UInt8] {
        var padded = body
        while (padded.count + 8) % 8 != 0 { padded.append(0) }
        return word(cmd) + word(size ?? UInt32(padded.count + 8)) + padded
    }

    func dylib(_ cmd: UInt32, _ path: String, current: UInt32 = 0x10000, compat: UInt32 = 0x10000,
               nameOffset: UInt32 = 24) -> [UInt8] {
        command(cmd, word(nameOffset) + word(2) + word(current) + word(compat) + Array(path.utf8) + [0])
    }

    func build() -> [UInt8] {
        let magic: UInt32 = is64 ? 0xFEED_FACF : 0xFEED_FACE
        let body = commands.flatMap { $0 }
        var out = word(magic) + word(cpuType) + word(cpuSubtype) + word(fileType)
            + word(declaredCount ?? UInt32(commands.count)) + word(declaredSize ?? UInt32(body.count)) + word(flags)
        if is64 { out += word(0) }
        return out + body + trailing
    }
}

/// Big-endian helpers for hand-built containers (fat headers, SuperBlobs, koly trailers, xar headers).
extension Array where Element == UInt8 {
    mutating func be16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func be32(_ v: UInt32) { for i in (0..<4).reversed() { append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    mutating func be64(_ v: UInt64) { for i in (0..<8).reversed() { append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
}

/// Deterministic pseudo-random numbers (xorshift), so fuzzing is the same on every run.
struct XorShift {
    var state: UInt64
    init(_ seed: UInt64 = 0x9E37_79B9_7F4A_7C15) { state = seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(Swift.max(1, n))) }
}

/// Flips, overwrites and truncates `bytes` in `rounds` ways and hands each copy to `body`, which must not trap.
func fuzz(_ bytes: [UInt8], rounds: Int, seed: UInt64 = 1, body: ([UInt8]) -> Void) {
    var rng = XorShift(seed)
    for round in 0..<rounds {
        var copy = bytes
        switch round % 4 {
        case 0:                                                   // flip a few bytes in the first 4 KiB
            for _ in 0..<(1 + rng.below(8)) {
                let i = rng.below(Swift.min(copy.count, 4096)); copy[i] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            }
        case 1:                                                   // write an extreme 32-bit value somewhere
            let i = rng.below(Swift.max(1, Swift.min(copy.count, 4096) - 4))
            let v: [UInt8] = [[0xFF, 0xFF, 0xFF, 0xFF], [0, 0, 0, 0], [0x7F, 0xFF, 0xFF, 0xFF], [0x80, 0, 0, 0]][rng.below(4)]
            for k in 0..<4 where i + k < copy.count { copy[i + k] = v[k] }
        case 2:                                                   // truncate
            copy = Array(copy.prefix(rng.below(copy.count)))
        default:                                                  // damage anywhere, including the tail
            for _ in 0..<(1 + rng.below(16)) {
                let i = rng.below(copy.count); copy[i] = UInt8(truncatingIfNeeded: rng.next())
            }
        }
        body(copy)
    }
}

extension XCTestCase {
    /// Asserts that `body` throws a `BinaryError` (never a trap), optionally of the expected case.
    func assertBinaryError(_ body: @autoclosure () throws -> Any, matching predicate: (BinaryError) -> Bool = { _ in true },
                           _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try body()
            XCTFail("expected a BinaryError \(message)", file: file, line: line)
        } catch let error as BinaryError {
            XCTAssertTrue(predicate(error), "unexpected \(error) \(message)", file: file, line: line)
            XCTAssertFalse(error.reason.isEmpty, file: file, line: line)
        } catch {
            XCTFail("expected a BinaryError, got \(error) \(message)", file: file, line: line)
        }
    }
}
