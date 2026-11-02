import Foundation

/// A chat export's `conversations.json` (A-10), from ChatGPT (each conversation a `mapping` tree of message nodes) or
/// from Claude (each conversation a `chat_messages` list): how many conversations, over which dates, with which
/// models, and per conversation its main path of messages. roadmap: S-21
public struct ChatExportSummary: Sendable, Equatable {
    /// Which service wrote the export. roadmap: S-21
    public enum Source: String, Sendable, Equatable {
        case chatGPT
        case claude

        public var title: String {
            self == .chatGPT ? String(localized: "ChatGPT export", bundle: .module, comment: "Chat export source name.")
                : String(localized: "Claude export", bundle: .module, comment: "Chat export source name.")
        }
    }

    /// One message on a conversation's main path. roadmap: S-21
    public struct Message: Sendable, Equatable {
        /// user, assistant, system or tool (Claude's "human" is shown as user).
        public var role: String
        /// The message's text, at most `ChatExportSummary.maxMessageCharacters`; non-text parts appear as
        /// "[image]", "[tool use: name]", "[2 attachments]".
        public var text: String
        public var isTruncated: Bool
        public var created: Date?

        public init(role: String, text: String, isTruncated: Bool, created: Date?) {
            self.role = role
            self.text = text
            self.isTruncated = isTruncated
            self.created = created
        }
    }

    /// One conversation. roadmap: S-21
    public struct Conversation: Sendable, Equatable {
        public var id: String?
        public var title: String
        public var created: Date?
        public var updated: Date?
        /// Model slugs the conversation names, first seen first (ChatGPT's per-message `model_slug` and default slug;
        /// a Claude export's `model` when it has one).
        public var models: [String]
        /// Messages from people, the assistant and tools (hidden system nodes are not counted).
        public var messageCount: Int
        /// Nodes with more than one child: places where a message was edited or a reply regenerated.
        public var branchCount: Int
        /// The current path from the first message to the last one shown, at most `maxPathMessages` messages.
        public var mainPath: [Message]
        /// Messages on the full main path, shown or not.
        public var mainPathLength: Int
        /// The path was not read, because the conversation lies past the first `maxDetailedConversations`.
        public var mainPathOmitted: Bool

        public init(id: String?, title: String, created: Date?, updated: Date?, models: [String], messageCount: Int,
                    branchCount: Int, mainPath: [Message], mainPathLength: Int, mainPathOmitted: Bool) {
            self.id = id
            self.title = title
            self.created = created
            self.updated = updated
            self.models = models
            self.messageCount = messageCount
            self.branchCount = branchCount
            self.mainPath = mainPath
            self.mainPathLength = mainPathLength
            self.mainPathOmitted = mainPathOmitted
        }
    }

    public var source: Source
    public var headline: String
    /// Every conversation counted in the bytes read, listed or not.
    public var conversationCount: Int
    /// The whole array was read; false when the file was cut or damaged.
    public var conversationCountIsExact: Bool
    /// The earliest creation time and the latest update time across every counted conversation.
    public var earliest: Date?
    public var latest: Date?
    public var totalMessages: Int
    /// Model slug → conversations naming it.
    public var models: [String: Int]
    /// The first `maxListedConversations` conversations in file order.
    public var conversations: [Conversation]
    public var conversationsTruncated: Bool
    /// One row per listed conversation: title, created, updated, messages, branches, models.
    public var table: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public static let maxListedConversations = 1_000
    public static let maxDetailedConversations = 100
    public static let maxPathMessages = 100
    public static let maxMessageCharacters = 1_000

    public init(source: Source, headline: String, conversationCount: Int, conversationCountIsExact: Bool,
                earliest: Date?, latest: Date?, totalMessages: Int, models: [String: Int],
                conversations: [Conversation], conversationsTruncated: Bool, table: AIDataTable, facts: [AIDataFact],
                warnings: [AIDataWarning]) {
        self.source = source
        self.headline = headline
        self.conversationCount = conversationCount
        self.conversationCountIsExact = conversationCountIsExact
        self.earliest = earliest
        self.latest = latest
        self.totalMessages = totalMessages
        self.models = models
        self.conversations = conversations
        self.conversationsTruncated = conversationsTruncated
        self.table = table
        self.facts = facts
        self.warnings = warnings
    }
}

enum AIChatExportReader {
    /// The most nodes walked in one ChatGPT mapping.
    static let maxNodes = 20_000

