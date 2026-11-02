import Foundation

/// A GitHub Actions `permissions:` block, top level or per job. roadmap: S-22
public enum WorkflowPermissions: Sendable, Equatable {
    /// No `permissions:` key: the token gets the repository's default, which can be write access to everything.
    case notSet
    case readAll
    case writeAll
    /// `permissions: {}`: no permissions at all.
    case none
    /// Scope → access (`contents: read`, `id-token: write`), in file order.
    case scoped([Scope])

    /// One scope of a permissions block. roadmap: S-22
    public struct Scope: Sendable, Equatable {
        public var name: String
        /// `read`, `write` or `none`.
        public var access: String

        public init(name: String, access: String) {
            self.name = name
            self.access = access
        }
    }

    /// Short display text: "not set" and "none" localised; "read-all", "write-all" and scopes as GitHub writes them.
    public var display: String {
        switch self {
        case .notSet: String(localized: "not set", bundle: .module, comment: "GitHub Actions permissions shown on the infra card: the workflow has no permissions key.")
        case .readAll: "read-all"
        case .writeAll: "write-all"
        case .none: String(localized: "none", bundle: .module, comment: "GitHub Actions permissions shown on the infra card: permissions: {} (no permissions at all).")
        case .scoped(let scopes): scopes.map { "\($0.name): \($0.access)" }.joined(separator: ", ")
        }
    }
}

/// What a GitHub Actions workflow (`.github/workflows/*.yml`) runs: its triggers, jobs with their `needs` graph,
/// runners and step counts, every action it uses and whether that use is pinned to a full commit SHA, and its token
/// permissions, with warnings for missing or write-all permissions and for `pull_request_target` workflows that
/// check out the pull request's code. roadmap: S-22
public struct WorkflowSummary: Sendable, Equatable {
    /// How firmly a `uses:` reference is pinned. roadmap: S-22
    public enum Pinning: String, Sendable, Equatable {
        /// `owner/repo@<40-hex commit SHA>`, or a `docker://` image with a digest.
        case pinned
        /// A tag or branch (`@v4`, `@main`), no ref, or a `docker://` image without a digest.
        case unpinned
        /// `./path` in the same repository.
        case local
        /// `docker://image:tag` without a digest.
        case docker
    }

    /// One `uses:` (a step's action, or a job's reusable workflow). roadmap: S-22
    public struct Use: Sendable, Equatable {
        public var job: String
        /// The step's position in its job (0-based); nil for a job-level reusable workflow.
        public var step: Int?
        public var reference: String
        public var pinning: Pinning

        public init(job: String, step: Int?, reference: String, pinning: Pinning) {
            self.job = job
            self.step = step
            self.reference = reference
            self.pinning = pinning
        }
    }

    /// One job. roadmap: S-22
    public struct Job: Sendable, Equatable {
        public var id: String
        public var name: String?
        /// `ubuntu-latest`, `[self-hosted, linux]` joined with ", ", or a runner group; nil for a reusable-workflow call.
        public var runsOn: String?
        public var needs: [String]
        public var steps: Int
        /// The reusable workflow the job calls, when it is one.
        public var uses: String?
        public var permissions: WorkflowPermissions
        /// The job has a `strategy.matrix`.
        public var matrix: Bool

        public init(id: String, name: String?, runsOn: String?, needs: [String], steps: Int, uses: String?,
                    permissions: WorkflowPermissions, matrix: Bool) {
            self.id = id; self.name = name; self.runsOn = runsOn; self.needs = needs; self.steps = steps
            self.uses = uses; self.permissions = permissions; self.matrix = matrix
        }
    }

    public var name: String?
    /// Event names in file order (`push`, `pull_request`, `workflow_dispatch`, `schedule` …).
    public var triggers: [String]
    public var jobs: [Job]
    public var totalJobs: Int
    /// Jobs as nodes, `needs` as edges.
    public var graph: InfraGraph
    public var uses: [Use]
    public var totalUses: Int
    public var permissions: WorkflowPermissions
    public var headline: String
    public var facts: [InfraFact]
    public var warnings: [InfraWarning]
    public var truncated: Bool
}

