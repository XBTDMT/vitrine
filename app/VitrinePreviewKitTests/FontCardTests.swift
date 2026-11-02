import AppKit
import CoreText
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// Font files on the facts card (S-23, N-1, parity B-6). The fonts are the ones every Mac has, read in place from
/// /System/Library/Fonts and never copied; the WOFF 2 files are the KaTeX fonts Vitrine already ships inside its
/// framework; the WOFF is built in the test by wrapping a system TrueType font's tables uncompressed (the WOFF 1.0
/// spec allows a table stored as is when its compressed length equals its length).
@MainActor
final class FontCardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func system(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(path) is not on this Mac") }
        return url
    }

    private func katex(_ name: String) throws -> URL {
        let bundle = Bundle(for: FontRenderer.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: "woff2", subdirectory: "web/vendor/katex/fonts"), "\(name).woff2 in the framework")
    }

    /// A WOFF 1.0 file around a TrueType font, every table stored uncompressed.
    private func woff(wrapping ttf: URL) throws -> URL {
        let font = [UInt8](try Data(contentsOf: ttf))
        func u16(_ o: Int) -> Int { Int(font[o]) << 8 | Int(font[o + 1]) }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        let count = u16(4)
        var out: [UInt8] = []
        func p32(_ v: Int) { out += [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func p16(_ v: Int) { out += [UInt8(v >> 8 & 255), UInt8(v & 255)] }
        var offset = 44 + 20 * count
        var directory: [(tag: Int, offset: Int, length: Int, checksum: Int)] = []
        var body: [UInt8] = []
        var sfntSize = 12 + 16 * count
        for i in 0..<count {
            let r = 12 + 16 * i
            let (tag, checksum, start, length) = (u32(r), u32(r + 4), u32(r + 8), u32(r + 12))
            var table = Array(font[start..<start + length])
            while table.count % 4 != 0 { table.append(0) }
            directory.append((tag, offset, length, checksum))
            body += table
            offset += table.count
            sfntSize += table.count
        }
        p32(0x774F_4646); p32(u32(0)); p32(44 + 20 * count + body.count); p16(count); p16(0); p32(sfntSize)
        p16(1); p16(0); p32(0); p32(0); p32(0); p32(0); p32(0)
        for d in directory { p32(d.tag); p32(d.offset); p32(d.length); p32(d.length); p32(d.checksum) }
        out += body
        let url = dir.appendingPathComponent(ttf.deletingPathExtension().lastPathComponent + ".woff")
        try Data(out).write(to: url)
        return url
    }

    private func render(_ url: URL, width: CGFloat = 900, height: CGFloat = 640) async throws -> (RenderedPreview, InfoCardView) {
        let preview = try await FontRenderer().render(url: url, kind: .font, context: RenderContext(appearance: .light, defaultsSuite: "vt-font"))
        let view = try XCTUnwrap(preview.view as? InfoCardView)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        return (preview, view)
    }

    /// Every character the grid shows has a glyph in the font (no fallback is ever drawn).
    private func assertGridIsCovered(_ info: FontFileInfo, file: StaticString = #filePath, line: UInt = #line) {
        let font = CTFontCreateWithFontDescriptor(info.faces[0].descriptor, 12, nil)
        for character in info.gridCharacters {
            let utf16 = Array(character.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count), "glyph for \(character)", file: file, line: line)
        }
    }

    // MARK: Formats

    func testTrueTypeFontReadsItsNameTableGlyphsScriptsAndFeatures() throws {
        let info = try FontFileInfo.read(url: try system("/System/Library/Fonts/Supplemental/Arial.ttf"))
        XCTAssertEqual(info.container, .trueType)
        XCTAssertEqual(info.formatName, "TrueType")
        XCTAssertEqual(info.family, "Arial")
        XCTAssertEqual(info.faces.count, 1)
        XCTAssertGreaterThan(info.glyphCount, 1_000)
        XCTAssertEqual(Array(info.scripts.prefix(3)), ["Latin", "Greek", "Cyrillic"])
        XCTAssertFalse(info.isVariable)
        XCTAssertNotNil(info.version)
        XCTAssertNotNil(info.designer)
        XCTAssertFalse(info.features.isEmpty, "GSUB/GPOS feature tags")
        XCTAssertTrue(info.features.allSatisfy { $0.count <= 4 && !$0.isEmpty })
        XCTAssertEqual(info.gridCharacters.count, 36)
        XCTAssertEqual(info.gridCharacters.first, "A")
        XCTAssertEqual(info.sample, "Sphinx of black quartz, judge my vow")

        let card = FontCard.make(info, fileSize: 1)
        XCTAssertEqual(card.kindName, "Font")
        XCTAssertTrue(card.sentence.hasPrefix("A font, Arial"), card.sentence)
        XCTAssertTrue(card.sentence.contains("glyphs covering Latin, Greek"), card.sentence)
        XCTAssertEqual(card.strip.map(\.label), ["Glyphs", "Format", "Scripts"])
        XCTAssertEqual(card.sections.map(\.title), ["Sizes", "Font", "Features"])
        XCTAssertEqual(card.actions.map(\.title), ["Install…", "Copy name"])
    }

    func testCollectionListsItsStyles() throws {
        let info = try FontFileInfo.read(url: try system("/System/Library/Fonts/Helvetica.ttc"))
        XCTAssertEqual(info.container, .collection)
        XCTAssertEqual(info.formatName, "TrueType collection")
        XCTAssertGreaterThan(info.faces.count, 1)
        XCTAssertEqual(Set(info.faces.map(\.fullName)).count, info.faces.count)
        let card = FontCard.make(info, fileSize: 1)
        XCTAssertTrue(card.sentence.hasPrefix("A font collection, Helvetica, with \(info.faces.count) styles and "), card.sentence)
        XCTAssertEqual(card.strip[1], .init(value: "\(info.faces.count)", label: "Styles"))
        XCTAssertEqual(info.specimenFaces.map(\.style).prefix(2), ["Regular", "Bold"])
    }

    func testVariableFontNamesItsAxesAndInstances() throws {
        let info = try FontFileInfo.read(url: try system("/System/Library/Fonts/NewYork.ttf"))
        XCTAssertTrue(info.isVariable)
        XCTAssertTrue(info.axes.map(\.tag).contains("wght"))
        XCTAssertTrue(info.formatName.hasSuffix(", variable"))
        XCTAssertGreaterThan(info.namedInstances, 1)
        let card = FontCard.make(info, fileSize: 1)
        XCTAssertTrue(card.sentence.hasPrefix("A variable font, "), card.sentence)
        XCTAssertEqual(card.strip[1].label, "Axes")
        XCTAssertTrue(card.strip[1].value.contains("wght"))
        XCTAssertTrue(card.sections.map(\.title).contains("Axes"))
        guard case .rows(let rows) = card.sections[1].content else { return XCTFail("font rows") }
        XCTAssertEqual(rows.first { $0.key == "Styles" }?.value, "\(info.namedInstances) named instances")
        let weight = try XCTUnwrap(info.axes.first { $0.tag == "wght" })
        let heavy = info.font(size: 20, variation: ["wght": weight.maximum + 100])
        XCTAssertEqual(fontWeightValue(heavy), weight.maximum, "a weight past the axis is held to its end")
    }

    private func fontWeightValue(_ font: NSFont) -> Double? {
        (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[NSNumber(value: 0x7767_6874)]?.doubleValue
    }

    func testOpenTypeCFF() throws {
        let info = try FontFileInfo.read(url: try system("/System/Library/Fonts/Supplemental/STIXGeneral.otf"))
        XCTAssertEqual(info.container, .cff)
        XCTAssertEqual(info.formatName, "OpenType (CFF)")
    }

    func testWOFF2ShippedInTheFrameworkReads() throws {
        let info = try FontFileInfo.read(url: try katex("KaTeX_Main-Regular"))
        XCTAssertEqual(info.container, .woff2)
        XCTAssertEqual(info.outlines, .trueType)
        XCTAssertEqual(info.formatName, "WOFF 2 (TrueType)")
        XCTAssertEqual(info.family, "KaTeX_Main")
        XCTAssertEqual(FontCard.shortFormat(info), "WOFF 2")
        assertGridIsCovered(info)
    }

    func testWOFFBuiltInTheTestReads() throws {
        let url = try woff(wrapping: try system("/System/Library/Fonts/Supplemental/Arial.ttf"))
        XCTAssertEqual(FileSniffer.kind(of: url), .font)
        let info = try FontFileInfo.read(url: url)
        XCTAssertEqual(info.container, .woff)
        XCTAssertEqual(info.formatName, "WOFF (TrueType)")
        XCTAssertEqual(info.family, "Arial")
    }

    func testAFontWithoutLatinShowsItsOwnLetters() throws {
        let info = try FontFileInfo.read(url: try system("/System/Library/Fonts/Supplemental/NotoSansJavanese-Regular.otf"))
        guard !info.scripts.contains("Latin") else { throw XCTSkip("this Noto build carries Latin") }
        XCTAssertNotEqual(info.sample, "Sphinx of black quartz, judge my vow", "no pangram drawn in borrowed glyphs")
        XCTAssertFalse(info.gridCharacters.isEmpty)
        assertGridIsCovered(info)
    }

    // MARK: Words

    func testLicenceNamesAndVersions() {
        XCTAssertEqual(FontFileInfo.licenceName("This Font Software is licensed under the SIL Open Font License, Version 1.1. This license is available"),
                       "SIL Open Font License 1.1")
        XCTAssertEqual(FontFileInfo.licenceName("Licensed under the Apache License, Version 2.0"), "Apache License 2.0")
        XCTAssertEqual(FontFileInfo.licenceName("You may use this font to display and print content. Other uses need a licence."),
                       "You may use this font to display and print content")
        XCTAssertEqual(FontFileInfo.cleanVersion("Version 2.104; ttfautohint (v1.8.3)"), "2.104")
        XCTAssertEqual(FontFileInfo.cleanVersion("22.0d4e2"), "22.0d4e2")
    }

    // MARK: The card drawn

    func testRendererDrawsTheSpecimenAndSwitchesToText() async throws {
        let (preview, view) = try await render(try system("/System/Library/Fonts/Helvetica.ttc"))
        XCTAssertEqual(preview.document.kind, .font)
        XCTAssertEqual(preview.document.viewTitles, ["Glyphs", "Text", "Info"])
        XCTAssertEqual(view.titleField.stringValue, "Helvetica")
        let specimen = try XCTUnwrap(view.stageContent as? FontSpecimenView)
        XCTAssertEqual(specimen.cells.count, 36)
        XCTAssertEqual(specimen.sampleLines.count, 3)
        XCTAssertGreaterThan(specimen.frame.height, specimen.cellSize * 3, "the stage grows to hold three rows of square cells")
        let first = specimen.cells[0].frame, second = specimen.cells[1].frame
        XCTAssertEqual(first.width, first.height, accuracy: 0.5, "square cells")
        XCTAssertEqual(second.minX - first.maxX, FontSpecimenView.gap, accuracy: 0.5)
        let sizes = try XCTUnwrap(view.sectionViews.first { $0.section.title == "Sizes" })
        XCTAssertNotNil(sizes.subviews.first { $0 is TokenBox }?.subviews.first { $0 is FontWaterfallView })
        let samples = try XCTUnwrap(view.subviews.compactMap { $0 as? FontSamplesView }.first)
        XCTAssertTrue(samples.isHidden)
        XCTAssertEqual(preview.showView?(1), true)
        XCTAssertFalse(samples.isHidden)
        XCTAssertTrue(view.scrollView.isHidden)
        XCTAssertEqual(samples.styleNames.count, min(60, specimen.info.faces.count))
        XCTAssertEqual(preview.showView?(2), false, "Info is the host's text view")
        XCTAssertEqual(preview.showView?(0), true)
        XCTAssertTrue(samples.isHidden)
        XCTAssertFalse(view.scrollView.isHidden)
    }

    func testUnreadableFontThrows() async throws {
        let url = dir.appendingPathComponent("broken.ttf")
        try Data([0, 1, 0, 0] + [UInt8](repeating: 7, count: 60)).write(to: url)
        do {
            _ = try await FontRenderer().render(url: url, kind: .font, context: RenderContext(appearance: .light, defaultsSuite: "vt-font"))
            XCTFail("expected a throw")
        } catch {}
    }
}