    static func read(_ bytes: [UInt8], context: AIReadContext) -> ChatExportSummary? {
        var source: ChatExportSummary.Source?
        var conversations: [ChatExportSummary.Conversation] = []
        var count = 0, messages = 0
        var earliest: Date?, latest: Date?
        var models: [String: Int] = [:]

        let stream = AIJSONParser.forEachElement(bytes, limits: .conversation, maxBuilt: .max) { element, index in
            if source == nil {
                if element["mapping"]?.isObject == true { source = .chatGPT }
                else if element["chat_messages"]?.array != nil { source = .claude }
                else { return false }
            }
            guard let source, element.isObject else { return true }
            let detail = index < ChatExportSummary.maxDetailedConversations
            let conversation = source == .chatGPT ? chatGPT(element, detail: detail) : claude(element, detail: detail)
            count += 1
            messages += conversation.messageCount
            for date in [conversation.created, conversation.updated].compactMap({ $0 }) {
                earliest = min(earliest ?? date, date)
                latest = max(latest ?? date, date)
            }
            for model in conversation.models where models.count < 500 || models[model] != nil { models[model, default: 0] += 1 }
            if conversations.count < ChatExportSummary.maxListedConversations { conversations.append(conversation) }
            return true
        }
        guard let source else { return nil }

        let exact = stream.complete && !context.wasCut
        var warnings: [AIDataWarning] = []
        if context.wasCut {
            let megabytes = AIDataReader.maxBytes / (1024 * 1024)
            warnings.append(AIDataWarning(.caution, String(localized: "Only the first \(megabytes) MB of this export were read; the counts cover the \(count) conversations in that part.", bundle: .module, comment: "Chat export warning. The arguments are a size in megabytes and a conversation count.")))
        } else if !stream.complete {
            if let offset = stream.failure?.offset {
                warnings.append(AIDataWarning(.caution, String(localized: "The export is damaged at byte \(offset); the counts cover the \(count) conversations before it.", bundle: .module, comment: "Chat export warning. The arguments are a byte offset and a conversation count.")))
            } else {
                warnings.append(AIDataWarning(.caution, String(localized: "The export ends before its last conversation is complete; the counts cover the \(count) conversations before it.", bundle: .module, comment: "Chat export warning. The argument is a conversation count.")))
            }
        }
        if stream.budgetHit {
            warnings.append(AIDataWarning(.caution, String(localized: "A conversation is too large to read whole; its figures cover its first part.", bundle: .module, comment: "Chat export warning.")))
        }

        var facts: [AIDataFact] = [
            AIDataFact(String(localized: "Source", bundle: .module, comment: "Fact label: which service wrote a chat export."), source.title),
            AIDataFact(String(localized: "Conversations", bundle: .module, comment: "Fact label."), count.formatted() + (exact ? "" : "+")),
            AIDataFact(String(localized: "Messages", bundle: .module, comment: "Fact label: chat messages."), messages.formatted()),
        ]
        if let earliest, let latest {
            facts.append(AIDataFact(String(localized: "Dates", bundle: .module, comment: "Fact label: the date range of a chat export."), AIText.date(earliest) + " – " + AIText.date(latest)))
        }
        if !models.isEmpty { facts.append(AIDataFact(String(localized: "Models", bundle: .module, comment: "Fact label: model names and how often each appears."), AIText.counted(models))) }
        let branches = conversations.reduce(0) { $0 + $1.branchCount }
        if branches > 0 { facts.append(AIDataFact(String(localized: "Branch points", bundle: .module, comment: "Fact label: places in chats where a message was edited or a reply regenerated."), branches.formatted())) }

        let rows = conversations.prefix(AIDataTable.maxRows).map { c in
            [AIText.cap(c.title), c.created.map(AIText.date) ?? "", c.updated.map(AIText.date) ?? "",
             c.messageCount.formatted(), c.branchCount.formatted(), AIText.cap(c.models.joined(separator: ", "))]
        }
        let table = AIDataTable(columns: [String(localized: "Title", bundle: .module, comment: "Table column."),
                                          String(localized: "Created", bundle: .module, comment: "Table column."),
                                          String(localized: "Updated", bundle: .module, comment: "Table column."),
                                          String(localized: "Messages", bundle: .module, comment: "Table column."),
                                          String(localized: "Branches", bundle: .module, comment: "Table column: branch points in a chat."),
                                          String(localized: "Models", bundle: .module, comment: "Table column.")],
                                rows: Array(rows), totalRows: count, isTruncated: count > rows.count || !exact)
        let sourceTitle = source.title
        let headline = exact
            ? String(localized: "\(sourceTitle) · \(count) conversations", bundle: .module, comment: "Chat export headline. The arguments are the source name and a conversation count.")
            : String(localized: "\(sourceTitle) · \(count)+ conversations", bundle: .module, comment: "Chat export headline when the file was not read whole. The arguments are the source name and the conversations counted so far.")
        return ChatExportSummary(source: source, headline: headline, conversationCount: count,
                                 conversationCountIsExact: exact, earliest: earliest, latest: latest,
                                 totalMessages: messages, models: models, conversations: conversations,
                                 conversationsTruncated: count > conversations.count, table: table, facts: facts,
                                 warnings: warnings)
    }

