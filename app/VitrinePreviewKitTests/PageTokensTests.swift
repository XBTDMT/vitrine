import XCTest
@testable import VitrinePreviewKit
import VitrineUI

/// Every design token a page uses (`var(--v-name)`) is one Swift emits for it, so no page style silently falls back to
/// nothing: the shadow tokens once did (S-15 redman, 2026-11-01). roadmap: S-15
final class PageTokensTests: XCTestCase {
    func testEveryTokenThePagesUseIsEmitted() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let emitted = Set(DesignTokens.systemCSS(for: .light).components(separatedBy: ";").compactMap { decl -> String? in
            let d = decl.trimmingCharacters(in: .whitespaces)
            guard d.hasPrefix("--v-"), let colon = d.firstIndex(of: ":") else { return nil }
            return String(d[d.index(d.startIndex, offsetBy: 4)..<colon])
        })
        XCTAssertTrue(emitted.contains("shadow-pop") && emitted.contains("accent"), "the scan reads the emitted names")
        let use = try NSRegularExpression(pattern: #"var\(--v-([a-z0-9-]+)"#)
        let define = try NSRegularExpression(pattern: #"--v-([a-z0-9-]+)\s*:"#)
        var files: [URL] = []
        for folder in ["VitrinePreviewKit/Resources/web", "web-src"] {
            let root = app.appendingPathComponent(folder)
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                if url.path.contains("/vendor/") || url.path.contains("/node_modules/") || url.path.contains("/licenses/") { continue }
                if ["html", "js", "css", "ts"].contains(url.pathExtension) { files.append(url) }
            }
        }
        var used = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            let local = Set(define.matches(in: source, range: range).map { String(source[Range($0.range(at: 1), in: source)!]) })
            for match in use.matches(in: source, range: range) {
                let name = String(source[Range(match.range(at: 1), in: source)!])
                used += 1
                XCTAssertTrue(emitted.contains(name) || local.contains(name), "\(file.lastPathComponent) uses --v-\(name), which nothing defines")
            }
        }
        XCTAssertGreaterThan(used, 50, "the scan found the pages' tokens")
    }
}
