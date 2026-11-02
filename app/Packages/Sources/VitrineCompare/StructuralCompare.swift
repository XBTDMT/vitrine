import Foundation
import VitrineData
import VitrineText

/// Bounds for one structural compare. roadmap: S-7
public struct StructuralCompareLimits: Sendable, Equatable {
    /// Nodes each side's parse keeps; a larger document is compared as far as it was kept and marked incomplete.
    public var maxParsedNodes: Int
    /// Rows of the display tree; past it the tree stops growing but changes and counts go on.
    public var maxDisplayNodes: Int
    /// Entries of `changes`; past it the counts go on.
    public var maxChanges: Int
    /// Wall-clock time for the walk (parsing excluded).
    public var timeLimit: Duration
    /// Characters of an `old` / `new` value before it is cut with "…".
    public var maxValueCharacters: Int
    /// Nesting kept by the parse.
    public var maxDepth: Int
    /// Bytes read from each side.
    public var maxInputBytes: Int64

    public init(maxParsedNodes: Int = 500_000, maxDisplayNodes: Int = 20_000, maxChanges: Int = 5_000,
                timeLimit: Duration = .seconds(2), maxValueCharacters: Int = 200, maxDepth: Int = 256,
                maxInputBytes: Int64 = 64 * 1024 * 1024) {
        self.maxParsedNodes = max(1, maxParsedNodes); self.maxDisplayNodes = max(0, maxDisplayNodes)
        self.maxChanges = max(0, maxChanges); self.timeLimit = timeLimit
        self.maxValueCharacters = max(8, maxValueCharacters); self.maxDepth = max(1, maxDepth)
        self.maxInputBytes = max(0, maxInputBytes)
    }

    public static let `default` = StructuralCompareLimits()
}

/// Two structured documents compared by key path, not by line (design/mockups/unified/diff.html, "Two files:
/// structural JSON"): key order is ignored but reported per object, arrays are aligned by a diff of their elements
/// so one insertion reads as one addition, and values are compared by type (`1` and `1.0` are the same number, `1`
/// and `"1"` are a type change). roadmap: S-7
public struct StructuralComparison: Sendable, Equatable, Codable {
    public enum ChangeKind: String, Sendable, Equatable, Codable {
        case changed, added, removed, typeChanged
    }

    /// One entry of the "what changed" list, in document order.
    public struct Change: Sendable, Equatable, Codable {
        /// Display path without the `$`: `sync.interval`, `features[2]`, `["key with spaces"]`; `$` for the root.
        public var path: String
        public var kind: ChangeKind
        /// Compact JSON of the old and new value, cut at the limit's characters with "…".
        public var old: String?
        public var new: String?
    }

    public enum NodeKind: String, Sendable, Equatable, Codable { case object, array, value }

    public enum Mark: String, Sendable, Equatable, Codable {
        case same
        /// A value that differs, a type change, or a container with changes inside.
        case changed
        case added, removed
        /// An object whose only difference is the order of its keys.
        case reorderedOnly
    }

    /// One row of the detail tree, in document order (new order, removed keys where they stood in the old file).
    /// Added and removed containers are one row with their compact JSON; their children are not listed.
    public struct Node: Sendable, Equatable, Codable {
        /// 0 for the root's members.
        public var depth: Int
        /// Member name, array index ("2"), "$" for a scalar root, or "document 2" in a multi-document stream.
        public var key: String
        public var kind: NodeKind
        /// For containers: "{4} · 3 changes", "[3] · 1 added", "{2} · key order only, ignored"; nil for values.
        public var summary: String?
        public var mark: Mark
        /// Compact JSON: both for a changed value, `old` for removed, `new` for added, `new` for an unchanged value.
        public var old: String?
        public var new: String?
    }

    public struct Counts: Sendable, Equatable, Codable {
        /// Values that differ, type changes included.
        public var changed: Int
        public var added: Int
        public var removed: Int
        /// Of `changed`, the ones whose type differs.
        public var typeChanged: Int
        /// Objects whose key order differs (never a change on its own).
        public var reorderedObjects: Int
        /// Scalar values equal on both sides.
        public var unchangedValues: Int
    }

