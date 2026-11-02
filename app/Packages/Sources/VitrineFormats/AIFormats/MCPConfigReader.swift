import Foundation
import VitrineData

/// How an MCP client reaches a server. roadmap: S-21
public enum MCPTransport: String, Sendable, Equatable {
    /// A local program the client starts, talking over its standard input and output.
    case stdio
    /// A remote server over Streamable HTTP.
    case http
    /// A remote server over Server-Sent Events (the older remote transport).
    case sse
    case unknown
}

/// Whether the package a runner downloads is held to one version. roadmap: S-21
public enum MCPPinning: Sendable, Equatable {
    /// An exact version or digest.
    case pinned(String)
    /// No version, `latest`, or a range: what runs can change on any start.
    case unpinned(String)
    /// A local program or script: nothing is downloaded.
    case notApplicable
}

/// An env or header entry: its key only, never its value, with whether the key or the value's shape looks like a
/// secret. roadmap: S-21
public struct MCPKeyEntry: Sendable, Equatable {
    /// Where the value comes from, without the value itself. roadmap: S-21
    public enum ValueKind: String, Sendable, Equatable {
        /// Written into the file.
        case literal
        /// A `${…}` reference filled in at launch (an env variable, a prompted input).
        case placeholder
        case empty
        /// Not a string (a number, a list).
        case other
    }

    public var key: String
    public var valueKind: ValueKind
    /// The key's name says secret (TOKEN, API_KEY, PASSWORD, Authorization …).
    public var keyLooksSecret: Bool
    /// The written value has a secret's shape (a known token prefix, a long random string).
    public var valueLooksSecret: Bool

    public var looksSecret: Bool { keyLooksSecret || valueLooksSecret }
}

/// One server entry of an MCP config. roadmap: S-21
public struct MCPServer: Sendable, Equatable {
    public var name: String
    public var transport: MCPTransport
    public var command: String?
    public var args: [String]
    /// The exact command line that runs on this Mac, shell-quoted; `${…}` placeholders stay as written.
    public var commandLine: String?
    /// npx, bunx, uvx, pipx, docker, node, python … (the command's base name).
    public var runner: String?
    /// The package or image the runner fetches, or the script it runs.
    public var package: String?
    public var pinning: MCPPinning
    public var env: [MCPKeyEntry]
    public var headers: [MCPKeyEntry]
    /// The remote URL with secret-looking query values and passwords replaced by •••.
    public var url: String?
    public var host: String?
    public var workingDirectory: String?
    public var disabled: Bool
    /// Tools the client calls without asking (Cline's `autoApprove`, `alwaysAllow`).
    public var autoApprovedTools: [String]
    public var warnings: [AIWarning]
}

/// An MCP configuration file (Claude Code `.mcp.json`, Claude Desktop, Cursor, VS Code): every server, what it runs
/// or connects to, pinning, secret-looking keys, and dangerous commands. roadmap: S-21
public struct MCPConfigSummary: Sendable, Equatable {
    /// The client the file belongs to, from its name and folder.
    public var client: String
    /// `mcpServers` or `servers`.
    public var rootKey: String?
    public var servers: [MCPServer]
    public var serversTruncated: Bool
    /// VS Code's prompted `inputs`.
    public var inputCount: Int
    public var remoteHosts: [String]
    public var headline: String
    public var facts: [AIFact]
    /// The file's own warnings followed by every server's, each with the server as its subject.
    public var warnings: [AIWarning]
}

enum MCPConfigReader {
    static func recognises(fileName name: String, path: String) -> Bool {
        [".mcp.json", "mcp.json", "claude_desktop_config.json", "mcp_settings.json", "cline_mcp_settings.json"].contains(name)
    }

