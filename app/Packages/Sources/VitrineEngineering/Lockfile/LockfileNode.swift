import Foundation

/// The JavaScript lockfiles (A-12): package-lock.json and npm-shrinkwrap.json (lockfileVersion 1, 2, 3), yarn.lock
/// (classic v1 and berry), pnpm-lock.yaml (5.x, 6.x, 9.x) and bun.lock (the text JSONC form). roadmap: S-22
enum NodeLockfiles {
    static let dependencyFields = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]

    /// Where an npm-style package comes from, from its resolved location or, without one, from its spec:
    /// registry tarballs (`…/-/…tgz`), git locations, codeload tarballs (git at a commit), `file:`/`link:` paths,
    /// other download URLs.
    static func origin(resolved: String?, spec: String?, link: Bool = false) -> LockfileOrigin {
        if link { return .path(resolved) }
        var location = resolved
        if location == nil || location?.isEmpty == true, let spec, !LockfileText.looksExact(spec) { location = spec }
        guard let r = location, !r.isEmpty else { return .unknown }
        for prefix in ["file:", "link:", "workspace:", "portal:"] where r.hasPrefix(prefix) {
            return .path(String(r.dropFirst(prefix.count)))
        }
        if LockfileText.looksGit(r) {
            return .git(LockfileText.host(r.hasPrefix("git+") ? String(r.dropFirst(4)) : r), commit: LockfileText.gitHasCommit(r))
        }
        if r.hasPrefix("https://") || r.hasPrefix("http://") {
            let host = LockfileText.host(r)
            if host == "codeload.github.com" {
                let last = LockfileText.lastComponent(Substring(r.split(separator: "#").first ?? ""))
                return .git("github.com", commit: LockfileText.isCommit(last))
            }
            return r.contains("/-/") ? .registry(host) : .url(host)
        }
        if r.hasPrefix(".") || r.hasPrefix("/") { return .path(r) }
        return .unknown
    }

    // MARK: npm

    static func npm(_ bytes: [UInt8]) -> LockfileSummary? {
        let (parsed, complete) = LockJSONReader.parse(bytes)
        guard let root = parsed, root.members != nil else { return nil }
        let version = root["lockfileVersion"]?.text
        guard version != nil || root["packages"] != nil || root["dependencies"] != nil else { return nil }
        var b = LockfileBuilder(.npm)
        b.formatVersion = version
        b.truncated = !complete

        if let packages = root["packages"]?.members {
            b.carriesLicences = true
            var direct: Set<String> = []
            var hasRoot = false
            var folders: Set<String> = []
            for (key, entry) in packages where !key.contains("node_modules/") {
                if key.isEmpty { hasRoot = true } else { folders.insert(key) }
                for field in dependencyFields { for dep in entry[field]?.members ?? [] { direct.insert(dep.key) } }
            }
            b.directKnown = hasRoot
            for (key, entry) in packages where !key.isEmpty {
                let isLink = entry["link"]?.isTrue == true
                let resolved = entry["resolved"]?.string
                if isLink, let target = resolved, folders.contains(target) { continue }   // counted at its folder
                let nm = key.range(of: "node_modules/", options: .backwards)
                let keyName = nm.map { String(key[$0.upperBound...]) } ?? String(LockfileText.lastComponent(Substring(key)))
                let name = entry["name"]?.string ?? keyName
                let topLevel = key.hasPrefix("node_modules/") && !key.dropFirst(13).contains("node_modules/")
                let v = entry["version"]?.string
                let origin = nm == nil ? LockfileOrigin.path(key) : origin(resolved: resolved, spec: v, link: isLink)
                let licence = entry["license"]?.string ?? entry["license"]?["type"]?.string
                b.add(name: name, version: v, origin: origin, integrity: !(entry["integrity"]?.string ?? "").isEmpty,
                      isDirect: hasRoot ? (topLevel && direct.contains(keyName)) || (nm == nil && direct.contains(name)) : nil,
                      licence: licence)
            }
        } else if let deps = root["dependencies"]?.members {
            // lockfileVersion 1: nested "dependencies", walked with an explicit stack and a depth bound.
            var stack: [(members: [(key: String, value: LockJSON)], depth: Int)] = [(deps, 0)]
            while let (members, depth) = stack.popLast() {
                for (name, entry) in members {
                    let v = entry["version"]?.string
                    b.add(name: name, version: v, origin: origin(resolved: entry["resolved"]?.string, spec: v),
                          integrity: !(entry["integrity"]?.string ?? "").isEmpty, isDirect: nil)
                    if let nested = entry["dependencies"]?.members, !nested.isEmpty {
                        if depth + 1 < LockJSONReader.maxDepth { stack.append((nested, depth + 1)) } else { b.truncated = true }
                    }
                }
            }
        }
        return b.summary()
    }

    // MARK: yarn

    static func yarn(_ text: String) -> LockfileSummary? {
        let lines = LockLine.lines(text)
        var blocks: [(header: Substring, body: ArraySlice<LockLine>)] = []
        var k = 0
        while k < lines.count {
            let head = lines[k]
            k += 1
            guard head.indent == 0, head.text.hasSuffix(":") else { continue }
            let start = k
            while k < lines.count, lines[k].indent > 0 { k += 1 }
            blocks.append((head.text.dropLast(), lines[start..<k]))
        }
        let berry = blocks.contains { $0.header == "__metadata" }
        guard berry || text.contains("# yarn lockfile v1") || blocks.contains(where: { fields($0.body)["version"] != nil }) else { return nil }
        return berry ? yarnBerry(blocks) : yarnClassic(blocks, marked: text.contains("# yarn lockfile v1"))
    }

    /// The top-level fields of one block (`version "1.0.0"` in classic, `version: 1.0.0` in berry), unquoted.
    private static func fields(_ body: ArraySlice<LockLine>) -> [String: String] {
        guard let indent = body.first?.indent else { return [:] }
        var out: [String: String] = [:]
        for line in body where line.indent == indent {
            if let kv = LockYAML.keyValue(line.text), !kv.key.contains(" ") {
                out[kv.key] = kv.value.map(LockYAML.unquote) ?? ""
            } else if let space = line.text.firstIndex(of: " ") {
                out[String(line.text[..<space])] = LockYAML.unquote(line.text[line.text.index(after: space)...])
            }
        }
        return out
    }

    private static func descriptors(_ header: Substring) -> [String] {
        header.components(separatedBy: ", ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" '")) }.filter { !$0.isEmpty }
    }

    private static func yarnClassic(_ blocks: [(header: Substring, body: ArraySlice<LockLine>)], marked: Bool) -> LockfileSummary {
        var b = LockfileBuilder(.yarn)
        b.formatVersion = marked ? "1" : nil
        for block in blocks {
            guard let first = descriptors(block.header).first else { continue }
            let (name, spec) = LockfileText.splitNameAt(Substring(first))
            let f = fields(block.body)
            let resolved = f["resolved"]
            var origin = origin(resolved: resolved, spec: nil)
            if resolved == nil, let spec, ["file:", "link:"].contains(where: spec.hasPrefix) { origin = .path(spec) }
            var integrity = !(f["integrity"] ?? "").isEmpty
            if !integrity, origin.kind == .registry, let r = resolved, let hash = r.lastIndex(of: "#") {
                integrity = r[r.index(after: hash)...].count >= 40 && LockfileText.isCommit(r[r.index(after: hash)...])
            }
            b.add(name: name, version: f["version"], origin: origin, integrity: integrity, isDirect: nil)
        }
        return b.summary()
    }

    private static func berryOrigin(_ spec: String) -> LockfileOrigin {
        if spec.hasPrefix("npm:") { return .defaultRegistry }
        for prefix in ["workspace:", "portal:", "link:", "file:"] where spec.hasPrefix(prefix) {
            return .path(String(spec.dropFirst(prefix.count)))
        }
        if spec.hasPrefix("patch:") {
            return spec.contains("npm%3A") || spec.contains("npm:") ? .defaultRegistry : .unknown
        }
        if LockfileText.looksGit(spec) || spec.contains("#commit=") {
            let location = spec.hasPrefix("git+") ? String(spec.dropFirst(4)) : spec
            return .git(LockfileText.host(location), commit: LockfileText.gitHasCommit(spec))
        }
        if spec.hasPrefix("https://") || spec.hasPrefix("http://") { return origin(resolved: spec, spec: nil) }
        return .unknown
    }

    private static func yarnBerry(_ blocks: [(header: Substring, body: ArraySlice<LockLine>)]) -> LockfileSummary {
        var b = LockfileBuilder(.yarn)
        var directDescriptors: Set<String> = []
        var workspaceNames: Set<String> = []
        struct Entry { var name: String; var spec: String; var version: String?; var checksum: Bool; var descriptors: [String] }
        var entries: [Entry] = []
        for block in blocks {
            let f = fields(block.body)
            if block.header == "__metadata" { b.formatVersion = f["version"]; continue }
            let descs = descriptors(block.header)
            let resolution = f["resolution"] ?? descs.first ?? ""
            let (name, spec) = LockfileText.splitNameAt(Substring(resolution))
            let s = spec ?? ""
            if s.hasPrefix("workspace:") {
                b.directKnown = true
                workspaceNames.insert(name)
                // A workspace's dependency lines are `name: range` one level below a dependency field.
                var inDeps = false
                let fieldIndent = block.body.first?.indent ?? 2
                for line in block.body {
                    if line.indent == fieldIndent {
                        inDeps = dependencyFields.contains { line.text == "\($0):" }
                    } else if inDeps, line.indent > fieldIndent, let kv = LockYAML.keyValue(line.text), let range = kv.value {
                        let r = LockYAML.unquote(range)
                        directDescriptors.insert("\(kv.key)@\(r)")
                        if !r.contains(":") { directDescriptors.insert("\(kv.key)@npm:\(r)") }
                    }
                }
                if s == "workspace:." { continue }                   // the project itself, like npm's "" root
            }
            entries.append(Entry(name: name, spec: s, version: f["version"], checksum: !(f["checksum"] ?? "").isEmpty, descriptors: descs))
        }
        for e in entries {
            let isDirect = b.directKnown ? (!workspaceNames.contains(e.name) && e.descriptors.contains { directDescriptors.contains($0) }) : nil
            let local = e.version?.hasSuffix("-use.local") == true
            b.add(name: e.name, version: local ? nil : e.version, origin: berryOrigin(e.spec), integrity: e.checksum, isDirect: isDirect)
        }
        return b.summary()
    }

    // MARK: pnpm

    /// Lines directly below a parent, each with the deeper lines under it.
    static func groups(_ lines: ArraySlice<LockLine>) -> [(head: LockLine, body: ArraySlice<LockLine>)] {
        guard let indent = lines.first?.indent else { return [] }
        var out: [(head: LockLine, body: ArraySlice<LockLine>)] = []
        var k = lines.startIndex
        while k < lines.endIndex {
            let head = lines[k]
            k += 1
            let start = k
            while k < lines.endIndex, lines[k].indent > indent { k += 1 }
            if head.indent == indent { out.append((head, lines[start..<k])) }
        }
        return out
    }

    static func pnpm(_ text: String) -> LockfileSummary? {
        let lines = LockLine.lines(text)
        var top: [String: ArraySlice<LockLine>] = [:]
        var version: String?
        var k = 0
        while k < lines.count {
            let head = lines[k]
            k += 1
            guard head.indent == 0, let kv = LockYAML.keyValue(head.text) else { continue }
            let start = k
            while k < lines.count, lines[k].indent > 0 { k += 1 }
            if kv.key == "lockfileVersion", let v = kv.value { version = LockYAML.unquote(v) }
            top[kv.key] = lines[start..<k]
        }
        guard let version else { return nil }
        let v5 = version.hasPrefix("5") || version.hasPrefix("4") || version.hasPrefix("3")

        func stripPeers(_ s: String) -> String {
            if v5 {
                // 5.x writes peers after an underscore in the last path segment: /name/1.0.0_peer@2.0.0.
                let tail = s.lastIndex(of: "/").map { s[$0...] } ?? s[...]
                guard let us = tail.firstIndex(of: "_") else { return s }
                return String(s[..<us])
            }
            return String(s.prefix { $0 != "(" })
        }

        // Direct dependencies: importers (workspaces, and every project from 6.x on) or the top-level groups (5.x).
        var directPairs: Set<String> = []
        var directKnown = false
        let groupNames = ["dependencies", "devDependencies", "optionalDependencies"]
        // One dependency group: `name: version` (5.x) or `name:` with `specifier:`/`version:` below it (6.x, 9.x).
        func readDependencies(_ group: ArraySlice<LockLine>) {
            directKnown = true
            for dep in groups(group) {
                guard let d = LockYAML.keyValue(dep.head.text) else { continue }
                var ver = d.value.map(LockYAML.unquote)
                for prop in groups(dep.body) {
                    if let p = LockYAML.keyValue(prop.head.text), p.key == "version", let pv = p.value { ver = LockYAML.unquote(pv) }
                }
                guard let raw = ver, !raw.hasPrefix("link:") else { continue }
                let clean = stripPeers(raw.hasPrefix("/") ? String(raw.dropFirst()) : raw)
                directPairs.insert("\(d.key)@\(clean)")
                directPairs.insert(clean)
            }
        }
        if let importers = top["importers"] {
            for importer in groups(importers) {
                for group in groups(importer.body) {
                    if let kv = LockYAML.keyValue(group.head.text), groupNames.contains(kv.key) { readDependencies(group.body) }
                }
            }
        }
        for key in groupNames { if let group = top[key] { readDependencies(group) } }

        var b = LockfileBuilder(.pnpm)
        b.formatVersion = version
        b.directKnown = directKnown
        let entries = top["packages"] ?? top["snapshots"] ?? []
        for entry in groups(entries) {
            guard let kv = LockYAML.keyValue(entry.head.text) else { continue }
            var key = kv.key
            if key.hasPrefix("/") { key.removeFirst() }
            key = stripPeers(key)
            var keyName: String
            var keyVersion: String?
            if v5, kv.key.hasPrefix("/"), let slash = key.lastIndex(of: "/") {
                keyName = String(key[..<slash])
                keyVersion = String(key[key.index(after: slash)...])
            } else if v5 {
                keyName = key
            } else {
                (keyName, keyVersion) = LockfileText.splitNameAt(Substring(key))
            }
            var resolution: [String: String] = [:]
            var name: String?
            var fieldVersion: String?
            for prop in groups(entry.body) {
                guard let p = LockYAML.keyValue(prop.head.text) else { continue }
                switch p.key {
                case "resolution":
                    if let value = p.value { resolution = LockYAML.flowMap(value) }
                    else {
                        for r in groups(prop.body) {
                            if let rv = LockYAML.keyValue(r.head.text) { resolution[rv.key] = rv.value.map(LockYAML.unquote) ?? "" }
                        }
                    }
                case "name": name = p.value.map(LockYAML.unquote)
                case "version": fieldVersion = p.value.map(LockYAML.unquote)
                default: break
                }
            }
            let finalName = name ?? keyName
            let finalVersion = fieldVersion ?? keyVersion
            let isDirect = directKnown
                ? directPairs.contains(key) || directPairs.contains("\(finalName)@\(keyVersion ?? "")") || directPairs.contains("\(finalName)@\(finalVersion ?? "")")
                : nil
            b.add(name: finalName, version: finalVersion, origin: pnpmOrigin(resolution),
                  integrity: !(resolution["integrity"] ?? "").isEmpty, isDirect: isDirect,
                  dedupKey: "\(finalName)@\(finalVersion ?? key)")
        }
        return b.summary()
    }

    private static func pnpmOrigin(_ r: [String: String]) -> LockfileOrigin {
        if r["type"] == "git" {
            return .git(r["repo"].flatMap { LockfileText.host($0.hasPrefix("git+") ? String($0.dropFirst(4)) : $0) },
                        commit: LockfileText.isCommit(r["commit"] ?? ""))
        }
        if r["type"] == "directory" || r["directory"] != nil { return .path(r["directory"]) }
        if let tarball = r["tarball"], !tarball.isEmpty { return origin(resolved: tarball, spec: nil) }
        if r["integrity"] != nil { return .defaultRegistry }
        return .unknown
    }

    // MARK: bun

    static func bun(_ bytes: [UInt8]) -> LockfileSummary? {
        let (parsed, complete) = LockJSONReader.parse(bytes, comments: true)
        guard let root = parsed, let packages = root["packages"]?.members else { return nil }
        var b = LockfileBuilder(.bun)
        b.formatVersion = root["lockfileVersion"]?.text
        b.truncated = !complete
        var direct: Set<String> = []
        if let workspaces = root["workspaces"]?.members {
            b.directKnown = true
            for ws in workspaces {
                for field in dependencyFields { for dep in ws.value[field]?.members ?? [] { direct.insert(dep.key) } }
            }
        }
        for (key, value) in packages {
            guard let tuple = value.array, let first = tuple.first?.string else { continue }
            let (name, specOrNil) = LockfileText.splitNameAt(Substring(first))
            let spec = specOrNil ?? ""
            var origin: LockfileOrigin
            var version: String? = nil
            var integrity = false
            if let p = ["workspace:", "file:", "link:"].first(where: spec.hasPrefix) {
                origin = .path(String(spec.dropFirst(p.count)))
            } else if LockfileText.looksGit(spec) {
                origin = .git(LockfileText.host(spec.hasPrefix("git+") ? String(spec.dropFirst(4)) : spec), commit: LockfileText.gitHasCommit(spec))
            } else if spec.hasPrefix("https://") || spec.hasPrefix("http://") {
                origin = Self.origin(resolved: spec, spec: nil)
            } else if spec.hasPrefix("root:") {
                origin = .path(nil)
            } else {
                version = spec.isEmpty ? nil : spec
                let registry = tuple.count > 1 ? tuple[1].string ?? "" : ""
                origin = registry.isEmpty ? .defaultRegistry : .registry(LockfileText.host(registry))
                integrity = tuple.count > 3 && (tuple[3].string?.hasPrefix("sha") ?? false)
            }
            b.add(name: name, version: version, origin: origin, integrity: integrity,
                  isDirect: b.directKnown ? key == name && direct.contains(name) : nil)
        }
        return b.summary()
    }
}