    /// "json", "yaml", "toml", "jsonLines", "propertyList".
    public var format: String
    public var changes: [Change]
    public var counts: Counts
    public var nodes: [Node]
    /// "3 changed · 3 added · 1 removed · 1 object reordered"; "No differences" when equal.
    public var summary: String
    /// The two documents are equal by value (key order may still differ: see `counts.reorderedObjects`).
    public var isEqual: Bool
    /// False when a limit cut the walk, the tree or a parse short; `incompleteReason` says which.
    public var isComplete: Bool
    public var incompleteReason: String?
}

/// Structural compare of JSON (and, through the same node model, YAML, TOML, JSON Lines and property lists).
/// XML is refused: its children are ordered and repeat names, so a key-path match would mislead. roadmap: S-7
public enum JSONCompare {
    /// Compares two documents. Throws `CompareError` naming the side when either is malformed.
    public static func compare(old: Data, new: Data, format: StructuredFormat = .json,
                               limits: StructuralCompareLimits = .default) throws -> StructuralComparison {
        guard format != .xml else {
            throw CompareError(.unsupported, side: nil,
                               reason: String(localized: "XML is not compared by structure (elements repeat names and keep order); compare it as text", bundle: .module, comment: "A compare could not start: reason."))
        }
        var options = StructuredOptions()
        options.maxNodes = limits.maxParsedNodes
        options.maxDepth = limits.maxDepth
        options.maxInputBytes = limits.maxInputBytes
        options.maxPreviewBytes = 64 * 1024
        let a = try parse(old, side: .old, format: format, options: options)
        let b = try parse(new, side: .new, format: format, options: options)
        var walker = StructuralWalker(old: a.tree, new: b.tree, oldData: old, newData: new, limits: limits)
        var reasons: [String] = []
        if let note = a.coverage.note { reasons.append(String(localized: "old file: \(note)", bundle: .module, comment: "Why a structural compare is incomplete: the old file's coverage note.")) }
        if let note = b.coverage.note { reasons.append(String(localized: "new file: \(note)", bundle: .module, comment: "Why a structural compare is incomplete: the new file's coverage note.")) }
        walker.run()
        reasons += walker.cutReasons
        let c = walker.counts
        var parts: [String] = []
        if c.changed > 0 { parts.append(String(localized: "\(c.changed) changed", bundle: .module, comment: "Structural compare summary part: how many values changed.")) }
        if c.added > 0 { parts.append(String(localized: "\(c.added) added", bundle: .module, comment: "Structural compare summary part: how many values were added.")) }
        if c.removed > 0 { parts.append(String(localized: "\(c.removed) removed", bundle: .module, comment: "Structural compare summary part: how many values were removed.")) }
        if c.reorderedObjects > 0 {
            parts.append(c.reorderedObjects == 1 ? String(localized: "1 object reordered", bundle: .module, comment: "Structural compare summary part: one object's keys were reordered.")
                : String(localized: "\(c.reorderedObjects) objects reordered", bundle: .module, comment: "Structural compare summary part: how many objects' keys were reordered (not 1)."))
        }
        let isEqual = c.changed + c.added + c.removed == 0
        return StructuralComparison(format: format.rawValue, changes: walker.changes, counts: c, nodes: walker.nodes,
                                    summary: parts.isEmpty ? String(localized: "No differences", bundle: .module, comment: "Compare summary: the two files have no differences.") : parts.joined(separator: " · "),
                                    isEqual: isEqual, isComplete: reasons.isEmpty,
                                    incompleteReason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
    }

    private static func parse(_ data: Data, side: CompareSide, format: StructuredFormat,
                              options: StructuredOptions) throws -> StructuredParseResult {
        let result = StructuredParser.parse(data, format: format, options: options)
        if let error = result.error {
            throw CompareError(.malformed, side: side, reason: String(localized: "not valid \(result.dialect.displayName): \(error.reason)", bundle: .module, comment: "A compare could not start: lower-case reason; the arguments are a format name such as JSON and the parser's message."),
                               line: error.location?.line, column: error.location?.column)
        }
        if result.tree.roots.isEmpty, format != .yaml, format != .jsonLines {
            throw CompareError(.malformed, side: side, reason: String(localized: "the file holds no \(format.rawValue) value", bundle: .module, comment: "A compare could not start: lower-case reason; the argument is a format identifier such as json."))
        }
        return result
    }
}

/// The recursive walk behind `JSONCompare`: one pass over both trees that emits the display tree, the change list
/// and the counts together. roadmap: S-7
struct StructuralWalker {
    let old: StructuredTree
    let new: StructuredTree
    let oldData: Data
    let newData: Data
    let limits: StructuralCompareLimits
    var nodes: [StructuralComparison.Node] = []
    var changes: [StructuralComparison.Change] = []
    var counts = StructuralComparison.Counts(changed: 0, added: 0, removed: 0, typeChanged: 0, reorderedObjects: 0,
                                             unchangedValues: 0)
    var cutReasons: [String] = []
    private var oldHash: [Int] = []
    private var newHash: [Int] = []
    private let deadline: Deadline
    private var steps = 0
    private var timedOut = false
    private var treeCut = false
    private var changesCut = false