    static func read(bytes: [UInt8], fileName: String, path: String?, fileSize: Int64) -> MCPConfigSummary? {
        let (rootView, result) = AIJSONView.parse(bytes, format: .json, maxDepth: 32, maxNodes: 100_000,
                                                  fileSize: max(fileSize, Int64(bytes.count)))
        let given = (path ?? fileName).lowercased()
        let lowerPath = given.hasPrefix("/") ? given : "/" + given
        let lower = fileName.lowercased()
        let client: String
        let shared: Bool
        if lowerPath.hasSuffix("/.cursor/mcp.json") { client = "Cursor"
            // ~/.cursor/mcp.json is the user's own; a project's .cursor/mcp.json travels with the repository.
            shared = lowerPath.range(of: #"^/users/[^/]+/\.cursor/mcp\.json$"#, options: .regularExpression) == nil }
        else if lowerPath.hasSuffix("/.vscode/mcp.json") { client = "VS Code"; shared = true }
        else if lower == "claude_desktop_config.json" { client = "Claude Desktop"; shared = false }
        else if lower == ".mcp.json" {
            client = String(localized: "Claude Code (project)", bundle: .module, comment: "The app an MCP config file belongs to: Claude Code's per-project file. Claude Code is a product name.")
            shared = true
        }
        else if lower.contains("cline") { client = "Cline"; shared = false }
        else if lowerPath.contains("/library/application support/code/user/") {
            client = String(localized: "VS Code (user)", bundle: .module, comment: "The app an MCP config file belongs to: VS Code's per-user file. VS Code is a product name.")
            shared = false
        }
        else { client = String(localized: "MCP client", bundle: .module, comment: "The app an MCP config file belongs to, when the file does not say. MCP is a protocol name."); shared = false }
        let clientLabel = String(localized: "Client", bundle: .module, comment: "Fact label on an MCP config card: the app the file belongs to.")

        var warnings: [AIWarning] = []
        guard let root = rootView, root.isObject else {
            var w = [AIWarning(.caution, String(localized: "This is not a valid JSON object, so the client will refuse to load it.", bundle: .module, comment: "Warning on an MCP config card."))]
            if let error = result.error { w[0].reason += " (\(error.description))" }
            return MCPConfigSummary(client: client, rootKey: nil, servers: [], serversTruncated: false, inputCount: 0, remoteHosts: [],
                                    headline: String(localized: "\(client) MCP config (unreadable)", bundle: .module, comment: "Headline of an MCP config card that could not be read. The argument is the app it belongs to."),
                                    facts: [AIFact(clientLabel, client)], warnings: w)
        }
        if let error = result.error {
            let detail = error.description
            warnings.append(AIWarning(.caution, String(localized: "The JSON has an error (\(detail)); the client may refuse the file.", bundle: .module, comment: "Warning on an MCP config card. The argument is a technical parser message in English.")))
        }
        let rootKey = ["mcpServers", "servers", "context_servers"].first { root[$0]?.isObject == true }
        let serverNodes = rootKey.flatMap { root[$0] }?.children ?? []
        var servers: [MCPServer] = []
        for node in serverNodes.prefix(AIFormatsLimits.maxListItems) {
            guard let name = node.name else { continue }
            servers.append(server(name: name, node, sharedFile: shared))
        }
        let inputCount = root["inputs"]?.count ?? 0
        let hosts = Array(Set(servers.compactMap(\.host))).sorted()

        for s in servers {
            for w in s.warnings {
                let server = s.name, reason = w.reason
                warnings.append(AIWarning(w.level, String(localized: "\(server): \(reason)", bundle: .module, comment: "A server's warning on an MCP config card: the server's name, then the warning sentence."), subject: s.name))
            }
        }
        var facts = [AIFact(clientLabel, client),
                     AIFact(String(localized: "Servers", bundle: .module, comment: "Fact label on an MCP config card."), AIFormat.count(serverNodes.count))]
        let local = servers.filter { $0.transport == .stdio }.count
        if local > 0 {
            facts.append(AIFact(String(localized: "Local programs", bundle: .module, comment: "Fact label on an MCP config card: servers that run as programs on this Mac."), AIFormat.count(local)))
        }
        if !hosts.isEmpty {
            facts.append(AIFact(String(localized: "Remote hosts", bundle: .module, comment: "Fact label on an MCP config card: internet hosts the servers connect to."), hosts.joined(separator: ", ")))
        }
        if inputCount > 0 {
            facts.append(AIFact(String(localized: "Prompted inputs", bundle: .module, comment: "Fact label on an MCP config card: values VS Code asks for at launch."), AIFormat.count(inputCount)))
        }
        let secretKeys = servers.flatMap { $0.env + $0.headers }.filter(\.looksSecret).count
        if secretKeys > 0 {
            facts.append(AIFact(String(localized: "Secret-looking keys", bundle: .module, comment: "Fact label on an MCP config card: environment or header keys whose name or value looks like a secret."), AIFormat.count(secretKeys)))
        }
        if rootKey == nil {
            warnings.insert(AIWarning(.caution, String(localized: "No mcpServers or servers object, so no server is configured.", bundle: .module, comment: "Warning on an MCP config card. mcpServers and servers are JSON keys and stay as they are.")), at: 0)
        }

        let n = serverNodes.count
        let headline = String(localized: "\(client) MCP config: \(n) servers", bundle: .module, comment: "Headline of an MCP config card. The app it belongs to, then the number of servers (plural forms).")
        return MCPConfigSummary(client: client, rootKey: rootKey, servers: servers,
                                serversTruncated: serverNodes.count > servers.count, inputCount: inputCount,
                                remoteHosts: hosts, headline: headline, facts: facts, warnings: warnings)
    }

    static func server(name: String, _ node: AIJSONView, sharedFile: Bool) -> MCPServer {
        var warnings: [AIWarning] = []
        let command = node["command"]?.string
        let args = node["args"]?.strings ?? []
        let type = node["type"]?.string?.lowercased() ?? node["transport"]?.string?.lowercased()
        let rawURL = node["url"]?.string ?? node["serverUrl"]?.string ?? node["httpUrl"]?.string
        let transport: MCPTransport
        if command != nil, type == nil || type == "stdio" { transport = .stdio }
        else if let type, type == "sse" { transport = .sse }
        else if let type, ["http", "streamable-http", "streamablehttp", "streamable_http"].contains(type) { transport = .http }
        else if let rawURL { transport = URL(string: rawURL)?.path.hasSuffix("/sse") == true ? .sse : .http }
        else if command != nil { transport = .stdio }
        else { transport = .unknown }

        var commandLine: String?
        var runner: String?
        var package: String?
        var pinning = MCPPinning.notApplicable
        if let command {
            let line = ([command] + args).map(shellQuote).joined(separator: " ")
            commandLine = line
            (runner, package, pinning) = analyse(command: command, args: args)
            if case .unpinned(let why) = pinning {
                let what = package ?? String(localized: "a package", bundle: .module, comment: "Stands in for a package name in an MCP warning when none is given.")
                warnings.append(AIWarning(.caution, String(localized: "It runs \(what) \(why), so a new release can change what runs on any start.", bundle: .module, comment: "Warning on an MCP server. A package name, then why it is not pinned, such as “without a version” or “at @latest”."), subject: package))
            }
            // Unquoted, so `| sh` inside a `-c` string is seen.
            warnings += commandDangers(command: command, args: args, line: ([command] + args).joined(separator: " "))
        }

        // Env and headers: keys only.
        let env = keys(node["env"])
        let headers = keys(node["headers"])
        for entry in env + headers where entry.valueKind == .literal && entry.looksSecret {
            let key = entry.key
            if sharedFile {
                warnings.append(AIWarning(.danger, String(localized: "\(key) holds what looks like a secret, written into the file in plain text. This file is usually committed and shared with everyone who clones the project.", bundle: .module, comment: "Warning on an MCP server. The argument is an environment variable or header name."), subject: key))
            } else {
                warnings.append(AIWarning(.caution, String(localized: "\(key) holds what looks like a secret, written into the file in plain text.", bundle: .module, comment: "Warning on an MCP server. The argument is an environment variable or header name."), subject: key))
            }
        }
        if let envFile = node["envFile"]?.string {
            warnings.append(AIWarning(.caution, String(localized: "It loads more environment variables from \(envFile), which this card cannot see.", bundle: .module, comment: "Warning on an MCP server. The argument is a file path.")))
        }

        var url: String?
        var host: String?
        if let rawURL, let components = URLComponents(string: rawURL) {
            host = components.host
            var safe = components
            if safe.password != nil { safe.password = "•••" }
            safe.queryItems = components.queryItems?.map { item in
                secretKeyName(item.name) || (item.value.map(valueLooksSecret) ?? false) ? URLQueryItem(name: item.name, value: "•••") : item
            }
            url = safe.string ?? rawURL
            if components.password != nil || components.queryItems?.contains(where: { secretKeyName($0.name) || ($0.value.map(valueLooksSecret) ?? false) }) == true {
                warnings.append(AIWarning(sharedFile ? .danger : .caution, String(localized: "The URL carries a credential, written into the file in plain text.", bundle: .module, comment: "Warning on an MCP server."), subject: host))
            }
            let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host ?? "")
            if components.scheme?.lowercased() == "http", !local {
                let shown = host ?? String(localized: "a remote host", bundle: .module, comment: "Stands in for a host name in an MCP warning when the URL has none.")
                warnings.append(AIWarning(.caution, String(localized: "It connects over plain http to \(shown), so traffic and tokens travel unencrypted.", bundle: .module, comment: "Warning on an MCP server. The argument is a host name."), subject: host))
            }
        } else if let rawURL {
            url = AIFormat.clip(rawURL, 200)
        }

        let disabled = node["disabled"]?.bool == true || node["enabled"]?.bool == false
        let auto = (node["autoApprove"]?.strings ?? []) + (node["alwaysAllow"]?.strings ?? [])
        if !auto.isEmpty {
            let count = auto.count, names = auto.prefix(8).joined(separator: ", ")
            warnings.append(AIWarning(.caution, String(localized: "The client calls \(count) tools without asking (\(names)).", bundle: .module, comment: "Warning on an MCP server. A number of tools (plural forms), then their names.")))
        }
        if transport == .unknown {
            warnings.append(AIWarning(.caution, String(localized: "It has neither a command nor a URL, so the client cannot start it.", bundle: .module, comment: "Warning on an MCP server.")))
        }
        return MCPServer(name: name, transport: transport, command: command, args: args, commandLine: commandLine,
                         runner: runner, package: package, pinning: pinning, env: env, headers: headers, url: url,
                         host: host, workingDirectory: node["cwd"]?.string, disabled: disabled,
                         autoApprovedTools: auto, warnings: warnings)
    }

    static func keys(_ node: AIJSONView?) -> [MCPKeyEntry] {
        guard let node, node.isObject else { return [] }
        return node.children.prefix(500).compactMap { child in
            guard let key = child.name else { return nil }
            let kind: MCPKeyEntry.ValueKind
            var valueSecret = false
            if let value = child.string {
                if value.isEmpty { kind = .empty }
                else if value.contains("${") || value.hasPrefix("$") || isPlaceholderText(value) { kind = .placeholder }
                else { kind = .literal; valueSecret = valueLooksSecret(value) }
            } else { kind = .other }
            return MCPKeyEntry(key: key, valueKind: kind, keyLooksSecret: secretKeyName(key), valueLooksSecret: valueSecret)
        }
    }

    static func isPlaceholderText(_ value: String) -> Bool {
        let v = value.lowercased()
        return (v.hasPrefix("<") && v.hasSuffix(">")) || v.hasPrefix("your") || v.contains("your-") || v.contains("your_")
            || v.contains("xxxx") || v == "changeme" || v.hasPrefix("{{")
    }

    static func secretKeyName(_ key: String) -> Bool {
        let k = key.uppercased().replacingOccurrences(of: "-", with: "_")
        let words = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "PRIVATE_KEY", "ACCESS_KEY", "AUTH",
                     "CREDENTIAL", "BEARER", "COOKIE", "SESSION", "CLIENT_SECRET"]
        if words.contains(where: { k.contains($0) }) {
            // Not a secret: names that only point at one.
            return !(k.hasSuffix("_URL") || k.hasSuffix("_HOST") || k.hasSuffix("_PATH") || k.hasSuffix("_FILE")
                     || k.hasSuffix("_URI") || k == "AUTHOR")
        }
        return k.hasSuffix("_KEY") || k == "KEY" || k == "PAT" || k.hasSuffix("_PAT")
    }

