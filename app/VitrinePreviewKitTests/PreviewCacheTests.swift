import XCTest
@testable import VitrinePreviewKit
import VitrineDocument

@MainActor
final class PreviewCacheTests: XCTestCase {
    private func key(_ name: String) throws -> PreviewCache.Key {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sbc-\(UUID().uuidString)-\(name)")
        try Data(name.utf8).write(to: url)
        return PreviewCache.Key(url: url)
    }

    func testStoreAndHit() throws {
        let cache = PreviewCache(capacity: 2)
        let k = try key("a")
        cache.store(RenderedPreview(view: NSView(), document: PreviewDocument(kind: .plainText, views: [.text("")])), for: k)
        XCTAssertNotNil(cache.preview(for: k))
    }

    func testEvictsLeastRecentlyUsed() throws {
        let cache = PreviewCache(capacity: 2)
        let a = try key("a"), b = try key("b"), c = try key("c")
        cache.store(RenderedPreview(view: NSView(), document: PreviewDocument(kind: .plainText, views: [.text("")])), for: a)
        cache.store(RenderedPreview(view: NSView(), document: PreviewDocument(kind: .plainText, views: [.text("")])), for: b)
        _ = cache.preview(for: a)   // a is now most recent
        cache.store(RenderedPreview(view: NSView(), document: PreviewDocument(kind: .plainText, views: [.text("")])), for: c)
        XCTAssertNil(cache.preview(for: b))
        XCTAssertNotNil(cache.preview(for: a))
        XCTAssertEqual(cache.count, 2)
    }

    func testModifiedFileMisses() throws {
        let cache = PreviewCache(capacity: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sbc-\(UUID().uuidString).txt")
        try Data("one".utf8).write(to: url)
        let k1 = PreviewCache.Key(url: url)
        cache.store(RenderedPreview(view: NSView(), document: PreviewDocument(kind: .plainText, views: [.text("")])), for: k1)
        try Data("one two three".utf8).write(to: url)
        XCTAssertNil(cache.preview(for: PreviewCache.Key(url: url)))
    }

    func testDiscardByPath() throws {
        let cache = PreviewCache(capacity: 2)
        let k = try key("a")
        cache.store(RenderedPreview(view: NSView(), document: PreviewDocument(kind: .plainText, views: [.text("")])), for: k)
        cache.discard(path: k.path)
        XCTAssertNil(cache.preview(for: k))
    }
}