    /// What a subtree contributed, for its parent's summary.
    struct Tally {
        var changed = 0, added = 0, removed = 0
        /// This object's own keys changed order (descendants' reorders are counted, not carried up).
        var selfReordered = false
        var total: Int { changed + added + removed }
        mutating func absorb(_ other: Tally) { changed += other.changed; added += other.added; removed += other.removed }
    }

    /// One path segment.
    enum Segment { case key(String), index(Int), document(Int) }

    init(old: StructuredTree, new: StructuredTree, oldData: Data, newData: Data, limits: StructuralCompareLimits) {
        self.old = old; self.new = new; self.oldData = oldData; self.newData = newData; self.limits = limits
        deadline = Deadline(limits.timeLimit)
    }

    mutating func run() {
        oldHash = Self.hashes(old, data: oldData)
        newHash = Self.hashes(new, data: newData)
        if old.roots.count == 1, new.roots.count == 1 {
            let o = old.roots[0], n = new.roots[0]
            if old[o].kind.isContainer, old[o].kind == new[n].kind {
                _ = compareContainer(o, n, path: [], depth: -1)
            } else {
                _ = compare(o, n, key: "$", path: [], depth: 0)
            }
        } else {
            // A YAML stream or JSON Lines: the documents are aligned like array elements.
            _ = compareSequence(old.roots, new.roots, path: [], depth: 0, documents: true)
        }
        if timedOut {
            cutReasons.append(String(localized: "the compare stopped at its time limit (\(limits.timeLimit.formatted()) s); later values are not compared", bundle: .module, comment: "Why a structural compare is incomplete; the argument is a number of seconds; lower-case, no final period."))
        }
        if treeCut { cutReasons.append(String(localized: "the tree shows its first \(limits.maxDisplayNodes.formatted()) rows", bundle: .module, comment: "Why a structural compare is incomplete; lower-case, no final period.")) }
        if changesCut { cutReasons.append(String(localized: "the list holds the first \(limits.maxChanges.formatted()) changes", bundle: .module, comment: "Why a structural compare is incomplete; lower-case, no final period.")) }
    }

    // MARK: Walk

    private mutating func tick() -> Bool {
        steps += 1
        if steps & 255 == 0, deadline.passed { timedOut = true }
        return !timedOut
    }

    /// Compares one matched pair and emits its row (and, for containers, its children's).
    private mutating func compare(_ o: Int, _ n: Int, key: String, path: [Segment], depth: Int) -> Tally {
        guard tick() else { return Tally() }
        let a = old[o], b = new[n]
        if a.kind != b.kind {
            let oldText = compact(old, o, oldData), newText = compact(new, n, newData)
            emit(depth: depth, key: key, kind: nodeKind(b.kind), summary: nil, mark: .changed, old: oldText, new: newText)
            record(path, .typeChanged, old: oldText, new: newText)
            counts.changed += 1; counts.typeChanged += 1
            return Tally(changed: 1)
        }
        if a.kind.isContainer {
            let row = emit(depth: depth, key: key, kind: nodeKind(b.kind), summary: "", mark: .same, old: nil, new: nil)
            let tally = compareContainer(o, n, path: path, depth: depth)
            if let row {
                nodes[row].summary = containerSummary(kind: b.kind, count: b.sourceChildCount, tally: tally)
                nodes[row].mark = tally.total > 0 ? .changed : tally.selfReordered ? .reorderedOnly : .same
            }
            return tally
        }
        if scalarEqual(o, n) {
            counts.unchangedValues += 1
            emit(depth: depth, key: key, kind: .value, summary: nil, mark: .same, old: nil, new: compact(new, n, newData))
            return Tally()
        }
        let oldText = compact(old, o, oldData), newText = compact(new, n, newData)
        emit(depth: depth, key: key, kind: .value, summary: nil, mark: .changed, old: oldText, new: newText)
        record(path, .changed, old: oldText, new: newText)
        counts.changed += 1
        return Tally(changed: 1)
    }