    /// A known token prefix, a bearer value, or a long random-looking string.
    static func valueLooksSecret(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        let prefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
                        "glpat-", "xoxb-", "xoxp-", "xoxa-", "xapp-", "AKIA", "ASIA", "AIza", "ya29.", "hf_", "npm_",
                        "pypi-", "dop_v1_", "shpat_", "sq0atp-", "SG.", "lin_api_", "ntn_", "secret_", "pk_live_"]
        if prefixes.contains(where: { v.hasPrefix($0) }) && v.count >= 12 { return true }
        if v.lowercased().hasPrefix("bearer ") || v.lowercased().hasPrefix("basic ") || v.lowercased().hasPrefix("token ") {
            return v.count > 12
        }
        if v.hasPrefix("eyJ") && v.filter({ $0 == "." }).count == 2 { return true }   // a JWT
        guard v.count >= 24, !v.contains(" "), !v.contains("/") || v.count >= 40, !v.hasPrefix("http") else { return false }
        let hasUpper = v.contains(where: \.isUppercase), hasLower = v.contains(where: \.isLowercase)
        let hasDigit = v.contains(where: \.isNumber)
        let classes = [hasUpper, hasLower, hasDigit].filter { $0 }.count
        if classes >= 3 { return true }
        // Long hex.
        return v.count >= 32 && v.allSatisfy(\.isHexDigit)
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./_-".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The runner, the package it fetches and whether that is pinned.
    static func analyse(command: String, args: [String]) -> (String?, String?, MCPPinning) {
        let base = (command as NSString).lastPathComponent.lowercased()
        func firstPositional(_ list: ArraySlice<String>, valueFlags: Set<String> = []) -> String? {
            var skipNext = false
            for a in list {
                if skipNext { skipNext = false; continue }
                if a.hasPrefix("-") {
                    if valueFlags.contains(a) { skipNext = true }
                    continue
                }
                return a
            }
            return nil
        }
        func packageFlag(_ list: [String], _ names: [String]) -> String? {
            for (i, a) in list.enumerated() {
                for n in names {
                    if a == n, i + 1 < list.count { return list[i + 1] }
                    if a.hasPrefix(n + "=") { return String(a.dropFirst(n.count + 1)) }
                }
            }
            return nil
        }
        switch base {
        case "npx", "bunx", "pnpx":
            let pkg = packageFlag(args, ["-p", "--package"]) ?? firstPositional(args[...], valueFlags: ["--registry", "--cache"])
            return (base, pkg, pkg.map(npmPin) ?? .unpinned(Unpinned.noPackage))
        case "pnpm", "yarn", "bun", "npm":
            if let i = args.firstIndex(where: { ["dlx", "x", "exec"].contains($0) }) {
                let pkg = firstPositional(args[(i + 1)...])
                return ("\(base) \(args[i])", pkg, pkg.map(npmPin) ?? .notApplicable)
            }
            return (base, nil, .notApplicable)
        case "uvx":
            let pkg = packageFlag(args, ["--from"]) ?? firstPositional(args[...], valueFlags: ["--python", "--with", "--index-url"])
            return (base, pkg, pkg.map(pythonPin) ?? .unpinned(Unpinned.noPackage))
        case "uv":
            if let i = args.firstIndex(of: "tool"), args.count > i + 1, args[i + 1] == "run" {
                let rest = Array(args[(i + 2)...])
                let pkg = packageFlag(rest, ["--from"]) ?? firstPositional(rest[...])
                return ("uv tool run", pkg, pkg.map(pythonPin) ?? .notApplicable)
            }
            if let i = args.firstIndex(of: "run") {
                return ("uv run", firstPositional(args[(i + 1)...], valueFlags: ["--directory", "--with", "--python"]), .notApplicable)
            }
            return (base, nil, .notApplicable)
        case "pipx":
            if let i = args.firstIndex(of: "run") {
                let rest = Array(args[(i + 1)...])
                let pkg = packageFlag(rest, ["--spec"]) ?? firstPositional(rest[...])
                return ("pipx run", pkg, pkg.map(pythonPin) ?? .unpinned(Unpinned.noPackage))
            }
            return (base, nil, .notApplicable)
        case "docker", "podman":
            guard let i = args.firstIndex(of: "run") else { return (base, nil, .notApplicable) }
            let valueFlags: Set<String> = ["-e", "--env", "-v", "--volume", "--name", "-p", "--publish", "--network", "--env-file",
                                           "-w", "--workdir", "--user", "-u", "--entrypoint", "--mount", "--platform", "-l", "--label"]
            let image = firstPositional(args[(i + 1)...], valueFlags: valueFlags)
            return (base, image, image.map(imagePin) ?? .unpinned(Unpinned.noImage))
        case "node", "python", "python3", "deno", "ruby", "java", "go":
            let script = firstPositional(args[...], valueFlags: ["-m", "--import", "-r"]) ?? packageFlag(args, ["-m"])
            return (base, script, .notApplicable)
        default:
            return (base, nil, .notApplicable)
        }
    }

