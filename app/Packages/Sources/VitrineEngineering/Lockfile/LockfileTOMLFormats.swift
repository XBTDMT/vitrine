import Foundation

/// The TOML lockfiles (A-12): Cargo.lock, poetry.lock and uv.lock, all built of `[[package]]` tables.
/// roadmap: S-22
enum TOMLLockfiles {
    /// One `[[package]]` table and the `[package.*]` sub-tables that follow it.
    struct PackageTable {
        var values: [String: LockTOML]
        var subtables: [String: [String: LockTOML]] = [:]
        subscript(key: String) -> LockTOML? { values[key] }
    }

    static func packageTables(_ sections: [LockTOMLSection]) -> [PackageTable] {
        var out: [PackageTable] = []
        for s in sections {
            if s.header == "package", s.isArray {
                out.append(PackageTable(values: s.values))
            } else if s.header.hasPrefix("package."), !out.isEmpty {
                out[out.count - 1].subtables[String(s.header.dropFirst("package.".count)), default: [:]].merge(s.values) { $1 }
            }
        }
        return out
    }

    // MARK: Cargo

    private static func cargoRegistryHost(_ url: String) -> String? {
        if url.contains("github.com/rust-lang/crates.io-index") { return "crates.io" }
        let host = LockfileText.host(url)
        return host == "index.crates.io" ? "crates.io" : host
    }

    static func cargo(_ bytes: [UInt8]) -> LockfileSummary? {
        let (sections, _) = LockTOMLReader.parse(bytes)
        let tables = packageTables(sections)
        guard !tables.isEmpty || sections.first?.values["version"] != nil else { return nil }
        var b = LockfileBuilder(.cargo)
        b.formatVersion = sections.first?.values["version"]?.text
        // Version 1 files keep checksums in [metadata] as `"checksum name version (source)" = "…"`.
        var oldChecksums: Set<String> = []
        for s in sections where s.header == "metadata" {
            for key in s.values.keys where key.hasPrefix("checksum ") {
                let parts = key.dropFirst("checksum ".count).split(separator: " ")
                if parts.count >= 2 { oldChecksums.insert("\(parts[0]) \(parts[1])") }
            }
        }
        // Workspace crates have no source; what they depend on is direct.
        var directNames: Set<String> = []
        var directPairs: Set<String> = []
        var memberNames: Set<String> = []
        for t in tables where t["source"] == nil {
            guard let name = t["name"]?.string else { continue }
            memberNames.insert(name)
            for dep in t["dependencies"]?.array ?? [] {
                let parts = (dep.string ?? "").split(separator: " ")
                guard let first = parts.first else { continue }
                if parts.count >= 2 { directPairs.insert("\(first) \(parts[1])") } else { directNames.insert(String(first)) }
            }
        }
        b.directKnown = !memberNames.isEmpty
        for t in tables {
            guard let name = t["name"]?.string else { continue }
            let version = t["version"]?.string
            let source = t["source"]?.string
            let origin: LockfileOrigin
            if let source {
                if source.hasPrefix("git+") {
                    origin = .git(LockfileText.host(String(source.dropFirst(4))), commit: LockfileText.gitHasCommit(source))
                } else if let plus = source.firstIndex(of: "+"), ["registry", "sparse"].contains(String(source[..<plus])) {
                    origin = .registry(cargoRegistryHost(String(source[source.index(after: plus)...])))
                } else {
                    origin = .url(LockfileText.host(source))
                }
            } else {
                origin = .path(nil)
            }
            let integrity = t["checksum"]?.string?.isEmpty == false || oldChecksums.contains("\(name) \(version ?? "")")
            let isDirect: Bool? = b.directKnown
                ? source != nil && (directNames.contains(name) || directPairs.contains("\(name) \(version ?? "")"))
                : nil
            b.add(name: name, version: version, origin: origin, integrity: integrity, isDirect: isDirect)
        }
        return b.summary()
    }

    // MARK: poetry