    /// The children of two containers of the same kind. `depth` is the containers' own row depth (-1 for the root).
    private mutating func compareContainer(_ o: Int, _ n: Int, path: [Segment], depth: Int) -> Tally {
        if old[o].kind == .array {
            return compareSequence(old.children(of: o), new.children(of: n), path: path, depth: depth + 1, documents: false)
        }
        // Objects: match by key (a repeated key is matched by its occurrence).
        let oldKids = keyed(old, old.children(of: o)), newKids = keyed(new, new.children(of: n))
        let oldIndex = Dictionary(oldKids.map { ($0.key, $0.node) }, uniquingKeysWith: { a, _ in a })
        let newIndex = Dictionary(newKids.map { ($0.key, $0.node) }, uniquingKeysWith: { a, _ in a })
        var tally = Tally()
        let commonOld = oldKids.filter { newIndex[$0.key] != nil }.map(\.key)
        let commonNew = newKids.filter { oldIndex[$0.key] != nil }.map(\.key)
        if commonOld != commonNew { tally.selfReordered = true; counts.reorderedObjects += 1 }

        // Removed keys stand after the nearest earlier old key that survives.
        var removedAfter: [String?: [(key: String, name: String, node: Int)]] = [:]
        var anchor: String?
        for kid in oldKids {
            if newIndex[kid.key] != nil { anchor = kid.key } else { removedAfter[anchor, default: []].append(kid) }
        }
        emitRemoved(removedAfter[nil], path: path, depth: depth, tally: &tally)
        for kid in newKids {
            guard !timedOut else { break }
            if let o2 = oldIndex[kid.key] {
                let sub = compare(o2, kid.node, key: kid.name, path: path + [.key(kid.name)], depth: depth + 1)
                tally.absorb(sub)
                emitRemoved(removedAfter[kid.key], path: path, depth: depth, tally: &tally)
            } else {
                guard tick() else { break }
                added(kid.node, key: kid.name, path: path + [.key(kid.name)], depth: depth + 1)
                tally.added += 1
            }
        }
        return tally
    }

    private mutating func emitRemoved(_ list: [(key: String, name: String, node: Int)]?, path: [Segment], depth: Int,
                                      tally: inout Tally) {
        for kid in list ?? [] {
            guard tick() else { return }
            removed(kid.node, key: kid.name, path: path + [.key(kid.name)], depth: depth + 1)
            tally.removed += 1
        }
    }

    /// Array elements (or stream documents): aligned by a diff of their value hashes, so an insertion is one
    /// addition; elements left unmatched in a changed region are paired by position and compared inside.
    private mutating func compareSequence(_ a: [Int], _ b: [Int], path: [Segment], depth: Int, documents: Bool) -> Tally {
        let steps = Alignment.align(a.map { oldHash[$0] }, b.map { newHash[$0] }, threshold: 0, maxRegion: 0) { _, _ in 1 }
        var tally = Tally()
        func segment(_ i: Int) -> Segment { documents ? .document(i + 1) : .index(i) }
        func label(_ i: Int) -> String { documents ? String(localized: "document \(i + 1)", bundle: .module, comment: "Name of a YAML document or JSON Lines record in a structural compare; the argument is its 1-based number.") : "\(i)" }
        for step in steps {
            guard !timedOut else { break }
            switch step {
            case .equal(let i, let j), .paired(let i, let j):
                let sub = compare(a[i], b[j], key: label(j), path: path + [segment(j)], depth: depth)
                tally.absorb(sub)
            case .deleted(let i):
                guard tick() else { break }
                removed(a[i], key: label(i), path: path + [segment(i)], depth: depth)
                tally.removed += 1
            case .inserted(let j):
                guard tick() else { break }
                added(b[j], key: label(j), path: path + [segment(j)], depth: depth)
                tally.added += 1
            }
        }
        return tally
    }