enum WorkflowReader {
    static func read(_ parsed: InfraParse.Result, capped: Bool) -> WorkflowSummary? {
        guard let root = parsed.roots.first, root.isObject, let jobsNode = root["jobs"], jobsNode.isObject else { return nil }
        // YAML 1.1 readers turn a bare `on` key into `true`; VitrineData keeps it as written, but accept both.
        let on = root["on"] ?? root["true"]
        var truncated = capped || !parsed.complete

        var triggers: [String] = []
        if let on {
            if let s = on.text { triggers = [s] } else if on.isArray { triggers = on.items.compactMap(\.text) } else { triggers = on.entries.map(\.key) }
        }
        if triggers.count > 200 { triggers = Array(triggers.prefix(200)); truncated = true }

        let topPermissions = permissions(root["permissions"])
        var jobs = Capped<WorkflowSummary.Job>()
        var uses = Capped<WorkflowSummary.Use>()
        var edges: [InfraGraph.Edge] = []
        var warnings = WarningList()
        var jobsWithoutPermissions: [String] = []
        var checksOutPullRequestHead: [String] = []

        for (id, j) in jobsNode.entries where j.isObject {
            let needs = j["needs"]?.stringList ?? []
            for need in needs.prefix(200) {
                if edges.count < InfraReader.maxItems { edges.append(.init(from: id, to: need)) } else { truncated = true }
            }
            let steps = j["steps"]?.items ?? []
            let jobUses = j["uses"]?.text
            if let jobUses { uses.append(.init(job: id, step: nil, reference: InfraText.cut(jobUses, 300), pinning: pinning(jobUses))) }
            for (k, step) in steps.enumerated() {
                guard let ref = step["uses"]?.text else { continue }
                uses.append(.init(job: id, step: k, reference: InfraText.cut(ref, 300), pinning: pinning(ref)))
                if isCheckout(ref), checksOutUntrustedRef(step["with"]) { checksOutPullRequestHead.append(id) }
            }
            let jobPermissions = permissions(j["permissions"])
            if jobPermissions == .notSet { jobsWithoutPermissions.append(id) }
            if jobPermissions == .writeAll {
                warnings.add(.caution, .permissionsWriteAll, String(localized: "This job gives its token write access to everything; name only the scopes it needs.", bundle: .module, comment: "Infra card warning on a GitHub Actions job with permissions: write-all."), subject: id)
            }
            jobs.append(.init(id: id, name: j["name"]?.text, runsOn: runsOn(j["runs-on"]), needs: Array(needs.prefix(200)),
                              steps: steps.count, uses: jobUses.map { InfraText.cut($0, 300) }, permissions: jobPermissions,
                              matrix: j["strategy"]?["matrix"] != nil))
        }

        switch topPermissions {
        case .writeAll:
            warnings.add(.caution, .permissionsWriteAll, String(localized: "The workflow gives every job's token write access to everything; name only the scopes it needs.", bundle: .module, comment: "Infra card warning on a GitHub Actions workflow with permissions: write-all."))
        case .notSet where !jobsWithoutPermissions.isEmpty:
            let list = jobsWithoutPermissions.prefix(10).joined(separator: ", ") + (jobsWithoutPermissions.count > 10 ? " …" : "")
            warnings.add(.caution, .permissionsNotSet, String(localized: "No permissions are set for \(list), so their token gets the repository default, which may be write access to everything.", bundle: .module, comment: "Infra card warning on a GitHub Actions workflow; the argument is a comma-separated list of job ids, kept as written."))
        default: break
        }
        if triggers.contains("pull_request_target") {
            for id in checksOutPullRequestHead {
                warnings.add(.danger, .pullRequestTargetCheckout,
                             String(localized: "Runs on pull_request_target and checks out the pull request's code: code from a fork runs with this repository's secrets and write token.", bundle: .module, comment: "Infra card warning (danger) on a GitHub Actions job; pull_request_target is a GitHub event name, kept as written."),
                             subject: id)
            }
        }
        let unpinned = uses.items.filter { $0.pinning == .unpinned }
        if !unpinned.isEmpty {
            warnings.add(.caution, .unpinnedAction,
                         String(localized: "\(unpinned.count) actions are referenced by tag or branch, not a full commit SHA, so the code can change under the same name.", bundle: .module, comment: "Infra card warning on a GitHub Actions workflow: actions used by a tag or branch instead of a commit hash."))
        }

        let graph = InfraGraph(nodes: jobs.items.map(\.id), edges: edges)
        if !jobs.truncated {
            for missing in graph.missing {
                warnings.add(.caution, .missingDependency, String(localized: "A needs names the job \(missing), which this workflow does not define.", bundle: .module, comment: "Infra card warning on a GitHub Actions workflow; needs is a workflow key, kept as written; the argument is a job id."), subject: missing)
            }
        }
        if graph.hasCycle { warnings.add(.caution, .dependencyCycle, String(localized: "The needs entries form a loop, so these jobs can never start.", bundle: .module, comment: "Infra card warning on a GitHub Actions workflow; needs is a workflow key, kept as written.")) }
        truncated = truncated || jobs.truncated || uses.truncated || warnings.truncated

        let pinned = uses.items.filter { $0.pinning == .pinned }.count
        let stepCount = jobs.items.reduce(0) { $0 + $1.steps }
        var facts: [InfraFact] = []
        if let name = root["name"]?.text { facts.append(.init(id: "name", label: String(localized: "Name", bundle: .module, comment: "Infra card fact label: the GitHub Actions workflow's name."), value: name)) }
        if !triggers.isEmpty { facts.append(.init(id: "triggers", label: String(localized: "Triggers", bundle: .module, comment: "Infra card fact label: the events that start a GitHub Actions workflow."), value: triggers.joined(separator: ", "))) }
        facts.append(.init(id: "jobs", label: String(localized: "Jobs", bundle: .module, comment: "Infra card fact label: GitHub Actions jobs."), value: jobs.total.formatted()))
        facts.append(.init(id: "steps", label: String(localized: "Steps", bundle: .module, comment: "Infra card fact label: GitHub Actions steps across all jobs."), value: stepCount.formatted()))
        let runners = Array(Set(jobs.items.compactMap(\.runsOn))).sorted()
        if !runners.isEmpty { facts.append(.init(id: "runners", label: String(localized: "Runners", bundle: .module, comment: "Infra card fact label: the machines GitHub Actions jobs run on (runs-on)."), value: runners.prefix(20).joined(separator: "; "))) }
        facts.append(.init(id: "actions", label: String(localized: "Actions used", bundle: .module, comment: "Infra card fact label: actions and reusable workflows a GitHub Actions workflow uses."), value: String(localized: "\(uses.total) (\(pinned) pinned to a SHA)", bundle: .module, comment: "Infra card fact value: actions used in total, and how many are pinned to a full commit hash (SHA).")))
        facts.append(.init(id: "permissions", label: String(localized: "Permissions", bundle: .module, comment: "Infra card fact label: the GitHub Actions token permissions."), value: topPermissions.display))

        let headline = root["name"]?.text.map { InfraText.cut($0, 80) }.map { name in
            String(localized: "\(name) · \(jobs.total) jobs", bundle: .module, comment: "Infra card headline for a GitHub Actions workflow: its name, then job count.")
        } ?? String(localized: "GitHub Actions workflow · \(jobs.total) jobs", bundle: .module, comment: "Infra card headline for a GitHub Actions workflow without a name: job count.")
        return WorkflowSummary(name: root["name"]?.text, triggers: triggers, jobs: jobs.items, totalJobs: jobs.total, graph: graph,
                               uses: uses.items, totalUses: uses.total, permissions: topPermissions, headline: headline,
                               facts: facts, warnings: warnings.sorted, truncated: truncated)
    }

