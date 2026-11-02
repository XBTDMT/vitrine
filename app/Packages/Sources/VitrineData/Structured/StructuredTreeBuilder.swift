import Foundation

/// The one place nodes are made, shared by every parser so the limits mean the same thing everywhere. Parsers call it
/// in pre-order (`open` a container, add its children, `close` it); the builder decides what is kept:
///
/// - past `maxNodes` it keeps counting but stores nothing, so the coverage note can give the true total;
/// - past `maxDepth` it counts the deeper nodes and marks the ancestor at the limit `childrenOmitted`;
/// - it never recurses, and its stack of open containers lives on the heap.
struct StructuredTreeBuilder {
    let maxNodes: Int
    let maxDepth: Int
    let maxPreviewBytes: Int
    let pathStyle: StructuredPathStyle

    private(set) var nodes: [StructuredNode] = []
    /// Open containers: the stored index, or -1 for one that was counted but not kept.
    private var open: [Int32] = []
    private var roots: [Int32] = []
    private(set) var totalNodes = 0
    /// The deepest node seen, kept or not.
    private(set) var maxDepthSeen = 0
    private(set) var hitNodeLimit = false
    private(set) var hitDepthLimit = false
    var tags: [Int32: String] = [:]
    var anchors: [Int32: String] = [:]

    init(options: StructuredOptions, pathStyle: StructuredPathStyle) {
        maxNodes = max(0, min(options.maxNodes, Int(Int32.max - 1)))
        maxDepth = max(0, options.maxDepth)
        maxPreviewBytes = max(1, options.maxPreviewBytes)
        self.pathStyle = pathStyle
    }

    /// Depth the next node would get.
    var depth: Int { open.count }
    var openCount: Int { open.count }
    var isStoringNewNodes: Bool { nodes.count < maxNodes && (open.last ?? 0) >= 0 && open.count <= maxDepth }
    var rootCount: Int { roots.count }

    /// The innermost open container's stored index, if it was kept.
    var currentContainer: Int? {
        guard let top = open.last, top >= 0 else { return nil }
        return Int(top)
    }

    // MARK: Adding

    /// Adds a scalar. Returns its index when kept.
    @discardableResult
    mutating func leaf(_ kind: StructuredNodeKind, role: StructuredNodeRole = .value, name: String?, preview: String,
                       truncated: Bool = false, span: StructuredSpan) -> Int? {
        guard let index = add(kind, role: role, name: name, preview: preview, truncated: truncated, span: span) else { return nil }
        nodes[index].subtreeEndRaw = Int32(index + 1)
        return index
    }

    /// Adds a container and makes it the parent of what follows until `close`. Returns its index when kept.
    @discardableResult
    mutating func open(_ kind: StructuredNodeKind, role: StructuredNodeRole = .value, name: String?, preview: String = "",
                       span: StructuredSpan) -> Int? {
        let index = add(kind, role: role, name: name, preview: preview, truncated: false, span: span)
        open.append(index.map { Int32($0) } ?? -1)
        return index
    }

    /// Closes the innermost open container. `endOffset` (one past its last byte) completes its byte span.
    mutating func close(endOffset: Int64? = nil) {
        guard let top = open.popLast(), top >= 0 else { return }
        let index = Int(top)
        nodes[index].subtreeEndRaw = Int32(nodes.count)
        if let endOffset, nodes[index].offsetRaw >= 0 { nodes[index].lengthRaw = max(0, endOffset - nodes[index].offsetRaw) }
    }

    /// Text cut to the preview budget at a character boundary.
    func previewText(_ text: Substring) -> (String, Bool) {
        let utf8 = text.utf8
        if utf8.count <= maxPreviewBytes { return (String(text), false) }
        var end = utf8.index(utf8.startIndex, offsetBy: maxPreviewBytes)
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 { end = utf8.index(before: end) }
        return (String(decoding: utf8[..<end], as: UTF8.self), true)
    }

    func previewText(_ text: String) -> (String, Bool) { previewText(text[...]) }

    /// Marks the innermost kept container as missing children (the input ended or broke off inside it).
    mutating func markCurrentIncomplete() {
        if let current = currentContainer { nodes[current].childrenOmitted = true }
    }

    mutating func setPreview(_ index: Int, _ text: String, truncated: Bool) {
        nodes[index].preview = text
        nodes[index].isPreviewTruncated = truncated
    }

    mutating func setKind(_ index: Int, _ kind: StructuredNodeKind) { nodes[index].kind = kind }

    mutating func setLength(_ index: Int, _ length: Int64) { nodes[index].lengthRaw = length }

