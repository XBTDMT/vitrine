import Foundation
import XCTest
@testable import VitrineBinary

final class VitrineBinaryTests: XCTestCase {
    func testInspectDispatchesByContent() throws {
        let fx = try SharedFixtures.get()
        guard case .machO(let file) = try VitrineBinary.inspect(fx.fat) else { return XCTFail("fat binary") }
        XCTAssertEqual(file.slices.count, 2)

        let folder = try FixtureFolder()
        try folder.write("Tiny.app/Contents/Info.plist", BundleReaderTests.plist(id: "com.example.tiny"))
        guard case .bundle(let bundle) = try VitrineBinary.inspect(folder.path("Tiny.app")) else { return XCTFail("bundle") }
        XCTAssertEqual(bundle.info.identifier, "com.example.tiny")
        XCTAssertNil(bundle.executable)

        // A disk image is recognised by its trailer even without the extension.
        var trailer = [UInt8](repeating: 0, count: 512)
        trailer.replaceSubrange(0..<4, with: Array("koly".utf8))
        trailer.replaceSubrange(8..<12, with: [0, 0, 2, 0])
        try folder.write("image.bin", bytes: [UInt8](repeating: 0, count: 1024) + trailer)
        guard case .diskImage(let image) = try VitrineBinary.inspect(folder.path("image.bin")) else { return XCTFail("dmg") }
        XCTAssertTrue(image.partitions.isEmpty)

        try folder.write("notes.txt", "plain text")
        assertBinaryError(try VitrineBinary.inspect(folder.path("notes.txt")), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        assertBinaryError(try VitrineBinary.inspect(folder.path("missing")))
        // A Java class file is not taken for a universal binary.
        try folder.write("Main.class", bytes: [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x41] + [UInt8](repeating: 0, count: 64))
        assertBinaryError(try VitrineBinary.inspect(folder.path("Main.class")))
    }

    /// ARCHITECTURE §7: these facts are part of the first paint. Read-only over the system's own apps; the bounds
    /// are generous (debug build) and the measured times are printed for the record.
    func testFirstPaintBudgetOnSystemApps() throws {
        let root = URL(fileURLWithPath: "/System/Applications")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard !names.isEmpty else { throw XCTSkip("no system apps to read") }
        let clock = ContinuousClock()
        var slowest: Duration = .zero, slowestName = ""
        var read = 0
        let total = clock.measure {
            for name in names {
                var once: Duration = .zero
                once = clock.measure { if (try? BundleReader.read(contentsOf: root.appendingPathComponent(name))) != nil { read += 1 } }
                if once > slowest { slowest = once; slowestName = name }
            }
        }
        print("VitrineBinary perf: \(read) of \(names.count) system apps read in \(total); slowest \(slowestName) \(slowest)")
        XCTAssertGreaterThan(read, names.count / 2)
        XCTAssertLessThan(slowest, .seconds(2))
    }
}
