import XCTest
@testable import VitrineUI

final class DesignTokensTests: XCTestCase {
    func testCSSVariablesCarryEveryToken() {
        let css = DesignTokens.standard.cssVariables(for: .dark)
        for name in ["--vt-bg", "--vt-text", "--vt-accent", "--vt-mono", "--vt-font", "--vt-size", "--vt-radius"] {
            XCTAssertTrue(css.contains(name + ":"), name)
        }
        XCTAssertTrue(css.contains(DesignTokens.standard.dark.background))
    }

    func testCSSColours() throws {
        let orange = try XCTUnwrap(NSColor(css: "#FF8000")?.usingColorSpace(.sRGB))
        XCTAssertEqual(orange.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(orange.greenComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(orange.alphaComponent, 1, accuracy: 0.01)
        let translucent = try XCTUnwrap(NSColor(css: "rgba(60,60,67,.74)")?.usingColorSpace(.sRGB))
        XCTAssertEqual(translucent.blueComponent, 67.0 / 255, accuracy: 0.01)
        XCTAssertEqual(translucent.alphaComponent, 0.74, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(NSColor(css: "#00000080")).alphaComponent, 128.0 / 255, accuracy: 0.01)
        XCTAssertNil(NSColor(css: "linear-gradient(180deg,#F3F4F7 0%,#E9EBF0 100%)"))
        XCTAssertNil(NSColor(css: "#12345"))
    }

    func testSystemPaletteComesFromTheDesignSystem() {
        XCTAssertEqual(DesignTokens.standard.light.background, GeneratedTokens.color("page")?.light)
        XCTAssertEqual(DesignTokens.standard.dark.accent, "#108070", "dark buttons use the deeper teal (D3)")
        XCTAssertEqual(GeneratedTokens.color("th-mark-caution")?.light, "#9E5400", "amber caution mark (D7)")
        let solidGrounds = ["page", "win", "card", "code", "t1", "accent", "accent-text"]
        for name in solidGrounds {
            let token = GeneratedTokens.color(name)
            XCTAssertNotNil(token.flatMap { NSColor(css: $0.light) }, name)
            XCTAssertNotNil(token.flatMap { NSColor(css: $0.dark) }, name)
        }
        XCTAssertTrue(DesignTokens.systemCSS(for: .light).contains("--v-danger-text: #D70015;"))
    }
}

final class TokenColorTests: XCTestCase {
    func testTokenColourFollowsAppearance() throws {
        let c = NSColor.token("accent-text")
        var light: NSColor?, dark: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = c.usingColorSpace(.sRGB) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = c.usingColorSpace(.sRGB) }
        XCTAssertEqual(try XCTUnwrap(light).greenComponent, 0x7B / 255.0, accuracy: 0.01, "#0D7B6C in light")
        XCTAssertEqual(try XCTUnwrap(dark).greenComponent, 0xC6 / 255.0, accuracy: 0.01, "#3CC6AA in dark")
    }

    func testMetrics() {
        XCTAssertEqual(Metric.value("h-capsule"), 40)
        XCTAssertEqual(Metric.value("h-gutter"), 56)
        XCTAssertEqual(Metric.value("h-pill"), 24)
    }
}
