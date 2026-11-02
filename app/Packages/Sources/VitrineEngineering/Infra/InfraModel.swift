import Foundation

/// One line of an infrastructure card's facts table: a stable `id` the card can key a translation on, an English
/// `label`, and the value as display text. Facts never carry a secret's value. roadmap: S-22
public struct InfraFact: Sendable, Equatable {
    /// Stable key such as `terraformVersion` or `services`; never shown.
    public var id: String
    /// English label, for a card that has no translation of its own for `id`.
    public var label: String
    public var value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Something in an infrastructure file worth a reader's attention, with a plain-English reason. `code` is stable, so
/// a card can localise or group by it; `subject` names what it is about (a service, job, container, stage, host),
/// never a secret's value. roadmap: S-22
public struct InfraWarning: Sendable, Equatable {
    /// How serious the finding is. roadmap: S-22
    public enum Level: String, Sendable, Equatable, Comparable {
        case caution, danger

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs == .caution && rhs == .danger }
    }

    /// What kind of finding it is. roadmap: S-22
    public enum Code: String, Sendable, Equatable {
        // Terraform state
        case secretsInState, unknownStateVersion
        // Containers (Compose, Kubernetes)
        case privileged, hostNetwork, hostNamespace, dockerSocket, dangerousCapability, hostPath, runsAsRoot
        case unpinnedImage, inlineSecretEnvironment, missingDependency, dependencyCycle
        // GitHub Actions
        case permissionsNotSet, permissionsWriteAll, pullRequestTargetCheckout, unpinnedAction
        // Dockerfile
        case rootUser, remoteAdd, pipeToShell
        // HAR
        case authorizationHeaders, cookies
    }

    public var level: Level
    public var code: Code
    /// English, one sentence, plain words.
    public var reason: String
    public var subject: String?

    public init(_ level: Level, _ code: Code, _ reason: String, subject: String? = nil) {
        self.level = level
        self.code = code
        self.reason = reason
        self.subject = subject
    }
}

/// A name with how many times it was seen (hosts, kinds, secret-looking attribute names, cookie names).
/// roadmap: S-22
public struct InfraNameCount: Sendable, Equatable {
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// A dependency graph (Compose `depends_on`, Actions `needs`): nodes in file order, edges from the dependent to what
/// it waits for. roadmap: S-22
public struct InfraGraph: Sendable, Equatable {
    /// One `from` waits for `to`. roadmap: S-22
    public struct Edge: Sendable, Equatable {
        public var from: String
        public var to: String
        /// Compose's `condition` (`service_healthy` …) when given.
        public var label: String?

        public init(from: String, to: String, label: String? = nil) {
            self.from = from
            self.to = to
            self.label = label
        }
    }

    public var nodes: [String]
    public var edges: [Edge]
    /// Edge targets that are not nodes (a `needs` or `depends_on` naming something the file does not define).
    public var missing: [String]
    /// The edges contain a loop, so the graph has no order to run in.
    public var hasCycle: Bool

    public init(nodes: [String], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
        let known = Set(nodes)
        var seen: Set<String> = []
        missing = edges.compactMap { known.contains($0.to) || !seen.insert($0.to).inserted ? nil : $0.to }
        hasCycle = Self.cycle(nodes: nodes, edges: edges.filter { known.contains($0.to) && known.contains($0.from) })
    }

    /// Kahn's algorithm: a loop leaves nodes that never reach in-degree zero. No recursion.
    private static func cycle(nodes: [String], edges: [Edge]) -> Bool {
        var indegree: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        for n in nodes { indegree[n, default: 0] += 0 }
        for e in edges {
            indegree[e.from, default: 0] += 1          // `from` waits for `to`: to must come first
            outgoing[e.to, default: []].append(e.from)
        }
        var ready = indegree.filter { $0.value == 0 }.map(\.key)
        var done = 0
        while let n = ready.popLast() {
            done += 1
            for next in outgoing[n] ?? [] {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 { ready.append(next) }
            }
        }
        return done < indegree.count
    }
}

/// A container image reference as written (`harbor.example:5000/acme/notes:1.4`, `nginx`, `app@sha256:…`), split
/// into what a card shows: the tag, whether a digest pins it, and whether it floats (`:latest` or no tag).
/// roadmap: S-22
public struct InfraImage: Sendable, Equatable {
    public var reference: String
    /// The tag when one is written, without the colon.
    public var tag: String?
    /// An `@sha256:` (or other algorithm) digest pins the exact image.
    public var pinnedByDigest: Bool
    /// The reference uses a variable (`${TAG}`, `$BASE`), so what it resolves to is not in the file.
    public var usesVariable: Bool

    public init(_ reference: String) {
        self.reference = reference
        usesVariable = reference.contains("$")
        var rest = Substring(reference)
        if let at = rest.firstIndex(of: "@") {
            pinnedByDigest = rest[rest.index(after: at)...].contains(":")
            rest = rest[..<at]
        } else {
            pinnedByDigest = false
        }
        let lastSegment = rest.split(separator: "/", omittingEmptySubsequences: false).last ?? rest
        if let colon = lastSegment.lastIndex(of: ":") {
            let t = lastSegment[lastSegment.index(after: colon)...]
            tag = t.isEmpty ? nil : String(t)
        } else {
            tag = nil
        }
    }

    /// No digest and either no tag or `latest`: the image can change under the same name.
    public var floats: Bool { !pinnedByDigest && !usesVariable && (tag == nil || tag == "latest") }
}

/// A list that keeps at most `InfraReader.maxItems` items and counts the rest.
struct Capped<Element> {
    var items: [Element] = []
    var total = 0
    var truncated = false

    mutating func append(_ item: Element) {
        total += 1
        if items.count < InfraReader.maxItems { items.append(item) } else { truncated = true }
    }
}

/// Counts names, keeping first-seen order and at most `InfraReader.maxItems` distinct names.
struct NameCounter {
    private var order: [String] = []
    private var counts: [String: Int] = [:]
    var truncated = false
    var total = 0

    mutating func add(_ name: String, _ n: Int = 1) {
        total += n
        if counts[name] != nil { counts[name]! += n; return }
        guard order.count < InfraReader.maxItems else { truncated = true; return }
        order.append(name)
        counts[name] = n
    }

    /// Most first; ties keep first-seen order.
    var sorted: [InfraNameCount] {
        order.enumerated().sorted { a, b in
            let ca = counts[a.element]!, cb = counts[b.element]!
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map { InfraNameCount(name: $0.element, count: counts[$0.element]!) }
    }

    var inOrder: [InfraNameCount] { order.map { InfraNameCount(name: $0, count: counts[$0]!) } }
    var isEmpty: Bool { order.isEmpty }
}

/// Collects warnings, one per code and subject, at most `InfraReader.maxItems` of them.
struct WarningList {
    var items: [InfraWarning] = []
    var truncated = false
    private var seen: Set<String> = []

    mutating func add(_ level: InfraWarning.Level, _ code: InfraWarning.Code, _ reason: String, subject: String? = nil) {
        guard seen.insert("\(code.rawValue)\u{1F}\(subject ?? "")").inserted else { return }
        guard items.count < InfraReader.maxItems else { truncated = true; return }
        items.append(InfraWarning(level, code, reason, subject: subject))
    }

    /// Danger first, then file order.
    var sorted: [InfraWarning] {
        items.enumerated().sorted { a, b in
            a.element.level != b.element.level ? a.element.level > b.element.level : a.offset < b.offset
        }.map(\.element)
    }
}