    // MARK: ChatGPT

    private struct Node {
        var parent: String?
        var children: [String]
        var message: AIJSON?
    }

    static func chatGPT(_ c: AIJSON, detail: Bool) -> ChatExportSummary.Conversation {
        var nodes: [String: Node] = [:]
        var order: [String] = []
        for member in (c["mapping"]?.members ?? []).prefix(maxNodes) {
            let node = member.value
            let children = (node["children"]?.array ?? []).compactMap(\.string)
            nodes[member.key] = Node(parent: node["parent"]?.string, children: children,
                                     message: node["message"].flatMap { $0.isObject ? $0 : nil })
            order.append(member.key)
        }
        var models: [String] = []
        if let slug = c["default_model_slug"]?.text { models.append(slug) }
        var messageCount = 0
        var branchCount = 0
        for id in order {
            guard let node = nodes[id] else { continue }
            if node.children.count > 1 { branchCount += 1 }
            guard let message = node.message else { continue }
            if let slug = message.at("metadata", "model_slug")?.text { models.append(slug) }
            let role = message.at("author", "role")?.string ?? ""
            if role != "system", !isHidden(message) { messageCount += 1 }
        }

        var path: [ChatExportSummary.Message] = []
        var pathLength = 0
        if detail {
            // The current node back to the root, then reversed; without a current node, the root's last children.
            var chain: [String] = []
            var visited = Set<String>()
            if var cursor = c["current_node"]?.string, nodes[cursor] != nil {
                while visited.insert(cursor).inserted, chain.count < maxNodes {
                    chain.append(cursor)
                    guard let parent = nodes[cursor]?.parent, nodes[parent] != nil else { break }
                    cursor = parent
                }
                chain.reverse()
            } else if var cursor = order.first(where: { id in nodes[id]?.parent.map { nodes[$0] == nil } ?? true }) {
                while visited.insert(cursor).inserted, chain.count < maxNodes {
                    chain.append(cursor)
                    guard let next = nodes[cursor]?.children.last, nodes[next] != nil else { break }
                    cursor = next
                }
            }
            for id in chain {
                guard let message = nodes[id]?.message, !isHidden(message) else { continue }
                let role = message.at("author", "role")?.string ?? "unknown"
                let text = chatGPTText(message)
                if role == "system", text.isEmpty { continue }
                pathLength += 1
                if path.count < ChatExportSummary.maxPathMessages {
                    path.append(capped(role: role, text: text, created: AIDates.date(message["create_time"])))
                }
            }
        }
        return ChatExportSummary.Conversation(
            id: c["conversation_id"]?.text ?? c["id"]?.text, title: c["title"]?.text ?? untitled,
            created: AIDates.date(c["create_time"]), updated: AIDates.date(c["update_time"]),
            models: AIText.unique(models), messageCount: messageCount, branchCount: branchCount, mainPath: path,
            mainPathLength: pathLength, mainPathOmitted: !detail)
    }

    private static func isHidden(_ message: AIJSON) -> Bool {
        message.at("metadata", "is_visually_hidden_from_conversation")?.bool == true
    }

    /// The text of a ChatGPT message whatever its content type.
    static func chatGPTText(_ message: AIJSON) -> String {
        guard let content = message["content"] else { return "" }
        var pieces: [String] = []
        if let parts = content["parts"]?.array {
            for part in parts.prefix(200) {
                if let s = part.string {
                    if !s.isEmpty { pieces.append(s) }
                } else if let type = part["content_type"]?.string {
                    pieces.append(type.contains("image") ? imageMarker : type.contains("audio") ? audioMarker : "[\(type)]")
                } else if let s = part["text"]?.string {
                    pieces.append(s)
                }
            }
        }
        if pieces.isEmpty, let text = content["text"]?.text { pieces.append(text) }
        if pieces.isEmpty, let result = content["result"]?.text { pieces.append(result) }
        if pieces.isEmpty, let thoughts = content["thoughts"]?.array {
            pieces += thoughts.prefix(50).compactMap { $0["content"]?.text }
        }
        if pieces.isEmpty, let inner = content["content"]?.text { pieces.append(inner) }
        return pieces.joined(separator: "\n")
    }

