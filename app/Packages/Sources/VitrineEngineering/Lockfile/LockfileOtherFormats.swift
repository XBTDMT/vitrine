import Foundation

/// The remaining lockfiles (A-12): Pipfile.lock, go.sum, Package.resolved, composer.lock (JSON or line formats) and
/// Gemfile.lock, Podfile.lock (indentation formats). roadmap: S-22
enum OtherLockfiles {
    // MARK: Pipfile.lock

    static func pipenv(_ bytes: [UInt8]) -> LockfileSummary? {
        let (parsed, complete) = LockJSONReader.parse(bytes)
        guard let root = parsed, root["_meta"] != nil || root["default"] != nil || root["develop"] != nil else { return nil }
        var b = LockfileBuilder(.pipenv)
        b.formatVersion = root["_meta"]?["pipfile-spec"]?.text
        b.truncated = !complete
        var indexHosts: [String: String] = [:]
        var firstHost: String?
        for source in root["_meta"]?["sources"]?.array ?? [] {
            guard let url = source["url"]?.string, let host = LockfileText.host(url) else { continue }
            if let name = source["name"]?.string { indexHosts[name] = host }
            if firstHost == nil { firstHost = host }
        }
        for section in ["default", "develop"] {
            for (name, entry) in root[section]?.members ?? [] {
                let raw = entry["version"]?.string
                let version = raw.map { $0.hasPrefix("==") ? String($0.dropFirst(2)) : $0 }
                let origin: LockfileOrigin
                if let git = entry["git"]?.string {
                    origin = .git(LockfileText.host(git.hasPrefix("git+") ? String(git.dropFirst(4)) : git),
                                  commit: LockfileText.isCommit(entry["ref"]?.string ?? ""))
                } else if let path = entry["path"]?.string {
                    origin = .path(path)
                } else if let file = entry["file"]?.string {
                    origin = file.contains("://") && !file.hasPrefix("file:") ? .url(LockfileText.host(file)) : .path(file)
                } else if let index = entry["index"]?.string, let host = indexHosts[index] {
                    origin = .registry(host)
                } else {
                    origin = firstHost.map { .registry($0) } ?? .defaultRegistry
                }
                b.add(name: name, version: version, origin: origin, integrity: !(entry["hashes"]?.array ?? []).isEmpty,
                      isDirect: nil, exact: raw?.hasPrefix("==") == true && LockfileText.looksExact(version),
                      dedupKey: "\(name.lowercased())@\(raw ?? "")")
            }
        }
        return b.summary()
    }

    // MARK: go.sum