    static func poetry(_ bytes: [UInt8]) -> LockfileSummary? {
        let (sections, _) = LockTOMLReader.parse(bytes)
        let tables = packageTables(sections)
        let metadata = sections.first { $0.header == "metadata" }
        guard !tables.isEmpty || metadata != nil else { return nil }
        var b = LockfileBuilder(.poetry)
        b.formatVersion = metadata?.values["lock-version"]?.text
        // Older files list hashes under [metadata.files] by package name.
        var hashedNames: Set<String> = []
        for s in sections where s.header == "metadata.files" {
            for (name, files) in s.values where !(files.array ?? []).isEmpty { hashedNames.insert(name.lowercased()) }
        }
        for t in tables {
            guard let name = t["name"]?.string else { continue }
            let source = t.subtables["source"] ?? t["source"]?.table
            let origin: LockfileOrigin
            switch source?["type"]?.string {
            case nil: origin = .defaultRegistry
            case "git":
                let ref = source?["resolved_reference"]?.string ?? source?["reference"]?.string ?? ""
                origin = .git(source?["url"]?.string.flatMap(LockfileText.host), commit: LockfileText.isCommit(ref))
            case "legacy": origin = .registry(source?["url"]?.string.flatMap(LockfileText.host))
            case "url": origin = .url(source?["url"]?.string.flatMap(LockfileText.host))
            case "file", "directory": origin = .path(source?["url"]?.string)
            default: origin = .unknown
            }
            let files = t["files"]?.array ?? []
            let integrity = files.contains { $0.table?["hash"]?.string?.isEmpty == false } || hashedNames.contains(name.lowercased())
            b.add(name: name, version: t["version"]?.string, origin: origin, integrity: integrity, isDirect: nil)
        }
        return b.summary()
    }

    // MARK: uv

    static func uv(_ bytes: [UInt8]) -> LockfileSummary? {
        let (sections, _) = LockTOMLReader.parse(bytes)
        let tables = packageTables(sections)
        guard !tables.isEmpty || sections.first?.values["version"] != nil else { return nil }
        var b = LockfileBuilder(.uv)
        b.formatVersion = sections.first?.values["version"]?.text

        func isLocal(_ t: PackageTable) -> Bool {
            guard let s = t["source"]?.table else { return false }
            return s["editable"] != nil || s["virtual"] != nil
        }
        func isRoot(_ t: PackageTable) -> Bool {
            guard let s = t["source"]?.table else { return false }
            return s["editable"]?.string == "." || s["virtual"]?.string == "."
        }
        // The project and its workspace members are editable or virtual; what they depend on is direct.
        var direct: Set<String> = []
        var members: Set<String> = []
        for t in tables where isLocal(t) {
            if let n = t["name"]?.string { members.insert(n.lowercased()) }
            var lists: [LockTOML] = [t["dependencies"] ?? .array([])]
            for sub in ["optional-dependencies", "dev-dependencies"] {
                lists.append(contentsOf: (t.subtables[sub] ?? [:]).values)
                lists.append(contentsOf: (t[sub]?.table ?? [:]).values)
            }
            for list in lists {
                for dep in list.array ?? [] { if let n = dep.table?["name"]?.string { direct.insert(n.lowercased()) } }
            }
        }
        b.directKnown = !members.isEmpty
        for t in tables {
            guard let name = t["name"]?.string, !isRoot(t) else { continue }
            let source = t["source"]?.table ?? [:]
            let origin: LockfileOrigin
            if let registry = source["registry"]?.string {
                origin = .registry(LockfileText.host(registry))
            } else if let git = source["git"]?.string {
                origin = .git(LockfileText.host(git), commit: LockfileText.gitHasCommit(git))
            } else if let url = source["url"]?.string {
                origin = .url(LockfileText.host(url))
            } else if let path = (source["path"] ?? source["directory"] ?? source["editable"] ?? source["virtual"])?.string {
                origin = .path(path)
            } else {
                origin = .unknown
            }
            let sdistHash = t["sdist"]?.table?["hash"]?.string?.isEmpty == false
            let wheelHash = (t["wheels"]?.array ?? []).contains { $0.table?["hash"]?.string?.isEmpty == false }
            let isDirect: Bool? = b.directKnown ? !members.contains(name.lowercased()) && direct.contains(name.lowercased()) : nil
            b.add(name: name, version: t["version"]?.string, origin: origin, integrity: sdistHash || wheelHash, isDirect: isDirect)
        }
        return b.summary()
    }
}
