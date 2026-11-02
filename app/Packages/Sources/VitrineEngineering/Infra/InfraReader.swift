import Foundation
import VitrineData

/// The infrastructure file kinds the infra lens reads (E-4, T-8). roadmap: S-22
public enum InfraKind: String, Sendable, Equatable, CaseIterable {
    case terraformState, compose, githubWorkflow, kubernetes, dockerfile, har
}

/// One read infrastructure file: the summary for its kind. The shared parts every card draws (`headline`, `facts`,
/// `warnings`, `truncated`) are available on the enum itself. roadmap: S-22
public enum InfraDocument: Sendable, Equatable {
    case terraformState(TerraformStateSummary)
    case compose(ComposeSummary)
    case githubWorkflow(WorkflowSummary)
    case kubernetes(KubernetesSummary)
    case dockerfile(DockerfileSummary)
    case har(HARSummary)

    public var kind: InfraKind {
        switch self {
        case .terraformState: .terraformState
        case .compose: .compose
        case .githubWorkflow: .githubWorkflow
        case .kubernetes: .kubernetes
        case .dockerfile: .dockerfile
        case .har: .har
        }
    }

    /// A short English line naming what the file is and its size in its own terms ("Compose · 4 services").
    public var headline: String {
        switch self {
        case .terraformState(let s): s.headline
        case .compose(let s): s.headline
        case .githubWorkflow(let s): s.headline
        case .kubernetes(let s): s.headline
        case .dockerfile(let s): s.headline
        case .har(let s): s.headline
        }
    }

    public var facts: [InfraFact] {
        switch self {
        case .terraformState(let s): s.facts
        case .compose(let s): s.facts
        case .githubWorkflow(let s): s.facts
        case .kubernetes(let s): s.facts
        case .dockerfile(let s): s.facts
        case .har(let s): s.facts
        }
    }

    /// Danger first, then in file order.
    public var warnings: [InfraWarning] {
        switch self {
        case .terraformState(let s): s.warnings
        case .compose(let s): s.warnings
        case .githubWorkflow(let s): s.warnings
        case .kubernetes(let s): s.warnings
        case .dockerfile(let s): s.warnings
        case .har(let s): s.warnings
        }
    }

    /// The input passed a limit (more than `InfraReader.maxBytes`, more than `maxItems` in a list, nesting deeper
    /// than `maxDepth`) or ended mid-structure, so the summary was read from part of it.
    public var truncated: Bool {
        switch self {
        case .terraformState(let s): s.truncated
        case .compose(let s): s.truncated
        case .githubWorkflow(let s): s.truncated
        case .kubernetes(let s): s.truncated
        case .dockerfile(let s): s.truncated
        case .har(let s): s.truncated
        }
    }
}

/// Reads infrastructure files (E-4) for the infra lens (T-8): Terraform state, Compose files, GitHub Actions
/// workflows, Kubernetes manifests, Dockerfiles and HAR captures. The kind comes from the file name and path first and
/// from the content only when the name does not decide. Every file is untrusted input: at most `maxBytes` are read,
/// lists keep at most `maxItems` items (all are counted) and set `truncated`, nesting is bounded, nothing is fetched,
/// started or written, and malformed input gives nil or a partial summary, never a crash. Secret values (Terraform
/// attributes, environment values, Secret data, cookies, Authorization headers) are never kept: only names and
/// counts. roadmap: S-22
public enum InfraReader {
    /// The most bytes read from one file.
    public static let maxBytes = 8 * 1024 * 1024
    /// The most items kept in any one list of a summary.
    public static let maxItems = 2_000
    /// The deepest nesting the structured parsers keep.
    public static let maxDepth = 64