    static func goSum(_ text: String) -> LockfileSummary? {
        var b = LockfileBuilder(.goModules)
        var sawLine = false
        var valid = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard !fields.isEmpty else { continue }
            sawLine = true
            guard fields.count == 3, fields[2].hasPrefix("h"), fields[2].contains(":") else { continue }
            valid += 1
            let module = fields[0]
            let version = fields[1]
            if version.hasSuffix("/go.mod") { continue }        // the module's go.mod hash, not the module itself
            let host = module.split(separator: "/").first.map { String($0).lowercased() }
            b.add(name: String(module), version: String(version), origin: .registry(host), integrity: true,
                  isDirect: nil, dedupKey: "\(module)@\(version)")
        }
        guard valid > 0 || !sawLine else { return nil }
        return b.summary()
    }

    // MARK: Package.resolved

    static func swiftPM(_ bytes: [UInt8]) -> LockfileSummary? {
        let (parsed, complete) = LockJSONReader.parse(bytes)
        guard let root = parsed, let pins = root["pins"]?.array ?? root["object"]?["pins"]?.array else { return nil }
        var b = LockfileBuilder(.swiftPM)
        b.formatVersion = root["version"]?.text
        b.truncated = !complete
        for pin in pins {
            guard let name = pin["identity"]?.string ?? pin["package"]?.string else { continue }
            let location = pin["location"]?.string ?? pin["repositoryURL"]?.string
            let state = pin["state"]
            let revision = state?["revision"]?.string ?? ""
            let origin: LockfileOrigin
            switch pin["kind"]?.string {
            case "registry": origin = .defaultRegistry
            case "localSourceControl", "fileSystem": origin = .path(location)
            default: origin = .git(location.flatMap(LockfileText.host), commit: LockfileText.isCommit(revision))
            }
            let version = state?["version"]?.string ?? state?["branch"]?.string
            // The repository URL is what OSV's SwiftURL names a package by (G-26).
            b.add(name: name, version: version, origin: origin, integrity: false, isDirect: nil,
                  locator: pin["kind"]?.string == "remoteSourceControl" || pin["kind"] == nil ? location : nil)
        }
        return b.summary()
    }

    // MARK: composer.lock

    static func composer(_ bytes: [UInt8]) -> LockfileSummary? {
        let (parsed, complete) = LockJSONReader.parse(bytes)
        guard let root = parsed, root["packages"]?.array != nil || root["packages-dev"]?.array != nil else { return nil }
        var b = LockfileBuilder(.composer)
        b.carriesLicences = true
        b.truncated = !complete
        for list in ["packages", "packages-dev"] {
            for p in root[list]?.array ?? [] {
                guard let name = p["name"]?.string else { continue }
                let version = p["version"]?.string
                let source = p["source"]
                let dist = p["dist"]
                let isDev = version.map { $0.hasPrefix("dev-") || $0.hasSuffix("-dev") } ?? false
                let origin: LockfileOrigin
                if dist?["type"]?.string == "path" || source?["type"]?.string == "path" {
                    origin = .path(dist?["url"]?.string ?? source?["url"]?.string)
                } else if isDev || p["notification-url"] == nil, source?["type"]?.string == "git" {
                    origin = .git(source?["url"]?.string.flatMap(LockfileText.host),
                                  commit: LockfileText.isCommit(source?["reference"]?.string ?? ""))
                } else if let note = p["notification-url"]?.string {
                    origin = .registry(LockfileText.host(note))
                } else if let url = dist?["url"]?.string {
                    origin = .url(LockfileText.host(url))
                } else {
                    origin = .unknown
                }
                let licences = (p["license"]?.array ?? []).compactMap(\.string)
                b.add(name: name, version: version, origin: origin, integrity: !(dist?["shasum"]?.string ?? "").isEmpty,
                      isDirect: nil, licence: licences.isEmpty ? nil : licences.joined(separator: " OR "),
                      exact: !isDev && LockfileText.looksExact(version))
            }
        }
        return b.summary()
    }

    // MARK: Gemfile.lock

    /// `name (version)` → (name, version); `name` alone → (name, nil).
    private static func nameAndParen(_ s: Substring) -> (String, String?) {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else {
            return (String(s.prefix { $0 != " " && $0 != "!" }), nil)
        }
        return (s[..<open].trimmingCharacters(in: .whitespaces), String(s[s.index(after: open)..<close]))
    }

    static func bundler(_ text: String) -> LockfileSummary? {
        let lines = LockLine.lines(text)
        struct Gem { var name: String; var version: String?; var origin: LockfileOrigin }
        var gems: [Gem] = []
        var direct: Set<String> = []
        var hasDependencies = false
        var checksums: Set<String> = []
        var sawSection = false
        for section in NodeLockfiles.groups(lines[...]) where section.head.indent == 0 {
            let title = section.head.text
            switch title {
            case "GEM", "GIT", "PATH", "PLUGIN SOURCE":
                sawSection = true
                var remote: String?
                var revision: String?
                var specs: ArraySlice<LockLine> = []
                for field in NodeLockfiles.groups(section.body) {
                    guard let kv = LockYAML.keyValue(field.head.text) else { continue }
                    switch kv.key {
                    case "remote": if remote == nil { remote = kv.value.map(String.init) }
                    case "revision": revision = kv.value.map(String.init)
                    case "specs": specs = field.body
                    default: break
                    }
                }
                let origin: LockfileOrigin
                switch title {
                case "GIT": origin = .git(remote.flatMap(LockfileText.host), commit: LockfileText.isCommit(revision ?? ""))
                case "PATH": origin = .path(remote)
                default: origin = .registry(remote.flatMap(LockfileText.host))
                }
                for spec in NodeLockfiles.groups(specs) {
                    let (name, version) = nameAndParen(spec.head.text)
                    gems.append(Gem(name: name, version: version, origin: origin))
                }
            case "DEPENDENCIES":
                hasDependencies = true
                for dep in NodeLockfiles.groups(section.body) { direct.insert(nameAndParen(dep.head.text).0) }
            case "CHECKSUMS":
                for line in NodeLockfiles.groups(section.body) {
                    let (name, version) = nameAndParen(line.head.text)
                    if line.head.text.contains("=") { checksums.insert("\(name)@\(version ?? "")") }
                }
            default: break
            }
        }
        guard sawSection || hasDependencies else { return nil }
        var b = LockfileBuilder(.bundler)
        b.directKnown = hasDependencies
        for g in gems {
            b.add(name: g.name, version: g.version, origin: g.origin, integrity: checksums.contains("\(g.name)@\(g.version ?? "")"),
                  isDirect: hasDependencies ? direct.contains(g.name) : nil, dedupKey: "\(g.name)@\(g.version ?? "")")
        }
        return b.summary()
    }

    // MARK: Podfile.lock

    static func cocoapods(_ text: String) -> LockfileSummary? {
        let lines = LockLine.lines(text)
        var pods: [(name: String, version: String?)] = []
        var direct: Set<String> = []
        var hasDependencies = false
        var repoOf: [String: String] = [:]
        var external: [String: [String: String]] = [:]
        var checkout: [String: [String: String]] = [:]
        var checksums: Set<String> = []
        var sawPods = false

        func item(_ line: LockLine) -> Substring? {
            guard line.text.hasPrefix("- ") else { return nil }
            var t = line.text.dropFirst(2)
            if t.hasSuffix(":") { t = t.dropLast() }
            return Substring(LockYAML.unquote(t))
        }
        func root(_ name: String) -> String { String(name.prefix { $0 != "/" }) }
        func options(_ body: ArraySlice<LockLine>) -> [String: [String: String]] {
            var out: [String: [String: String]] = [:]
            for pod in NodeLockfiles.groups(body) {
                guard let kv = LockYAML.keyValue(pod.head.text) else { continue }
                var opts: [String: String] = [:]
                for o in NodeLockfiles.groups(pod.body) {
                    if let ov = LockYAML.keyValue(o.head.text) { opts[ov.key] = ov.value.map(LockYAML.unquote) ?? "" }
                }
                out[kv.key] = opts
            }
            return out
        }

        for section in NodeLockfiles.groups(lines[...]) where section.head.indent == 0 {
            guard let kv = LockYAML.keyValue(section.head.text) else { continue }
            switch kv.key {
            case "PODS":
                sawPods = true
                for entry in NodeLockfiles.groups(section.body) {
                    guard let t = item(entry.head) else { continue }
                    let (name, version) = nameAndParen(t)
                    pods.append((name, version))
                }
            case "DEPENDENCIES":
                hasDependencies = true
                for entry in NodeLockfiles.groups(section.body) {
                    if let t = item(entry.head) { direct.insert(root(nameAndParen(t).0)) }
                }
            case "SPEC REPOS":
                for repo in NodeLockfiles.groups(section.body) {
                    guard let r = LockYAML.keyValue(repo.head.text) else { continue }
                    let label = r.key.contains("://") ? (LockfileText.host(r.key) ?? r.key) : r.key
                    for entry in NodeLockfiles.groups(repo.body) {
                        if let t = item(entry.head) { repoOf[root(String(t))] = label }
                    }
                }
            case "EXTERNAL SOURCES": external = options(section.body)
            case "CHECKOUT OPTIONS": checkout = options(section.body)
            case "SPEC CHECKSUMS":
                for entry in NodeLockfiles.groups(section.body) {
                    if let c = LockYAML.keyValue(entry.head.text), c.value != nil { checksums.insert(c.key) }
                }
            default: break
            }
        }
        guard sawPods else { return nil }
        var b = LockfileBuilder(.cocoapods)
        b.directKnown = hasDependencies
        for pod in pods {
            let name = root(pod.name)
            let ext = external[name] ?? [:]
            let co = checkout[name] ?? [:]
            let origin: LockfileOrigin
            if let git = ext[":git"] ?? co[":git"] {
                origin = .git(LockfileText.host(git), commit: LockfileText.isCommit(co[":commit"] ?? ext[":commit"] ?? ""))
            } else if let path = ext[":path"] {
                origin = .path(path)
            } else if let podspec = ext[":podspec"] {
                origin = podspec.contains("://") ? .url(LockfileText.host(podspec)) : .path(podspec)
            } else if let repo = repoOf[name] {
                origin = LockfileOrigin(kind: .registry, host: repo, label: repo)
            } else {
                origin = .unknown
            }
            // Subspecs (Name/Core) are one pod: they share a version, a source and a checksum.
            b.add(name: name, version: pod.version, origin: origin, integrity: checksums.contains(name),
                  isDirect: hasDependencies ? direct.contains(name) : nil, dedupKey: name)
        }
        return b.summary()
    }
}