    static func pinning(_ ref: String) -> WorkflowSummary.Pinning {
        if ref.hasPrefix("./") || ref.hasPrefix("../") { return .local }
        if ref.hasPrefix("docker://") { return InfraImage(String(ref.dropFirst(9))).pinnedByDigest ? .pinned : .docker }
        guard let at = ref.lastIndex(of: "@") else { return .unpinned }
        let version = ref[ref.index(after: at)...]
        let isSHA = version.count == 40 && version.allSatisfy { $0.isHexDigit }
        return isSHA ? .pinned : .unpinned
    }

    static func permissions(_ node: InfraNode?) -> WorkflowPermissions {
        guard let node else { return .notSet }
        if let s = node.text {
            switch s {
            case "read-all": return .readAll
            case "write-all": return .writeAll
            default: return .scoped([.init(name: "*", access: s)])
            }
        }
        if node.isObject {
            let scopes = node.entries.prefix(64).map { WorkflowPermissions.Scope(name: $0.key, access: $0.value.text ?? "?") }
            return scopes.isEmpty ? .none : .scoped(Array(scopes))
        }
        return node.isNull ? .notSet : .none
    }

    static func runsOn(_ node: InfraNode?) -> String? {
        guard let node else { return nil }
        if let s = node.text { return InfraText.cut(s, 120) }
        if node.isArray { return InfraText.cut(node.items.compactMap(\.text).joined(separator: ", "), 120) }
        if let group = node["group"]?.text { return InfraText.cut("group: \(group)", 120) }
        if let labels = node["labels"] { return InfraText.cut(labels.stringList.joined(separator: ", "), 120) }
        return nil
    }

    static func isCheckout(_ ref: String) -> Bool {
        ref.lowercased().hasPrefix("actions/checkout@") || ref.lowercased() == "actions/checkout"
    }

    /// A checkout `with:` whose `ref` or `repository` points at the pull request's head (the fork's code).
    static func checksOutUntrustedRef(_ with: InfraNode?) -> Bool {
        guard let with else { return false }
        let markers = ["github.event.pull_request.head.sha", "github.event.pull_request.head.ref", "github.head_ref",
                       "github.event.pull_request.head.repo.full_name", "refs/pull/", "github.event.pull_request.merge_commit_sha"]
        for key in ["ref", "repository"] {
            guard let value = with[key]?.text?.replacingOccurrences(of: " ", with: "") else { continue }
            if markers.contains(where: { value.contains($0) }) { return true }
        }
        return false
    }
}