    /// Why a package is not pinned, as the end of "It runs <package> …".
    enum Unpinned {
        static var noVersion: String {
            String(localized: "without a version", bundle: .module, comment: "Ends “It runs <package> …” on an MCP card: no version is named.")
        }
        static var noPackage: String {
            String(localized: "with no package named", bundle: .module, comment: "Ends “It runs <runner> …” on an MCP card: the command names no package.")
        }
        static var noImage: String {
            String(localized: "with no image named", bundle: .module, comment: "Ends “It runs <runner> …” on an MCP card: docker run names no image.")
        }
        static func tag(_ version: String) -> String {
            String(localized: "at \(version)", bundle: .module, comment: "Ends “It runs <package> …” on an MCP card: a moving tag such as @latest or :latest, kept as written.")
        }
        static func range(_ version: String) -> String {
            String(localized: "at the range \(version)", bundle: .module, comment: "Ends “It runs <package> …” on an MCP card: a version range such as ^1.2.0.")
        }
        static var someRange: String {
            String(localized: "at a version range", bundle: .module, comment: "Ends “It runs <package> …” on an MCP card.")
        }
        static var defaultBranch: String {
            String(localized: "from a repository's default branch", bundle: .module, comment: "Ends “It runs <package> …” on an MCP card: installed from a git repository without a commit or tag.")
        }
        static var untaggedImage: String {
            String(localized: "without a tag (that means :latest)", bundle: .module, comment: "Ends “It runs <image> …” on an MCP card. :latest is a Docker tag and stays as written.")
        }
    }

