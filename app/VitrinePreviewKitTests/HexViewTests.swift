import AppKit
import Darwin
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// The hex view itself (S-5): the renderer and its document, selection in both columns and the gutter, the drawer,
/// find and go-to, Copy as, and a 200 MB sparse file that opens without reading it and whose search cancels.
/// Every file is written by the test. roadmap: S-5
@MainActor
final class HexViewTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-hex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// The design's invented cache file: a signature run, a timestamp, zeros, text runs, then noise.
    private var sample: [UInt8] {
        var b = Array("ACMEPKG1".utf8) + [1, 0, 0, 0, 0x5B, 0x82, 0xD8, 0x6A]
        b += [0xF8, 0, 3, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0xD4, 0xC3, 0xB2, 0xA1]
        b += Array("notes/inbox\0n_0091\0Weekly plan\0name@example.com\0".utf8)
        b += [UInt8](repeating: 0, count: 128 - b.count)
        var x: UInt32 = 7
        for _ in 0..<256 { x = x &* 1_103_515_245 &+ 12_345; b.append(UInt8(truncatingIfNeeded: x >> 16)) }
        return b
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func render(_ url: URL) async throws -> (RenderedPreview, HexView) {
        let preview = try await HexRenderer().render(url: url, kind: .binary, context: RenderContext(appearance: .light, defaultsSuite: "vt-hex"))
        let view = try XCTUnwrap(preview.view as? HexView)
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 440)
        view.layoutSubtreeIfNeeded()
        return (preview, view)
    }

    /// Draws the view into a bitmap, as the snapshot does; returns how many distinct colours it painted.
    private func paint(_ view: NSView) -> Int {
        autoreleasepool {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.bitmapData else { return 0 }
            var colours = Set<UInt32>()
            let step = rep.bitsPerPixel / 8
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    let p = data + y * rep.bytesPerRow + x * step
                    colours.insert(UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]))
                }
            }
            return colours.count
        }
    }

    /// Writes the view as PNGs (light and dark) into the folder named by VITRINE_HEX_PROOF, when set; off by default.
    private func proof(_ view: NSView, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["VITRINE_HEX_PROOF"] else { return }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(mode).png"))
        }
        view.appearance = nil
    }

    func testLayoutFitsSixteenEightOrFourBytes() {
        let wide = HexLayout.fitting(680, offsetDigits: 8, charWidth: 7)
        XCTAssertEqual(wide.bytesPerRow, 16)
        XCTAssertEqual(HexLayout.fitting(400, offsetDigits: 8, charWidth: 7).bytesPerRow, 8)
        XCTAssertEqual(HexLayout.fitting(250, offsetDigits: 8, charWidth: 7).bytesPerRow, 4)
        XCTAssertEqual(wide.hit(x: wide.hexCellX(9) + 3).index, 9, "the second group's cells sit past the gap")
        XCTAssertEqual(wide.hit(x: wide.asciiCellX(3) + 1).column, .ascii)
    }

    func testRegistryPicksTheHexViewForBinaries() {
        XCTAssertTrue(RendererRegistry.renderer(for: .binary) is HexRenderer)
        XCTAssertFalse(HexRenderer.canRender(.plainText))
    }

    func testDocumentNamesTheFormatAndOffersHexAndStrings() async throws {
        let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 8) + Array("IHDR-invented".utf8)
        let (preview, view) = try await render(try write("tiny.dat", png))
        XCTAssertEqual(view.signature?.name, "PNG image")
        XCTAssertEqual(preview.document.viewTitles, ["Hex", "Strings"])
        XCTAssertEqual(preview.document.fact("headline")?.value, "PNG image")
        XCTAssertEqual(preview.document.badges.first?.evidence, 0..<8)
        guard case .text(let strings) = preview.document.views[1] else { return XCTFail("Strings is text") }
        XCTAssertTrue(strings.contains("IHDR-invented"), strings)
        let capsule = CapsuleModel()
        capsule.show(preview.document, canToggleInspector: true, canFind: true)
        XCTAssertEqual(capsule.pillText, "Binary · PNG image · \(DocumentFacts.size(Int64(png.count)).value)")
        XCTAssertEqual(capsule.inspectorHelp, "Show or hide the byte decoder")
        XCTAssertEqual(preview.showView?(0), true, "Hex is drawn by the view itself")
        XCTAssertEqual(preview.showView?(1), false, "Strings goes to the host's text view")
        XCTAssertGreaterThan(paint(view), 4, "the rows and the evidence tint draw")
        try proof(view, "hex-png")
    }

    func testSelectionIsSharedByBothColumnsAndFeedsGutterAndDrawer() async throws {
        let (preview, view) = try await render(try write("harbor-cache.bin", sample))
        XCTAssertNil(preview.gutter, "nothing selected, nothing to say")
        XCTAssertTrue(view.readings.isEmpty)
        let l = view.layoutMetrics
        let rowY = HexLayout.topPad + HexLayout.rowHeight / 2
        // Click 0x0C in the hex column, shift-click 0x0F in the ASCII column: one selection, both columns.
        view.pointerSelect(at: NSPoint(x: l.hexCellX(12) + 4, y: rowY), extend: false, dragging: false)
        view.pointerSelect(at: NSPoint(x: l.asciiCellX(15) + 2, y: rowY), extend: true, dragging: false)
        XCTAssertEqual(view.selection, 0xC...0xF)
        XCTAssertEqual(view.activeColumn, .ascii)
        XCTAssertEqual(preview.gutter?.leading, "Offset 0x0C–0x0F · 4 bytes selected")
        XCTAssertEqual(view.readings.first?.value, "0x0C – 0x0F · 4 bytes")
        XCTAssertEqual(view.readings.first { $0.highlighted }?.value, "21 Oct 2026, 09:14:03 UTC")
        _ = await view.find("n_00", forward: true)
        try proof(view, "hex-selection")
        view.clearFind()
        view.setEndian(.big)
        XCTAssertEqual(view.readings.first { $0.label == "UInt32 BE" }?.value, 1_535_301_738.formatted())

        // A drag from the second row's first byte across two rows; then the keyboard extends it.
        view.pointerSelect(at: NSPoint(x: l.hexCellX(0) + 4, y: rowY + HexLayout.rowHeight), extend: false, dragging: false)
        view.pointerSelect(at: NSPoint(x: l.hexCellX(3) + 4, y: rowY + 2 * HexLayout.rowHeight), extend: true, dragging: true)
        XCTAssertEqual(view.selection, 0x10...0x23)
        view.moveCursor(by: 1, extend: true)
        XCTAssertEqual(view.selection, 0x10...0x24)
        view.moveCursor(rows: 1, extend: false)
        XCTAssertEqual(view.selection, 0x34...0x34)

        // ⌘C copies hex from the hex column, text from the ASCII column.
        let board = NSPasteboard(name: NSPasteboard.Name("vt-hex-\(UUID().uuidString)"))
        view.select(0x20...0x2A, column: .ascii)
        view.copySelection(to: board)
        XCTAssertEqual(board.string(forType: .string), "notes/inbox")
        view.select(0...3, column: .hex)
        view.copySelection(to: board)
        XCTAssertEqual(board.string(forType: .string), "41 43 4D 45")

        // ⌘I hides and shows the drawer.
        XCTAssertTrue(view.isInspectorShown)
        preview.toggleInspector?()
        XCTAssertFalse(view.isInspectorShown)
        XCTAssertGreaterThan(paint(view), 4)
    }

    func testCopyAsOffersHexCArrayBase64AndText() async throws {
        let (preview, view) = try await render(try write("dead.bin", [0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00]))
        var offer = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(offer.heading, "Copy all 6 bytes as")
        view.select(1...4)
        offer = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(offer.heading, "Copy 4 bytes as")
        XCTAssertEqual(offer.formats.map(\.title), ["Hex", "C array", "Base64", "Raw text", "Hex dump"])
        XCTAssertEqual(offer.formats[0].text(), "DE AD BE EF")
        XCTAssertEqual(offer.formats[1].text(), "const unsigned char bytes[4] = {\n    0xDE, 0xAD, 0xBE, 0xEF\n};")
        XCTAssertEqual(offer.formats[2].text(), "3q2+7w==")
        XCTAssertTrue(offer.formats[4].text().hasPrefix("00000001  DE AD BE EF"))
    }

    func testFindStepsThroughMatchesAndGoToJumps() async throws {
        var bytes = sample
        bytes += [0xDE, 0xAD, 0xBE, 0xEF] + [UInt8](repeating: 0x11, count: 40) + [0xDE, 0xAD, 0xBE, 0xEF]
        let (preview, view) = try await render(try write("find.bin", bytes))
        let find = try XCTUnwrap(preview.find)
        let r1 = await find("DE AD BE EF", true)
        XCTAssertEqual(r1, FindResult(count: 2, index: 0))
        XCTAssertEqual(view.matches, [384, 428])
        let r2 = await find("DE AD BE EF", true)
        XCTAssertEqual(r2.index, 1)
        let back = await find("DE AD BE EF", false)
        XCTAssertEqual(back.index, 0)
        let text = await find("WEEKLY", true)
        XCTAssertEqual(text.count, 1, "text ignores case")
        XCTAssertEqual(view.matches, [0x33])

        let jump = await find(":0x10", true)
        XCTAssertEqual(jump, FindResult(count: 1, index: 0))
        XCTAssertEqual(view.selection, 0x10...0x10)
        XCTAssertTrue(view.matches.isEmpty, "a jump clears the search")
        let past = await find(":99999", true)
        XCTAssertEqual(past.count, 0)
        XCTAssertTrue(preview.gutter?.trailing?.contains("past the end") == true, preview.gutter?.trailing ?? "")
        preview.clearFind?()
        XCTAssertNil(preview.gutter?.trailing)
    }

    /// Typing ahead: a newer query cancels the search before it, and both calls report the newest state.
    func testNewerQuerySupersedesTheRunningSearch() async throws {
        let (_, view) = try await render(try write("ahead.bin", sample + Array("plan".utf8)))
        view.searchChunkSize = 16
        let first = Task { await view.find("pla", forward: true) }
        let second = Task { await view.find("plan", forward: true) }
        let (a, b) = (await first.value, await second.value)
        XCTAssertEqual(a, b)
        XCTAssertEqual(view.matches.count, 2, "Weekly plan and the trailing plan")
    }

    func testReloadShowsTheNewBytesAndKeepsTheSelection() async throws {
        let url = try write("grow.bin", [1, 2, 3, 0])
        let (preview, view) = try await render(url)
        view.select(2...3)
        try Data([9, 9, 9, 9, 9, 9, 9, 9, 0]).write(to: url)
        let document = try await XCTUnwrap(preview.reload)(url)
        XCTAssertEqual(view.source.count, 9)
        XCTAssertEqual(view.selection, 2...3)
        XCTAssertEqual(document.fact("size")?.value, DocumentFacts.size(9).value)
    }

    func testEmptyFileOpens() async throws {
        let (preview, view) = try await render(try write("empty.bin", []))
        XCTAssertEqual(view.source.count, 0)
        let r = await preview.find?("00 00", true)
        XCTAssertEqual(r?.count, 0)
        XCTAssertGreaterThan(paint(view), 1)
    }

    // MARK: Large files

    /// 200 MB, sparse: nothing on disk but a few invented bytes at 150 MB.
    private func sparse() throws -> URL {
        let url = dir.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 200 * 1024 * 1024)
        try handle.seek(toOffset: 150 * 1024 * 1024)
        try handle.write(contentsOf: Data([0xCA, 0xFE, 0xF0, 0x0D]))
        try handle.close()
        return url
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testTwoHundredMegabyteFileOpensWithoutReadingIt() async throws {
        let url = try sparse()
        let before = footprint()
        let clock = ContinuousClock()
        let start = clock.now
        let (preview, view) = try await render(url)
        XCTAssertGreaterThan(paint(view), 2)
        // Scroll to the end and to the planted bytes: only the pages in view are read.
        view.scrollTo(topRow: view.map.maxTopRow)
        _ = paint(view)
        _ = await preview.find?(":\(150 * 1024 * 1024)", true)
        XCTAssertEqual(view.selection, Int64(150 * 1024 * 1024)...Int64(150 * 1024 * 1024))
        XCTAssertEqual(view.readings.first { $0.label == "UInt32 LE" }?.value, UInt32(0x0DF0FECA).formatted())
        _ = paint(view)
        let elapsed = clock.now - start
        XCTAssertLessThan(elapsed, .seconds(2), "opening, scrolling and jumping took \(elapsed)")
        XCTAssertEqual(view.source.count, 200 * 1024 * 1024)
        XCTAssertTrue(view.map.isScaled, "a 200 MB file scrolls through a scaled range")
        XCTAssertLessThanOrEqual(view.source.bytesRead, 2 * 1024 * 1024, "read \(view.source.bytesRead) bytes of 200 MB")
        let grown = Int64(footprint()) - Int64(before)
        // Measured 2026-10-30: about 17 MB, most of it AppKit's first controls and the first megabyte read for runs.
        XCTAssertLessThan(grown, 32 * 1024 * 1024, "memory grew by \(grown) bytes")
    }

    func testSearchOverTheLargeFileFindsAndCancels() async throws {
        let url = try sparse()
        let (preview, view) = try await render(url)
        let found = await preview.find?("CA FE F0 0D", true)
        XCTAssertEqual(found, FindResult(count: 1, index: 0))
        XCTAssertEqual(view.matches, [Int64(150 * 1024 * 1024)])

        // A search that would run to the end, cancelled from the gutter as soon as it shows progress.
        view.searchChunkSize = 256 * 1024
        let task = Task { await view.find("not in this file", forward: true) }
        while !view.isSearching { await Task.yield() }
        XCTAssertEqual(preview.gutter?.busy, true)
        XCTAssertTrue(preview.gutter?.trailing?.hasPrefix("Searching…") == true, preview.gutter?.trailing ?? "")
        preview.cancelWork?()
        let result = await task.value
        XCTAssertFalse(result.searchedAll, "a cancelled search says its count is a floor")
        XCTAssertFalse(view.isSearching)
        XCTAssertEqual(preview.gutter?.busy, false)
        let trailing = preview.gutter?.trailing ?? ""
        XCTAssertTrue(trailing.hasPrefix("Searched ") && trailing.hasSuffix("· stopped"), trailing)
        XCTAssertFalse(trailing.contains("200 MB of 200 MB"), trailing)
    }
}