    private mutating func added(_ n: Int, key: String, path: [Segment], depth: Int) {
        let text = compact(new, n, newData)
        let node = new[n]
        emit(depth: depth, key: key, kind: nodeKind(node.kind),
             summary: node.kind.isContainer ? containerSummary(kind: node.kind, count: node.sourceChildCount, tally: Tally()) : nil,
             mark: .added, old: nil, new: text)
        record(path, .added, old: nil, new: text)
        counts.added += 1
    }

    private mutating func removed(_ o: Int, key: String, path: [Segment], depth: Int) {
        let text = compact(old, o, oldData)
        let node = old[o]
        emit(depth: depth, key: key, kind: nodeKind(node.kind),
             summary: node.kind.isContainer ? containerSummary(kind: node.kind, count: node.sourceChildCount, tally: Tally()) : nil,
             mark: .removed, old: text, new: nil)
        record(path, .removed, old: text, new: nil)
        counts.removed += 1
    }

    // MARK: Output

    @discardableResult
    private mutating func emit(depth: Int, key: String, kind: StructuralComparison.NodeKind, summary: String?,
                               mark: StructuralComparison.Mark, old: String?, new: String?) -> Int? {
        guard nodes.count < limits.maxDisplayNodes else { treeCut = true; return nil }
        nodes.append(.init(depth: max(0, depth), key: key, kind: kind, summary: summary, mark: mark, old: old, new: new))
        return nodes.count - 1
    }

    private mutating func record(_ path: [Segment], _ kind: StructuralComparison.ChangeKind, old: String?, new: String?) {
        guard changes.count < limits.maxChanges else { changesCut = true; return }
        changes.append(.init(path: Self.display(path), kind: kind, old: old, new: new))
    }

    private func containerSummary(kind: StructuredNodeKind, count: Int, tally: Tally) -> String {
        var out = kind == .object ? "{\(count)}" : "[\(count)]"
        if tally.total > 0 {
            let kinds = [tally.changed, tally.added, tally.removed].filter { $0 > 0 }.count
            if kinds == 1 {
                if tally.changed > 0 { out += " · " + String(localized: "\(tally.changed) changed", bundle: .module, comment: "Structural compare: how many values inside a container changed.") }
                if tally.added > 0 { out += " · " + String(localized: "\(tally.added) added", bundle: .module, comment: "Structural compare: how many values inside a container were added.") }
                if tally.removed > 0 { out += " · " + String(localized: "\(tally.removed) removed", bundle: .module, comment: "Structural compare: how many values inside a container were removed.") }
            } else {
                out += " · " + (tally.total == 1 ? String(localized: "1 change", bundle: .module, comment: "Structural compare: changes inside a container.")
                    : String(localized: "\(tally.total) changes", bundle: .module, comment: "Structural compare: how many changes inside a container (not 1)."))
            }
            if tally.selfReordered { out += " · " + String(localized: "key order changed, ignored", bundle: .module, comment: "Structural compare: an object's keys were reordered, which does not count as a change.") }
        } else if tally.selfReordered {
            out += " · " + String(localized: "key order only, ignored", bundle: .module, comment: "Structural compare: only an object's key order changed, which does not count as a change.")
        }
        return out
    }

    private func nodeKind(_ kind: StructuredNodeKind) -> StructuralComparison.NodeKind {
        switch kind {
        case .object: .object
        case .array: .array
        default: .value
        }
    }

    /// `sync.interval`, `features[2]`, `["two words"].x`, `document 2: spec`; `$` for the root.
    static func display(_ path: [Segment]) -> String {
        var prefix = "", out = ""
        for segment in path {
            switch segment {
            case .document(let n): prefix = String(localized: "document \(n)", bundle: .module, comment: "Name of a YAML document or JSON Lines record in a structural compare; the argument is its 1-based number.")
            case .index(let i): out += "[\(i)]"
            case .key(let name):
                if isIdentifier(name) { out += (out.isEmpty ? "" : ".") + name } else { out += "[\(CompareText.quoted(name))]" }
            }
        }
        if prefix.isEmpty { return out.isEmpty ? "$" : out }
        return out.isEmpty ? prefix : "\(prefix): \(out)"
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return false }
        func nameFirst(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 0x80 }
        guard nameFirst(first) else { return false }
        return name.utf8.allSatisfy { nameFirst($0) || ($0 >= 48 && $0 <= 57) }
    }