    // MARK: Claude

    static func claude(_ c: AIJSON, detail: Bool) -> ChatExportSummary.Conversation {
        let messages = Array((c["chat_messages"]?.array ?? []).prefix(maxNodes))
        var models: [String] = []
        if let model = c["model"]?.text { models.append(model) }
        for m in messages { if let model = m["model"]?.text { models.append(model) } }

        // Newer exports link each message to its parent; branches are parents with more than one child.
        var byID: [String: Int] = [:]
        var children: [String: Int] = [:]
        for (index, m) in messages.enumerated() {
            if let id = m["uuid"]?.string { byID[id] = index }
            if let parent = m["parent_message_uuid"]?.string { children[parent, default: 0] += 1 }
        }
        let branchCount = children.values.filter { $0 > 1 }.count

        var path: [ChatExportSummary.Message] = []
        var pathLength = 0
        if detail {
            var chain: [Int] = []
            if branchCount > 0, let leaf = c["current_leaf_message_uuid"]?.string, var cursor = byID[leaf] {
                var visited = Set<Int>()
                while visited.insert(cursor).inserted {
                    chain.append(cursor)
                    guard let parent = messages[cursor]["parent_message_uuid"]?.string, let next = byID[parent] else { break }
                    cursor = next
                }
                chain.reverse()
            } else {
                chain = Array(messages.indices)
            }
            for index in chain {
                let m = messages[index]
                let sender = m["sender"]?.string ?? m["role"]?.string ?? "unknown"
                pathLength += 1
                if path.count < ChatExportSummary.maxPathMessages {
                    path.append(capped(role: sender == "human" ? "user" : sender, text: claudeText(m),
                                       created: AIDates.date(m["created_at"])))
                }
            }
        }
        return ChatExportSummary.Conversation(
            id: c["uuid"]?.text, title: c["name"]?.text ?? untitled, created: AIDates.date(c["created_at"]),
            updated: AIDates.date(c["updated_at"]), models: AIText.unique(models), messageCount: messages.count,
            branchCount: branchCount, mainPath: path, mainPathLength: pathLength, mainPathOmitted: !detail)
    }

    static func claudeText(_ m: AIJSON) -> String {
        var pieces: [String] = []
        if let blocks = m["content"]?.array, !blocks.isEmpty {
            for block in blocks.prefix(200) {
                switch block["type"]?.string {
                case "text": if let t = block["text"]?.text { pieces.append(t) }
                case "tool_use":
                    let tool = block["name"]?.string ?? "?"
                    pieces.append(String(localized: "[tool use: \(tool)]", bundle: .module, comment: "Stands for a tool call inside a chat message. The argument is the tool's name."))
                case "tool_result": pieces.append(String(localized: "[tool result]", bundle: .module, comment: "Stands for a tool result inside a chat message."))
                case "image": pieces.append(imageMarker)
                default: break
                }
            }
        }
        if pieces.isEmpty, let text = m["text"]?.text { pieces.append(text) }
        let attached = (m["attachments"]?.array?.count ?? 0) + (m["files"]?.array?.count ?? 0)
        if attached > 0 { pieces.append(String(localized: "[\(attached) attachments]", bundle: .module, comment: "Stands for files attached to a chat message. The argument is a count.")) }
        return pieces.joined(separator: "\n")
    }

    static var imageMarker: String { String(localized: "[image]", bundle: .module, comment: "Stands for an image inside a chat message.") }
    static var audioMarker: String { String(localized: "[audio]", bundle: .module, comment: "Stands for audio inside a chat message.") }
    static var untitled: String { String(localized: "Untitled", bundle: .module, comment: "Title of a conversation that has none.") }

    private static func capped(role: String, text: String, created: Date?) -> ChatExportSummary.Message {
        let limit = ChatExportSummary.maxMessageCharacters
        let cut = text.count > limit
        return ChatExportSummary.Message(role: role, text: cut ? AIText.cap(text, limit, oneLine: false) : text,
                                         isTruncated: cut, created: created)
    }
}