    /// `pkg@1.2.3` and `@scope/pkg@1.2.3` are pinned; a bare name, `@latest`, a tag or a range is not.
    static func npmPin(_ spec: String) -> MCPPinning {
        let body = spec.hasPrefix("@") ? String(spec.dropFirst()) : spec
        guard let at = body.lastIndex(of: "@") else { return .unpinned(Unpinned.noVersion) }
        let version = String(body[body.index(after: at)...])
        if version.isEmpty { return .unpinned(Unpinned.noVersion) }
        if ["latest", "next", "canary", "beta", "alpha", "*", "x"].contains(version.lowercased()) { return .unpinned(Unpinned.tag("@" + version)) }
        if exactVersion(version) { return .pinned(version) }
        return .unpinned(Unpinned.range(version))
    }

    /// `pkg==1.2.3` or `pkg@1.2.3` is pinned.
    static func pythonPin(_ spec: String) -> MCPPinning {
        if let r = spec.range(of: "==") {
            let v = String(spec[r.upperBound...])
            return exactVersion(v) ? .pinned(v) : .unpinned(Unpinned.tag(v))
        }
        if let at = spec.lastIndex(of: "@"), !spec.contains("://") {
            let v = String(spec[spec.index(after: at)...])
            if v.lowercased() == "latest" { return .unpinned(Unpinned.tag("@latest")) }
            return exactVersion(v) ? .pinned(v) : .unpinned(Unpinned.tag(v))
        }
        if spec.contains(">") || spec.contains("<") || spec.contains("~=") { return .unpinned(Unpinned.someRange) }
        if spec.hasPrefix("git+") || spec.contains("://") {
            return spec.contains("@")
                ? .pinned(String(localized: "a commit or tag", bundle: .module, comment: "What an MCP package is pinned to when it is installed from a git repository at a commit or tag."))
                : .unpinned(Unpinned.defaultBranch)
        }
        if spec.hasPrefix(".") || spec.hasPrefix("/") { return .notApplicable }
        return .unpinned(Unpinned.noVersion)
    }

