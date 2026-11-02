import AppKit

/// Keeps the last few rendered previews alive so arrowing back and forth in Finder is instant. Keyed by path plus
/// modification date, so a changed file never serves a stale view. Bounded; evicts least recently used.
@MainActor
public final class PreviewCache {
    public struct Key: Hashable, Sendable {
        public let path: String
        public let modified: Date?
        public let size: Int64?
        public init(url: URL) {
            path = url.path
            // FileManager, not URL.resourceValues: a URL caches resource values, so a reused URL would key a
            // changed file to its old preview.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            modified = attrs?[.modificationDate] as? Date
            size = (attrs?[.size] as? NSNumber)?.int64Value
        }
    }

    private var storage: [Key: RenderedPreview] = [:]
    private var order: [Key] = []
    public let capacity: Int

    public init(capacity: Int = 4) { self.capacity = capacity }

    public func preview(for key: Key) -> RenderedPreview? {
        guard let hit = storage[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    public func store(_ preview: RenderedPreview, for key: Key) {
        storage[key] = preview
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    public func discard(path: String) {
        for key in storage.keys where key.path == path { storage.removeValue(forKey: key) }
        order.removeAll { $0.path == path }
    }

    public var count: Int { storage.count }
}
