import Foundation
import VitrineData

/// A read-only view of one node of a VitrineData `StructuredTree`, with the lookups the infrastructure readers need:
/// a key, the items of a list, the entries of a mapping (YAML `<<` merge keys applied), and scalars as text, number
/// or flag. It walks the flat tree, so it never recurses over the document.
struct InfraNode {
    let tree: StructuredTree
    let index: Int

    var raw: StructuredNode { tree[index] }
    var isObject: Bool { raw.kind == .object }
    var isArray: Bool { raw.kind == .array }
    var isScalar: Bool { !raw.kind.isContainer }
    var isNull: Bool { raw.kind == .null }

    /// A scalar's text (strings decoded, numbers and flags as written); nil for containers, nulls and unreadable
    /// lines.
    var string: String? {
        guard isScalar, raw.kind != .null, raw.role != .invalid, raw.role != .alias else { return nil }
        return raw.preview
    }

    /// A non-empty scalar text.
    var text: String? { string.flatMap { $0.isEmpty ? nil : $0 } }

    var bool: Bool? {
        guard let s = string?.lowercased() else { return nil }
        if s == "true" { return true }
        if s == "false" { return false }
        return nil
    }

    var isTrue: Bool { bool == true }
    var int: Int? { string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    var double: Double? { string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }

    /// The node's own children in order (for a mapping, its entries without merges).
    var children: [InfraNode] { tree.children(of: index).map { InfraNode(tree: tree, index: $0) } }
    var items: [InfraNode] { isArray ? children : [] }
    var count: Int { raw.childCount }
    var name: String? { raw.name }

    /// A mapping's entries in order, with `<<` merge keys (a mapping or a list of them, possibly merging further)
    /// expanded: own keys win, then earlier merges.
    var entries: [(key: String, value: InfraNode)] {
        guard isObject else { return [] }
        var out: [(key: String, value: InfraNode)] = []
        var seen: Set<String> = []
        var merges: [(InfraNode, Int)] = []
        for child in children {
            let key = child.name ?? ""
            if key == "<<" { merges.append((child, 0)); continue }
            if seen.insert(key).inserted { out.append((key, child)) }
        }
        var k = 0
        while k < merges.count, k < 64 {
            let (source, depth) = merges[k]
            k += 1
            let sources = source.isArray ? source.items : [source]
            for s in sources where s.isObject {
                for child in s.children {
                    let key = child.name ?? ""
                    if key == "<<" { if depth < 4 { merges.append((child, depth + 1)) }; continue }
                    if seen.insert(key).inserted { out.append((key, child)) }
                }
            }
        }
        return out
    }

    subscript(key: String) -> InfraNode? {
        guard isObject else { return nil }
        var hasMerge = false
        for child in children {
            if child.name == key { return child }
            if child.name == "<<" { hasMerge = true }
        }
        guard hasMerge else { return nil }
        return entries.first { $0.key == key }?.value
    }

    /// A value that may be one string or a list of strings (`needs: build`, `needs: [build, test]`).
    var stringList: [String] {
        if let s = text { return [s] }
        return items.compactMap(\.text)
    }

    /// Keys of a mapping, or the strings of a list: the two ways Compose writes `networks`, `depends_on`, `secrets`.
    var keysOrStrings: [String] {
        if isObject { return entries.map(\.key) }
        return items.compactMap { $0.text ?? $0["source"]?.text }
    }
}

/// Parsing for the readers: the bytes through VitrineData's parsers with the infrastructure limits.
enum InfraParse {
    struct Result {
        var roots: [InfraNode]
        /// The whole input was read into the tree with no limit hit and no syntax error.
        var complete: Bool
        var valid: Bool
    }

    static func structured(_ data: Data, format: StructuredFormat, fileSize: Int) -> Result {
        var options = StructuredOptions()
        options.maxInputBytes = Int64(InfraReader.maxBytes)
        options.maxDepth = InfraReader.maxDepth
        options.maxPreviewBytes = 16 * 1024
        options.maxKeyBytes = 1024
        options.maxDiagnostics = 16
        if format == .json { options.jsonSyntax = .lenient }
        let result = StructuredParser.parse(data, format: format, options: options, fileSize: Int64(fileSize))
        let roots = result.tree.roots.map { InfraNode(tree: result.tree, index: $0) }
        return Result(roots: roots, complete: result.coverage.isComplete, valid: result.isValid)
    }
}

/// Small text helpers shared by the readers.
enum InfraText {
    /// Names that usually hold a secret: password, secret, token, private key, access key, API key, credentials,
    /// connection string. Compared with case, `-`, `_`, `.` and spaces removed, so `client_secret`, `ClientSecret`
    /// and `client-secret` all match. Names that only describe a secret (`secret_arn`, `token_type`,
    /// `password_length`) do not.
    static func looksSecret(_ name: String) -> Bool {
        let n = String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        guard !n.isEmpty, n.count <= 128 else { return false }
        let markers = ["password", "passwd", "passphrase", "secret", "token", "privatekey", "accesskey", "apikey",
                       "credential", "connectionstring", "sastoken", "signingkey", "encryptionkey", "masterkey", "authkey"]
        guard markers.contains(where: { n.contains($0) }) else { return false }
        let describing = ["arn", "id", "ids", "name", "names", "type", "ttl", "length", "version", "versions", "count",
                          "enabled", "expiry", "expiration", "expires", "expiresat", "rotation", "policy", "uri", "url",
                          "path", "ref", "endpoint", "file", "location", "hash", "sha", "required", "format", "header"]
        return !describing.contains { suffix in n.hasSuffix(suffix) && !markers.contains { n.hasSuffix($0) } }
    }

    /// `s` cut to `limit` characters, with "…" when cut.
    static func cut(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(max(0, limit - 1))) + "…"
    }

    static func decode(_ data: Data) -> String {
        var s = String(decoding: data, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }
}