    /// The kind a file's name and path promise, without looking at its bytes; nil when only its content could tell
    /// (a Kubernetes manifest is an ordinary `.yaml` by name).
    public static func kind(fileName: String, path: String?) -> InfraKind? {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if name.hasSuffix(".tfstate") || name.hasSuffix(".tfstate.backup") { return .terraformState }
        if ext == "har" { return .har }
        if ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].contains(name) { return .compose }
        if ext == "yml" || ext == "yaml", name.hasPrefix("docker-compose.") || name.hasPrefix("compose.") { return .compose }
        if ext == "yml" || ext == "yaml", let path {
            let p = path.replacingOccurrences(of: "\\", with: "/")
            if p.contains(".github/workflows/") { return .githubWorkflow }
        }
        if name == "dockerfile" || name == "containerfile" || ext == "dockerfile" || ext == "containerfile" { return .dockerfile }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") {
            let notDockerfile = ["md", "txt", "json", "yml", "yaml", "toml", "sh", "swift", "rtf", "html", "pdf"]
            if !notDockerfile.contains(ext) { return .dockerfile }
        }
        return nil
    }

    /// The kind from the first bytes alone, for a file whose name does not decide. Only strong markers count, so an
    /// ordinary JSON or YAML file is not mistaken for one of these.
    public static func sniff(data: Data, fileName: String) -> InfraKind? {
        let ext = ((fileName as NSString).pathExtension).lowercased()
        let head = InfraText.decode(data.prefix(64 * 1024))
        let trimmed = head.drop { $0.isWhitespace }
        if trimmed.hasPrefix("{"), ext == "json" || ext.isEmpty || ext == "backup" {
            if head.contains("\"terraform_version\"") && head.contains("\"lineage\"") { return .terraformState }
            if head.contains("\"log\"") && head.contains("\"entries\"") && head.contains("\"creator\"") { return .har }
            return nil
        }
        if ext == "yml" || ext == "yaml" {
            let lines = head.split(whereSeparator: \.isNewline)
            func topLevel(_ key: String) -> Bool { lines.contains { $0.hasPrefix(key + ":") } }
            if topLevel("jobs"), topLevel("on") || topLevel("\"on\"") || topLevel("'on'") { return .githubWorkflow }
            let k8sDoc = lines.contains { $0.hasPrefix("apiVersion:") } && lines.contains { $0.hasPrefix("kind:") }
            if k8sDoc { return .kubernetes }
            if topLevel("services"), !topLevel("apiVersion") { return .compose }
            return nil
        }
        if ext.isEmpty, DockerfileReader.looksLikeDockerfile(head) { return .dockerfile }
        return nil
    }

    /// nil when the file is none of the kinds (by name and path, then content), or its content lacks the shape its
    /// name promises.
    public static func read(data: Data, fileName: String, path: String?) -> InfraDocument? {
        guard let kind = kind(fileName: fileName, path: path) ?? sniff(data: data, fileName: fileName) else { return nil }
        let capped = data.count > maxBytes
        let input = capped ? data.prefix(maxBytes) : data
        return read(input, kind: kind, fileSize: data.count, capped: capped)
    }

    static func read(_ data: Data, kind: InfraKind, fileSize: Int, capped: Bool) -> InfraDocument? {
        switch kind {
        case .terraformState:
            let parsed = InfraParse.structured(data, format: .json, fileSize: fileSize)
            return TerraformStateReader.read(parsed, capped: capped).map(InfraDocument.terraformState)
        case .har:
            let parsed = InfraParse.structured(data, format: .json, fileSize: fileSize)
            return HARReader.read(parsed, capped: capped).map(InfraDocument.har)
        case .compose:
            let parsed = InfraParse.structured(data, format: .yaml, fileSize: fileSize)
            return ComposeReader.read(parsed, capped: capped).map(InfraDocument.compose)
        case .githubWorkflow:
            let parsed = InfraParse.structured(data, format: .yaml, fileSize: fileSize)
            return WorkflowReader.read(parsed, capped: capped).map(InfraDocument.githubWorkflow)
        case .kubernetes:
            let parsed = InfraParse.structured(data, format: .yaml, fileSize: fileSize)
            return KubernetesReader.read(parsed, capped: capped).map(InfraDocument.kubernetes)
        case .dockerfile:
            var text = InfraText.decode(data)
            if capped, let lastNewline = text.lastIndex(of: "\n") { text = String(text[...lastNewline]) }
            return DockerfileReader.read(text, capped: capped).map(InfraDocument.dockerfile)
        }
    }
}
