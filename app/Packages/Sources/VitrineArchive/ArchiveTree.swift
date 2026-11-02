import Foundation

/// An outline of an archive built from flat member paths: folders the paths imply are created, children are sorted
/// folders first and then by name the way Finder sorts (case-insensitive, numbers by value). Nodes live in one flat
/// array addressed by index, so a path 30,000 segments deep costs no recursion to build, compare or free, and an
/// outline view can use the index as its item identity. Nodes keep only their own name: storing each node's full
/// path would make one deep name cost the square of its length (a 64 KB zip name, about a gigabyte).
public struct ArchiveTree: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        /// This node's position in `nodes`.
        public var index: Int
        /// The last path segment ("" for the root).
        public var name: String
        public var isFolder: Bool
        /// The entry this node stands for, as an index into the entries (or paths) the tree was built from. Nil for
        /// folders that only member paths imply.
        public var entryIndex: Int?
        public var parent: Int?
        public var children: [Int]
        public var depth: Int
        /// Files and other non-folder members at or below this node.
        public var descendantCount: Int
        /// Uncompressed bytes at or below this node (0 when built from bare paths).
        public var totalSize: Int64

        public var isImplied: Bool { isFolder && entryIndex == nil }
    }

    /// `nodes[0]` is the root; every child's index is greater than its parent's.
    public let nodes: [Node]

    public var root: Node { nodes[0] }
    public func children(of node: Node) -> [Node] { node.children.map { nodes[$0] } }
    public func node(at path: String) -> Node? {
        var current = 0
        for part in ArchivePath.components(path) {
            guard let next = nodes[current].children.first(where: { nodes[$0].name == part && nodes[$0].isFolder })
                    ?? nodes[current].children.first(where: { nodes[$0].name == part }) else { return nil }
            current = next
        }
        return nodes[current]
    }

    /// The normalized path from the root to `node` (see `ArchivePath.normalized`), built on demand.
    public func path(of node: Node) -> String {
        var parts: [String] = []
        var current: Int? = node.index
        while let i = current, i != 0 {
            parts.append(nodes[i].name)
            current = nodes[i].parent
        }
        return parts.reversed().joined(separator: "/")
    }

    /// From a listing's entries; `entryIndex` indexes `entries`.
    public init(entries: [ArchiveEntry]) {
        self.init(items: entries.map { ($0.path, $0.type == .directory, $0.uncompressedSize ?? 0) })
    }

    /// From bare paths; a trailing `/` marks a folder. `entryIndex` indexes `paths`.
    public init(paths: [String]) {
        self.init(items: paths.map { ($0, $0.hasSuffix("/"), 0) })
    }

    private init(items: [(path: String, isFolder: Bool, size: Int64)]) {
        var nodes = [Node(index: 0, name: "", isFolder: true, entryIndex: nil, parent: nil, children: [], depth: 0,
                          descendantCount: 0, totalSize: 0)]
        // Folder lookup per node: name → child index. Files are never merged, so duplicates stay visible.
        var folderChildren: [[String: Int]] = [[:]]

        for (index, item) in items.enumerated() {
            let parts = ArchivePath.components(item.path)
            if parts.isEmpty { continue }                     // "/", "./": nothing to place
            var current = 0
            for (depth, part) in parts.enumerated() {
                let isLast = depth == parts.count - 1
                if isLast && !item.isFolder {
                    nodes.append(Node(index: nodes.count, name: part, isFolder: false, entryIndex: index,
                                      parent: current, children: [], depth: depth + 1, descendantCount: 0,
                                      totalSize: item.size))
                    folderChildren.append([:])
                    nodes[current].children.append(nodes.count - 1)
                    break
                }
                if let existing = folderChildren[current][part] {
                    current = existing
                } else {
                    nodes.append(Node(index: nodes.count, name: part, isFolder: true, entryIndex: nil,
                                      parent: current, children: [], depth: depth + 1, descendantCount: 0,
                                      totalSize: 0))
                    folderChildren.append([:])
                    let new = nodes.count - 1
                    nodes[current].children.append(new)
                    folderChildren[current][part] = new
                    current = new
                }
                if isLast, nodes[current].entryIndex == nil { nodes[current].entryIndex = index }
            }
        }

        // Children always follow their parent, so one backwards pass totals every subtree.
        for i in stride(from: nodes.count - 1, through: 1, by: -1) {
            guard let parent = nodes[i].parent else { continue }
            if !nodes[i].isFolder { nodes[i].descendantCount = 1 }
            nodes[parent].descendantCount += nodes[i].descendantCount
            let (sum, overflow) = nodes[parent].totalSize.addingReportingOverflow(nodes[i].totalSize)
            nodes[parent].totalSize = overflow ? .max : sum
        }
        let keys = nodes.map { (isFolder: $0.isFolder, name: $0.name, entry: $0.entryIndex ?? -1) }
        for i in nodes.indices where nodes[i].children.count > 1 {
            nodes[i].children.sort { a, b in
                let x = keys[a], y = keys[b]
                if x.isFolder != y.isFolder { return x.isFolder }
                if x.name != y.name { return Self.nameOrder(x.name, y.name) }
                return x.entry < y.entry
            }
        }
        self.nodes = nodes
    }

    /// Finder-style name order: case-insensitive, digits compared by value, then exact text as the tie-breaker so
    /// the order is total.
    public static func nameOrder(_ a: String, _ b: String) -> Bool {
        switch a.compare(b, options: [.caseInsensitive, .numeric]) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }
}
