import Foundation

/// The Claude connector in the Claude app (X-9, G-22): one `vitrine` entry under `mcpServers` in the app's
/// `claude_desktop_config.json`, `{"command": "<Vitrine.app>/Contents/Helpers/vitrine", "args": ["mcp"]}`. Changing it
/// changes the person's Claude settings, so, as with ClaudeSessionHook, it is only ever their action: `planConnect`
/// and `planDisconnect` say exactly what would change and change nothing; `apply` writes that plan, refusing if the
/// file changed since it was shown. The file is edited as text, so every other setting keeps its exact form. No test
/// and no code path writes the real file. Source for the file's place and shape: the MCP quickstart for Claude
/// Desktop users (modelcontextprotocol.io), recalled and not fetched in this session. roadmap: S-11
public struct ClaudeAppConnector: Sendable {
    public static let serverName = "vitrine"

    public let configFile: URL
    /// The `vitrine` executable to register.
    public let command: String

    public init(command: String,
                configFile: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")) {
        self.command = command; self.configFile = configFile
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notJSONObject
        case unexpectedShape
        case changedSinceShown
        case noClaudeFolder

        public var errorDescription: String? {
            switch self {
            case .notJSONObject: String(localized: "The Claude app's settings file is not a JSON object, so Vitrine leaves it alone.", bundle: .previewKit, comment: "Error connecting Vitrine to the Claude app: its settings file is not a JSON object.")
            case .unexpectedShape: String(localized: "The Claude app's settings file is not in the shape Vitrine expects, so Vitrine leaves it alone.", bundle: .previewKit, comment: "Error connecting Vitrine to the Claude app: its mcpServers setting is not an object.")
            case .changedSinceShown: String(localized: "The Claude app's settings file changed after the change was shown. Nothing was written; look again.", bundle: .previewKit, comment: "Error connecting Vitrine to the Claude app: the file changed meanwhile.")
            case .noClaudeFolder: String(localized: "The Claude app's settings folder is not there. Open the Claude app once, then connect again.", bundle: .previewKit, comment: "Error connecting Vitrine to the Claude app: its Application Support folder does not exist.")
            }
        }
    }

    /// One change, shown before it is made.
    public struct Plan: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case connect, disconnect }
        public let action: Action
        public let file: URL
        public let original: String
        public let exists: Bool
        public let updated: String
        /// The text added or taken out, exactly.
        public let change: String
    }

    /// The entry as written into `mcpServers`.
    public var entry: String {
        let path = try! JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return "\"\(Self.serverName)\": {\"command\": \(String(decoding: path, as: UTF8.self)), \"args\": [\"mcp\"]}"
    }

    public func read() -> (text: String, exists: Bool) {
        guard let data = try? Data(contentsOf: configFile) else { return ("", false) }
        return (String(decoding: data, as: UTF8.self), true)
    }

    /// The command the Claude app would start for Vitrine; nil when it has no `vitrine` entry.
    public static func registeredCommand(in text: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any], let entry = servers[serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    public var registeredCommand: String? { Self.registeredCommand(in: read().text) }

    public func planConnect() throws -> Plan? {
        let (text, exists) = read()
        guard let updated = try connecting(text) else { return nil }
        return Plan(action: .connect, file: configFile, original: text, exists: exists, updated: updated, change: entry)
    }

    public func planDisconnect() throws -> Plan? {
        let (text, exists) = read()
        guard exists, let (updated, removed) = try Self.disconnecting(text) else { return nil }
        return Plan(action: .disconnect, file: configFile, original: text, exists: exists, updated: updated, change: removed)
    }

    /// The settings with Vitrine's entry for this `command`; nil when it is already exactly there. An entry for another
    /// copy of Vitrine (the app was moved) is replaced.
    public func connecting(_ original: String) throws -> String? {
        var base = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : original
        guard (try? JSONSerialization.jsonObject(with: Data(base.utf8))) is [String: Any] else { throw Failure.notJSONObject }
        if let current = Self.registeredCommand(in: base) {
            if current == command { return nil }
            guard let (without, _) = try Self.disconnecting(base) else { throw Failure.unexpectedShape }
            base = without
        }
        let j = JSONText(base)
        let unit = j.indentUnit
        let rootOpen = j.skipSpace(0)
        guard let root = j.members(rootOpen) else { throw Failure.notJSONObject }
        let out: String
        if let servers = root.members.first(where: { $0.key == "mcpServers" }) {
            guard let inner = j.members(servers.valueStart) else { throw Failure.unexpectedShape }
            let indent = j.lineIndent(servers.keyStart) + unit
            out = ClaudeSessionHook.insert(into: j, open: servers.valueStart, close: inner.close, lastEnd: inner.members.last?.valueEnd,
                                           item: entry, indent: indent, closeIndent: j.lineIndent(servers.keyStart))
        } else {
            let indent = j.lineIndent(rootOpen) + unit
            let member = "\"mcpServers\": {\n\(indent + unit)\(entry)\n\(indent)}"
            out = ClaudeSessionHook.insert(into: j, open: rootOpen, close: root.close, lastEnd: root.members.last?.valueEnd,
                                           item: member, indent: indent, closeIndent: j.lineIndent(rootOpen))
        }
        guard (try? JSONSerialization.jsonObject(with: Data(out.utf8))) is [String: Any], Self.registeredCommand(in: out) == command else {
            throw Failure.unexpectedShape
        }
        return out
    }

    /// The settings without Vitrine's entry (and without `mcpServers` when that leaves it empty), and the text taken
    /// out; nil when there is no entry.
    public static func disconnecting(_ original: String) throws -> (String, String)? {
        guard (try? JSONSerialization.jsonObject(with: Data(original.utf8))) is [String: Any] else { throw Failure.notJSONObject }
        let j = JSONText(original)
        guard let root = j.members(j.skipSpace(0)), let servers = root.members.first(where: { $0.key == "mcpServers" }),
              let inner = j.members(servers.valueStart), let m = inner.members.firstIndex(where: { $0.key == serverName }) else { return nil }
        let range: Range<Int>
        if inner.members.count > 1 {
            range = ClaudeSessionHook.memberRange(inner.members, m)
        } else if root.members.count > 1 {
            range = ClaudeSessionHook.memberRange(root.members, root.members.firstIndex { $0.key == "mcpServers" }!)
        } else {
            range = (j.skipSpace(0) + 1)..<root.close
        }
        let removed = j.text(range.lowerBound, range.upperBound)
        let text = j.text(0, range.lowerBound) + j.text(range.upperBound, j.bytes.count)
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any], registeredCommand(in: text) == nil else {
            throw Failure.unexpectedShape
        }
        return (text, removed)
    }

    /// Writes the plan, only if the file still holds exactly what the plan was made from; through a temporary file,
    /// keeping its permissions.
    public func apply(_ plan: Plan) throws {
        let (now, exists) = read()
        guard now == plan.original, exists == plan.exists else { throw Failure.changedSinceShown }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: plan.file.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.noClaudeFolder
        }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: plan.file.path))?[.posixPermissions]
        try Data(plan.updated.utf8).write(to: plan.file, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: plan.file.path) }
    }
}
