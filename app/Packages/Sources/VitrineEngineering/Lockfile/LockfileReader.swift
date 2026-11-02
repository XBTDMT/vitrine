import Foundation

/// Reads a lockfile into a `LockfileSummary` for the lockfile card (A-12). The format is chosen by the exact file
/// name first and by the content's shape only when the name is not one it knows. Lockfiles are untrusted input: at
/// most `maxBytes` are read, at most `maxPackages` packages are kept (all are counted), nesting is bounded, nothing
/// is fetched, started or written, and malformed input gives nil or a partial summary, never a crash. Vulnerability
/// hints are not made here: A-12 allows them only from an opt-in local database, which is a separate step.
/// roadmap: S-22
public enum LockfileReader {
    /// The most bytes read from one file; past this the summary is marked `truncated`.
    public static let maxBytes = 8 * 1024 * 1024
    /// The most packages kept in `LockfileSummary.packages`; the rest are still counted.
    public static let maxPackages = 5_000

    /// File names (lowercased, exact) the reader recognises, for the preview's kind routing. bun.lockb, bun's
    /// binary lockfile, is deliberately not one of them.
    public static let knownFileNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", ".package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock",
        "cargo.lock", "gemfile.lock", "gems.locked", "poetry.lock", "uv.lock", "pipfile.lock", "go.sum", "go.work.sum",
        "package.resolved", "composer.lock", "podfile.lock",
    ]

    /// nil when the file is not a lockfile this reader knows (by name first, then content shape), or when its
    /// content does not have the shape its name promises.
    public static func read(data: Data, fileName: String) -> LockfileSummary? {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        if name == "bun.lockb" { return nil }
        let capped = data.count > maxBytes
        var bytes = [UInt8](data.prefix(maxBytes))
        if capped, !name.hasSuffix(".json"), name != "bun.lock", name != "package.resolved",
           let lastNewline = bytes.lastIndex(of: 0x0A) {
            bytes.removeSubrange((lastNewline + 1)...)      // line formats stop at the last whole line
        }
        guard !looksBinary(bytes) else { return nil }
        let reader = knownFileNames.contains(name) ? format(forName: name) : sniff(bytes)
        guard let reader, var summary = parse(reader, bytes) else { return nil }
        if capped { summary.truncated = true }
        return summary
    }

    // MARK: Routing

    enum Format: Equatable { case npm, yarn, pnpm, bun, cargo, bundler, poetry, uv, pipenv, goSum, swiftPM, composer, cocoapods }

    static func format(forName name: String) -> Format? {
        switch name {
        case "package-lock.json", "npm-shrinkwrap.json", ".package-lock.json": return .npm
        case "yarn.lock": return .yarn
        case "pnpm-lock.yaml": return .pnpm
        case "bun.lock": return .bun
        case "cargo.lock": return .cargo
        case "gemfile.lock", "gems.locked": return .bundler
        case "poetry.lock": return .poetry
        case "uv.lock": return .uv
        case "pipfile.lock": return .pipenv
        case "go.sum", "go.work.sum": return .goSum
        case "package.resolved": return .swiftPM
        case "composer.lock": return .composer
        case "podfile.lock": return .cocoapods
        default: return nil
        }
    }

    static func parse(_ format: Format, _ bytes: [UInt8]) -> LockfileSummary? {
        switch format {
        case .npm: return NodeLockfiles.npm(bytes)
        case .yarn: return NodeLockfiles.yarn(LockfileText.decode(bytes))
        case .pnpm: return NodeLockfiles.pnpm(LockfileText.decode(bytes))
        case .bun: return NodeLockfiles.bun(bytes)
        case .cargo: return TOMLLockfiles.cargo(bytes)
        case .poetry: return TOMLLockfiles.poetry(bytes)
        case .uv: return TOMLLockfiles.uv(bytes)
        case .pipenv: return OtherLockfiles.pipenv(bytes)
        case .goSum: return OtherLockfiles.goSum(LockfileText.decode(bytes))
        case .swiftPM: return OtherLockfiles.swiftPM(bytes)
        case .composer: return OtherLockfiles.composer(bytes)
        case .bundler: return OtherLockfiles.bundler(LockfileText.decode(bytes))
        case .cocoapods: return OtherLockfiles.cocoapods(LockfileText.decode(bytes))
        }
    }

    /// A NUL byte in the first 8 KB: a binary file (bun.lockb and the like), never a text lockfile.
    private static func looksBinary(_ bytes: [UInt8]) -> Bool {
        bytes.prefix(8192).contains(0)
    }

    /// The format from content alone, for a file whose name is not a known lockfile name. Only strong markers
    /// count, so an ordinary JSON, YAML or TOML file is not mistaken for a lockfile.
    static func sniff(_ bytes: [UInt8]) -> Format? {
        let head = LockfileText.decode(Array(bytes.prefix(64 * 1024)))
        let trimmed = head.drop { $0.isWhitespace }
        if trimmed.hasPrefix("{") {
            // Only the head is parsed: enough to see the top-level keys of every JSON lockfile.
            guard let root = LockJSONReader.parse(Array(bytes.prefix(64 * 1024)), comments: true).value else { return nil }
            if root["lockfileVersion"] != nil {
                if let first = root["packages"]?.members?.first, first.value.array != nil { return .bun }
                if root["workspaces"] != nil, root["packages"]?.members?.first?.value.array != nil { return .bun }
                return root["packages"] != nil || root["dependencies"] != nil || root["requires"] != nil ? .npm : nil
            }
            if root["_meta"]?["pipfile-spec"] != nil { return .pipenv }
            if root["pins"]?.array != nil || root["object"]?["pins"]?.array != nil { return .swiftPM }
            if root["content-hash"] != nil, root["packages"]?.array != nil { return .composer }
            return nil
        }
        if head.contains("# yarn lockfile v1") || head.hasPrefix("__metadata:") || head.contains("\n__metadata:\n") { return .yarn }
        if trimmed.hasPrefix("lockfileVersion:") { return .pnpm }
        if trimmed.hasPrefix("PODS:"), head.contains("\nCOCOAPODS:") || head.contains("\nSPEC CHECKSUMS:") { return .cocoapods }
        if head.contains("  specs:\n"), ["GEM", "GIT", "PATH"].contains(where: { trimmed.hasPrefix("\($0)\n") }) { return .bundler }
        if head.contains("[[package]]") {
            if head.contains("source = \"registry+") || head.contains("source = \"sparse+") || head.contains("checksum = \"") { return .cargo }
            if head.contains("requires-python") || head.contains("source = { registry") || head.contains("source = { editable")
                || head.contains("source = { virtual") { return .uv }
            if head.contains("[metadata]") || head.contains("[package.source]") || head.contains("python-versions") { return .poetry }
            return nil
        }
        // go.sum: every line is `module version h1:hash`.
        let lines = head.split(separator: "\n").prefix(20)
        if !lines.isEmpty, lines.allSatisfy({ line in
            let f = line.split(separator: " ")
            return f.count == 3 && f[2].hasPrefix("h1:")
        }) { return .goSum }
        return nil
    }
}