    /// A digest pins an image; a tag other than `latest` names one version; no tag means `latest`.
    static func imagePin(_ image: String) -> MCPPinning {
        if let at = image.range(of: "@sha256:") { return .pinned("sha256:" + image[at.upperBound...].prefix(12)) }
        let last = image.split(separator: "/").last.map(String.init) ?? image
        guard let colon = last.lastIndex(of: ":") else { return .unpinned(Unpinned.untaggedImage) }
        let tag = String(last[last.index(after: colon)...])
        if tag.lowercased() == "latest" || tag.isEmpty { return .unpinned(Unpinned.tag(":latest")) }
        return .pinned(tag)
    }

    static func exactVersion(_ v: String) -> Bool {
        let v = v.hasPrefix("v") ? String(v.dropFirst()) : v
        guard let first = v.first, first.isNumber else { return false }
        return v.allSatisfy { $0.isNumber || $0.isLetter || ".-+_".contains($0) } && !v.contains("x") && !v.contains("*")
    }

    /// Whether a lowercased command line holds `rm` as a word, whitespace, then a flag run of a–z letters holding both
    /// `r` and `f` (`rm -rf`, `rm -fr`, `rm -vrf`): what `\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r` matched, in
    /// one pass. That regex backtracked quadratically over a long flag run with no `f` (or no `r`).
    static func deletesRecursively(_ line: String) -> Bool {
        let s = Array(line.unicodeScalars)
        func isWord(_ u: Unicode.Scalar) -> Bool {
            let p = u.properties
            return p.isAlphabetic || p.numericType == .decimal || p.generalCategory == .connectorPunctuation
                || p.generalCategory == .nonspacingMark || p.generalCategory == .spacingMark || p.generalCategory == .enclosingMark
        }
        var i = 0
        while i + 1 < s.count {
            defer { i += 1 }
            guard s[i] == "r", s[i + 1] == "m", i == 0 || !isWord(s[i - 1]) else { continue }
            var j = i + 2
            while j < s.count, s[j].properties.isWhitespace { j += 1 }
            guard j > i + 2, j < s.count, s[j] == "-" else { continue }
            j += 1
            var sawR = false, sawF = false
            while j < s.count, ("a"..."z").contains(s[j]) {
                if s[j] == "r" { sawR = true } else if s[j] == "f" { sawF = true }
                j += 1
            }
            if sawR && sawF { return true }
        }
        return false
    }

