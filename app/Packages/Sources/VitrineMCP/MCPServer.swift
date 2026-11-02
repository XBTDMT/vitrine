import Foundation

// The Claude connector's protocol (X-9, G-22): MCP over stdio, newline-delimited JSON-RPC 2.0. Written after the same
// author's Kage server (KageMCP), which serves both protocol eras: a legacy client opens with `initialize`; a 2026-07-28
// client sends no handshake, probes with `server/discover` and names its version in each request's `_meta`, and gets
// `resultType` on every result. Vitrine adds image answers (a rendered preview). roadmap: S-11

/// One piece of a tool's answer.
public enum MCPContent: Sendable, Equatable {
    case text(String)
    /// PNG bytes; sent base64 with their MIME type.
    case image(Data)
}

/// A tool's answer: content, or an error the client shows as a failed call.
public enum MCPResult: Sendable, Equatable {
    case content([MCPContent])
    case error(String)
}

/// What answers `tools/call`. Arguments are the call's JSON object.
public protocol MCPBackend: Sendable {
    func call(_ tool: String, _ arguments: [String: Any]) async -> MCPResult
}

/// One tool: its name, what it does, and its JSON Schema for arguments.
public struct MCPTool: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    /// MCP's tool annotations (read-only, never destructive, works offline).
    public let annotations: [String: Any]
    public init(name: String, description: String, inputSchema: [String: Any], annotations: [String: Any] = [:]) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations
    }
}

/// Immutable after init, so safe to share. Every text answer passes through `wrapper`, which marks it as untrusted
/// data: a file's words reach Claude as content, never as instructions.
public final class MCPServer: @unchecked Sendable {
    /// The handshake versions this server speaks, newest first; a client asking for another gets the newest.
    public static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// The handshake-free versions: a request naming one of these in `_meta` is served without `initialize`.
    public static let modernVersions = ["2026-07-28"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"

    let name: String, version: String
    let instructions: String?
    let tools: [MCPTool]
    let backend: MCPBackend
    let wrapper: @Sendable (String) -> String

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool], backend: MCPBackend,
                wrapper: @escaping @Sendable (String) -> String) {
        self.name = name; self.version = version; self.instructions = instructions
        self.tools = tools; self.backend = backend; self.wrapper = wrapper
    }

    /// One line in, at most one line out (nil for a notification).
    public func handle(_ line: Data) async -> Data? {
        guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return reply(id: NSNull(), error: (-32700, "Parse error"))
        }
        guard let method = msg["method"] as? String else { return nil }
        guard let id = msg["id"], !(id is NSNull) else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        // A modern request names its version; an unknown one is refused with the list (-32022), never guessed.
        let asked = (params["_meta"] as? [String: Any])?[Self.versionKey] as? String
        if let asked, !Self.modernVersions.contains(asked) {
            return reply(id: id, error: (-32022, "Unsupported protocol version"),
                         data: ["supported": Self.modernVersions + Self.versions, "requested": asked])
        }
        let modern = asked != nil
        func complete(_ r: [String: Any]) -> [String: Any] {
            guard modern else { return r }
            var r = r
            r["resultType"] = "complete"
            r["_meta"] = ["io.modelcontextprotocol/serverInfo": ["name": name, "version": version]]
            return r
        }
        switch method {
        case "server/discover":
            var result: [String: Any] = [
                "resultType": "complete",
                "supportedVersions": Self.modernVersions,
                "capabilities": ["tools": ["listChanged": false]],
                "_meta": ["io.modelcontextprotocol/serverInfo": ["name": name, "version": version]],
            ]
            if let instructions { result["instructions"] = instructions }
            return reply(id: id, result: result)
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            var result: [String: Any] = [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "version": version],
            ]
            if let instructions { result["instructions"] = instructions }
            return reply(id: id, result: result)
        case "ping":
            return reply(id: id, result: [:])
        case "tools/list":
            var list: [String: Any] = ["tools": tools.map { tool -> [String: Any] in
                var entry: [String: Any] = ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema]
                if !tool.annotations.isEmpty { entry["annotations"] = tool.annotations }
                return entry
            }]
            // The tools never change while the server runs, and they are the same for every client.
            if modern { list["ttlMs"] = 300_000; list["cacheScope"] = "public" }
            return reply(id: id, result: complete(list))
        case "tools/call":
            guard let tool = params["name"] as? String else { return reply(id: id, error: (-32602, "Invalid params")) }
            guard tools.contains(where: { $0.name == tool }) else { return reply(id: id, error: (-32602, "Unknown tool: \(tool)")) }
            let (parts, isError): ([MCPContent], Bool) = switch await backend.call(tool, params["arguments"] as? [String: Any] ?? [:]) {
            case .content(let parts): (parts, false)
            // A failed call's sentence can carry text from the file (its name, a part name, a parser's message), so it
            // takes the same path as content: there is no way to send text that skips the wrapper (S-16 F22).
            case .error(let sentence): ([.text(sentence)], true)
            }
            return reply(id: id, result: complete(["content": parts.map(encode), "isError": isError]))
        default:
            return reply(id: id, error: (-32601, "Method not found"))
        }
    }

    /// The one place a tool's answer becomes JSON: every text part, a failed call's included, goes through `wrapper`.
    func encode(_ part: MCPContent) -> [String: Any] {
        switch part {
        case .text(let t): ["type": "text", "text": wrapper(t)]
        case .image(let png): ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]
        }
    }

    func reply(id: Any, result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.withoutEscapingSlashes])
    }

    func reply(id: Any, error: (Int, String), data: [String: Any]? = nil) -> Data? {
        var e: [String: Any] = ["code": error.0, "message": error.1]
        if let data { e["data"] = data }
        return try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": e])
    }

    /// Reads requests from stdin, one per line, and writes each reply as one line to stdout, until stdin closes.
    public func serve() async {
        await serve(input: .standardInput, output: .standardOutput)
    }

    /// The same over any pair of handles. `availableData` returns as soon as any bytes arrive (a client keeps the pipe
    /// open and waits for each answer; Kage measured that reading a fixed block waits forever).
    public func serve(input: FileHandle, output: FileHandle) async {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }), let out = await handle(Data(line)) else { continue }
                output.write(out + Data([0x0A]))
            }
        }
    }
}