    private mutating func add(_ kind: StructuredNodeKind, role: StructuredNodeRole, name: String?, preview: String,
                              truncated: Bool, span: StructuredSpan) -> Int? {
        totalNodes += 1
        let depth = open.count
        if depth > maxDepthSeen { maxDepthSeen = depth }
        let parent = open.last ?? -1
        if parent >= 0 { nodes[Int(parent)].sourceChildCountRaw &+= 1 }
        // A node whose parent was not kept is not kept either; nothing to mark.
        if !open.isEmpty && parent < 0 { return nil }
        if depth > maxDepth {
            hitDepthLimit = true
            if parent >= 0 { nodes[Int(parent)].childrenOmitted = true }
            return nil
        }
        if nodes.count >= maxNodes {
            hitNodeLimit = true
            if parent >= 0 { nodes[Int(parent)].childrenOmitted = true }
            return nil
        }
        let index = nodes.count
        var node = StructuredNode(kind: kind, role: role, name: name, preview: preview, isPreviewTruncated: truncated,
                                  parent: parent, depth: Int32(depth), span: span)
        if parent >= 0 {
            node.indexInParentRaw = nodes[Int(parent)].storedChildCount
            nodes[Int(parent)].storedChildCount += 1
        } else {
            node.indexInParentRaw = Int32(roots.count)
            roots.append(Int32(index))
        }
        nodes.append(node)
        return index
    }

    // MARK: Copying (YAML aliases)

    /// Whether `index` is a kept node whose subtree is finished (an alias to an open anchor would be recursive).
    func isComplete(_ index: Int) -> Bool { index >= 0 && index < nodes.count && nodes[index].subtreeEndRaw > Int32(index) }

    /// Appends a copy of the finished subtree at `source` as the next child, named `name`, through `open`/`leaf`/`close`
    /// so the node and depth limits apply to the copy as to anything else. Returns the number of source nodes copied,
    /// or nil (adding nothing) when that is more than `budget`. Copies keep the source's spans: they point at the
    /// anchored text, which is what an alias means.
    mutating func copySubtree(of source: Int, name: String?, budget: Int) -> Int? {
        let end = Int(nodes[source].subtreeEndRaw)
        let size = end - source
        guard size <= budget else { return nil }
        var stack: [Int32] = []
        for s in source..<end {
            let node = nodes[s]
            while let top = stack.last, top != node.parentRaw { stack.removeLast(); close() }
            let copyName = s == source ? name : node.name
            let copy: Int?
            if node.kind.isContainer {
                copy = open(node.kind, role: node.role, name: copyName, preview: node.preview, span: node.span)
                if let copy, node.childrenOmitted { nodes[copy].childrenOmitted = true }
                stack.append(Int32(s))
            } else {
                copy = leaf(node.kind, role: node.role, name: copyName, preview: node.preview,
                            truncated: node.isPreviewTruncated, span: node.span)
            }
            if let copy, let tag = tags[Int32(s)] { tags[Int32(copy)] = tag }
        }
        while !stack.isEmpty { stack.removeLast(); close() }
        return size
    }

    // MARK: Rollback (JSON Lines)

    struct Mark { let nodes: Int, roots: Int, total: Int, maxDepth: Int }

    /// A point to return to; valid only while no container is open.
    func mark() -> Mark { Mark(nodes: nodes.count, roots: roots.count, total: totalNodes, maxDepth: maxDepthSeen) }

    /// Forgets everything added since `mark`, closing anything still open.
    mutating func rollback(to mark: Mark) {
        open.removeAll()
        if nodes.count > mark.nodes { nodes.removeSubrange(mark.nodes...) }
        if roots.count > mark.roots { roots.removeSubrange(mark.roots...) }
        totalNodes = mark.total
        maxDepthSeen = mark.maxDepth
        tags = tags.filter { $0.key < Int32(mark.nodes) }
        anchors = anchors.filter { $0.key < Int32(mark.nodes) }
    }

    // MARK: Finishing

    /// Closes whatever is still open (marking it incomplete) and builds the child index.
    mutating func finish(inputEndedEarly: Bool) -> StructuredTree {
        while let top = open.last {
            if top >= 0, inputEndedEarly { nodes[Int(top)].childrenOmitted = true }
            close()
        }
        var childIndex = [Int32](repeating: 0, count: nodes.count)
        var next: Int32 = 0
        for i in nodes.indices {
            nodes[i].childStartRaw = next
            next += nodes[i].storedChildCount
        }
        var fill = nodes.map(\.childStartRaw)
        for i in nodes.indices {
            let parent = nodes[i].parentRaw
            guard parent >= 0 else { continue }
            childIndex[Int(fill[Int(parent)])] = Int32(i)
            fill[Int(parent)] += 1
        }
        return StructuredTree(pathStyle: pathStyle, nodes: nodes, roots: roots.map(Int.init), childIndex: childIndex,
                              tags: tags, anchors: anchors)
    }

    /// The limits this build ran into, for the coverage.
    var limitReasons: [StructuredLimit] {
        var reasons: [StructuredLimit] = []
        if hitNodeLimit { reasons.append(.nodeLimit(maxNodes)) }
        if hitDepthLimit { reasons.append(.depthLimit(maxDepth)) }
        return reasons
    }
}