    /// Download-and-run pipelines, privilege, destruction, shell strings.
    static func commandDangers(command: String, args: [String], line: String) -> [AIWarning] {
        var out: [AIWarning] = []
        let l = line.lowercased()
        let fetchers = ["curl", "wget", "invoke-webrequest", "iwr", "irm", "invoke-restmethod", "fetch "]
        let shells = ["sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "perl", "ruby", "iex", "invoke-expression", "pwsh", "powershell", "osascript"]
        let fetches = fetchers.contains { l.contains($0) }
        if fetches {
            // `curl … | sh`, `bash -c "$(curl …)"`, `sh <(curl …)`.
            let piped = l.components(separatedBy: "|").dropFirst().contains { part in
                let first = part.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                let name = (first as NSString).lastPathComponent
                return shells.contains(name) || (name == "sudo")
            }
            if piped || l.contains("$(curl") || l.contains("$(wget") || l.contains("<(curl") || l.contains("<(wget") || l.contains("`curl") {
                out.append(AIWarning(.danger, String(localized: "It downloads a script from the internet and runs it straight away (curl … | sh), so whoever controls that address controls this Mac.", bundle: .module, comment: "Warning on an MCP server. curl … | sh is a command and stays as written.")))
            }
        }
        if l.contains("base64") && (l.contains("-d") || l.contains("--decode")) && l.contains("|") {
            out.append(AIWarning(.danger, String(localized: "It decodes hidden base64 text and pipes it to another program, a common way to disguise what runs.", bundle: .module, comment: "Warning on an MCP server.")))
        }
        let base = (command as NSString).lastPathComponent.lowercased()
        if base == "sudo" || args.contains("sudo") {
            out.append(AIWarning(.danger, String(localized: "It runs with administrator rights (sudo).", bundle: .module, comment: "Warning on an MCP server. sudo is a command name.")))
        }
        if deletesRecursively(l) {
            out.append(AIWarning(.danger, String(localized: "It deletes files recursively (rm -rf).", bundle: .module, comment: "Warning on an MCP server. rm -rf is a command and stays as written.")))
        }
        if ["sh", "bash", "zsh", "dash", "fish", "cmd", "cmd.exe", "powershell", "pwsh"].contains(base),
           args.contains(where: { ["-c", "/c", "-command", "-encodedcommand", "-lc", "-ic"].contains($0.lowercased()) }) {
            out.append(AIWarning(.caution, String(localized: "It runs a shell command string, which can do anything the shell can.", bundle: .module, comment: "Warning on an MCP server.")))
        }
        if base == "docker" || base == "podman" {
            if args.contains("--privileged") {
                out.append(AIWarning(.danger, String(localized: "The container runs privileged, with full access to the host.", bundle: .module, comment: "Warning on an MCP server run with docker.")))
            }
            if args.contains(where: { $0.hasPrefix("/:") || $0 == "/var/run/docker.sock:/var/run/docker.sock" || $0.hasPrefix("/var/run/docker.sock") }) {
                out.append(AIWarning(.danger, String(localized: "The container mounts the whole disk or the Docker socket, which gives it control of the host.", bundle: .module, comment: "Warning on an MCP server run with docker.")))
            }
            if let i = args.firstIndex(of: "--network"), i + 1 < args.count, args[i + 1] == "host" {
                out.append(AIWarning(.caution, String(localized: "The container shares the host's network.", bundle: .module, comment: "Warning on an MCP server run with docker.")))
            }
        }
        return out
    }
}