    /// Children of an object with a match key: the name, or "name#2" for its second occurrence.
    private func keyed(_ tree: StructuredTree, _ kids: [Int]) -> [(key: String, name: String, node: Int)] {
        var seen: [String: Int] = [:]
        return kids.map { node in
            let name = tree[node].name ?? ""
            let n = (seen[name] ?? 0) + 1
            seen[name] = n
            return (n == 1 ? name : "\(name)#\(n)", name, node)
        }
    }

    // MARK: Values

    /// Equality of two scalars of the same kind: numbers by value, everything else by its decoded text (and, when a
    /// preview was cut, by the source bytes of the whole value).
    private func scalarEqual(_ o: Int, _ n: Int) -> Bool {
        let a = old[o], b = new[n]
        if a.kind == .number { return Self.numberKey(a.preview) == Self.numberKey(b.preview) }
        guard a.preview == b.preview else { return false }
        if a.isPreviewTruncated || b.isPreviewTruncated {
            return Self.sourceBytes(old, o, oldData) == Self.sourceBytes(new, n, newData)
        }
        return true
    }

    static func numberKey(_ text: String) -> String {
        if let d = Decimal(string: text), d.isFinite { return d.description }
        return text
    }

    static func sourceBytes(_ tree: StructuredTree, _ index: Int, _ data: Data) -> Data? {
        let span = tree[index].span
        guard let offset = span.byteOffset, let length = span.byteLength, offset >= 0, length >= 0,
              offset + length <= Int64(data.count) else { return nil }
        let start = data.startIndex + Int(offset)
        return data[start..<(start + Int(length))]
    }

    /// A value hash for every node, children first (the array is pre-order, so a reverse pass sees children before
    /// parents). Objects hash their members order-free, so a reordered object still aligns with its old self.
    static func hashes(_ tree: StructuredTree, data: Data) -> [Int] {
        var out = [Int](repeating: 0, count: tree.count)
        for index in stride(from: tree.count - 1, through: 0, by: -1) {
            let node = tree[index]
            var hasher = Hasher()
            hasher.combine(node.kind)
            switch node.kind {
            case .object:
                var members = 0
                for kid in tree.children(of: index) {
                    var h = Hasher()
                    h.combine(tree[kid].name)
                    h.combine(out[kid])
                    members = members &+ h.finalize()
                }
                hasher.combine(members)
            case .array:
                for kid in tree.children(of: index) { hasher.combine(out[kid]) }
            case .number:
                hasher.combine(numberKey(node.preview))
            default:
                hasher.combine(node.preview)
                if node.isPreviewTruncated { hasher.combine(sourceBytes(tree, index, data)) }
            }
            hasher.combine(node.childrenOmitted)
            out[index] = hasher.finalize()
        }
        return out
    }

    /// Compact JSON of a subtree, stopped as soon as it passes the character limit.
    private func compact(_ tree: StructuredTree, _ index: Int, _ data: Data) -> String {
        let limit = limits.maxValueCharacters
        var out = ""
        var budget = limit + 1
        func write(_ s: String) {
            guard budget > 0 else { return }
            out += s
            budget -= s.count
        }
        func value(_ i: Int) {
            guard budget > 0 else { return }
            let node = tree[i]
            switch node.kind {
            case .object:
                write("{")
                for (k, kid) in tree.children(of: i).enumerated() {
                    guard budget > 0 else { return }
                    if k > 0 { write(",") }
                    write(CompareText.quoted(tree[kid].name ?? "") + ":")
                    value(kid)
                }
                write(node.childrenOmitted ? ",…}" : "}")
            case .array:
                write("[")
                for (k, kid) in tree.children(of: i).enumerated() {
                    guard budget > 0 else { return }
                    if k > 0 { write(",") }
                    value(kid)
                }
                write(node.childrenOmitted ? ",…]" : "]")
            case .string, .date:
                write(CompareText.quoted(node.preview + (node.isPreviewTruncated ? "…" : "")))
            case .data:
                write("<\(node.preview)>")
            case .number, .bool, .null:
                write(node.preview.isEmpty && node.kind == .null ? "null" : node.preview)
            }
        }
        value(index)
        return CompareText.truncate(out, limit)
    }
}
