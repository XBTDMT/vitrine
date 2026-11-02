import Foundation

extension JQValue {
    /// The value of `node` in a parsed structured document (JSON, JSON Lines, YAML, TOML or a property list), so a jq
    /// program runs over the same tree the preview draws. Run it once per root for multi-document files
    /// (`tree.roots`: one per JSON Lines line or YAML document). Built bottom-up without recursion.
    ///
    /// The tree keeps value previews cut to `StructuredOptions.maxPreviewBytes` and stops at its node and depth
    /// limits; `JQValue.isLossless(tree:node:)` says whether this conversion saw everything. For a JSON file, parse
    /// the bytes with `init(json:)` instead to get whole strings regardless.
    ///
    /// Mapping: objects keep their key order (a repeated key keeps its first position and its last value); numbers
    /// are read from their text (YAML/TOML forms included: `0x1F`, `0o17`, `0b101`, `1_000`, `.inf`, `nan`); booleans
    /// from their text; dates and data become their display text, as strings.
    public init(tree: StructuredTree, node: Int) {
        let root = tree[node]
        let end = root.subtreeEnd > node ? root.subtreeEnd : node + 1
        var built = [JQValue?](repeating: nil, count: end - node)
        var depths = [Int](repeating: 0, count: end - node)
        for index in stride(from: end - 1, through: node, by: -1) {
            let n = tree[index]
            let slot = index - node
            switch n.kind {
            case .object:
                var object = JQObject()
                for child in tree.children(of: index) {
                    let c = child - node
                    object.set(tree[child].name ?? "", built[c] ?? .null, valueDepth: depths[c])
                    built[c] = nil
                }
                depths[slot] = object.depth
                built[slot] = .object(object)
            case .array:
                var items: [JQValue] = []
                var deepest = 0
                for child in tree.children(of: index) {
                    let c = child - node
                    items.append(built[c] ?? .null)
                    deepest = max(deepest, depths[c])
                    built[c] = nil
                }
                depths[slot] = 1 + deepest
                built[slot] = .array(items)
            case .string, .date, .data:
                built[slot] = .string(n.preview)
            case .number:
                built[slot] = Self.number(fromText: n.preview).map(JQValue.number) ?? .string(n.preview)
            case .bool:
                let text = n.preview.lowercased()
                built[slot] = .bool(text == "true" || text == "yes" || text == "on")
            case .null:
                built[slot] = .null
            }
        }
        self = built[0] ?? .null
    }

    /// Whether `init(tree:node:)` sees the whole value: no preview in the subtree was cut and no children were left
    /// out by a limit.
    public static func isLossless(tree: StructuredTree, node: Int) -> Bool {
        let end = max(tree[node].subtreeEnd, node + 1)
        for index in node..<end {
            let n = tree[index]
            if n.isPreviewTruncated || n.childrenOmitted { return false }
        }
        return true
    }

    /// A number written in JSON, YAML, TOML or property-list style; nil when the text is not one.
    static func number(fromText raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let d = Double(text) { return d }
        var negative = false
        if text.hasPrefix("+") { text.removeFirst() } else if text.hasPrefix("-") { negative = true; text.removeFirst() }
        let lower = text.lowercased()
        let sign: Double = negative ? -1 : 1
        if lower == ".inf" || lower == "inf" || lower == "infinity" { return sign * .infinity }
        if lower == ".nan" || lower == "nan" { return .nan }
        let plain = lower.replacingOccurrences(of: "_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where plain.hasPrefix(prefix) {
            guard let v = UInt64(plain.dropFirst(2), radix: radix) else { return nil }
            return sign * Double(v)
        }
        if let d = Double(plain) { return sign * d }
        return nil
    }
}
