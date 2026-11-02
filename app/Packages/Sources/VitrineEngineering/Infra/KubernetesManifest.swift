import Foundation

/// What a Kubernetes manifest (YAML, one or more documents, `List` items expanded) declares: objects by kind with
/// their names and namespaces, every container image, Secret data keys (never values), and warnings for floating
/// images, privileged containers, hostPath volumes, host namespaces and containers that run as root.
/// roadmap: S-22
public struct KubernetesSummary: Sendable, Equatable {
    /// One object (`apiVersion` + `kind`). roadmap: S-22
    public struct Object: Sendable, Equatable {
        public var apiVersion: String
        public var kind: String
        public var name: String?
        public var namespace: String?
        /// The 1-based YAML document it came from.
        public var document: Int

        public init(apiVersion: String, kind: String, name: String?, namespace: String?, document: Int) {
            self.apiVersion = apiVersion
            self.kind = kind
            self.name = name
            self.namespace = namespace
            self.document = document
        }
    }

    /// One container of a workload's pod template. roadmap: S-22
    public struct Container: Sendable, Equatable {
        /// `Deployment/harbor-api`.
        public var owner: String
        public var name: String
        public var image: InfraImage?
        /// `container`, `init` or `ephemeral`.
        public var role: String
        public var privileged: Bool
        /// The effective `runAsUser` (the container's, else the pod's), when one is set.
        public var runAsUser: Int?

        public init(owner: String, name: String, image: InfraImage?, role: String, privileged: Bool, runAsUser: Int?) {
            self.owner = owner; self.name = name; self.image = image; self.role = role
            self.privileged = privileged; self.runAsUser = runAsUser
        }
    }

    /// A Secret's shape: its keys, never its values. roadmap: S-22
    public struct Secret: Sendable, Equatable {
        public var name: String?
        public var namespace: String?
        /// `Opaque`, `kubernetes.io/tls` …
        public var type: String?
        /// Keys of `data` and `stringData`, in file order.
        public var keys: [String]

        public init(name: String?, namespace: String?, type: String?, keys: [String]) {
            self.name = name
            self.namespace = namespace
            self.type = type
            self.keys = keys
        }
    }

    public var objects: [Object]
    public var totalObjects: Int
    /// Kind → count, most first.
    public var kinds: [InfraNameCount]
    public var namespaces: [String]
    public var containers: [Container]
    public var secrets: [Secret]
    /// YAML documents that are not Kubernetes objects (no `apiVersion` or `kind`), empty ones excluded.
    public var otherDocuments: Int
    public var headline: String
    public var facts: [InfraFact]
    public var warnings: [InfraWarning]
    public var truncated: Bool
}

enum KubernetesReader {
    static func read(_ parsed: InfraParse.Result, capped: Bool) -> KubernetesSummary? {
        var truncated = capped || !parsed.complete
        var objects = Capped<KubernetesSummary.Object>()
        var kinds = NameCounter()
        var namespaces = NameCounter()
        var containers = Capped<KubernetesSummary.Container>()
        var secrets = Capped<KubernetesSummary.Secret>()
        var warnings = WarningList()
        var other = 0

        // Documents, with `kind: List` items queued after their list (one level: a List of Lists is not a thing).
        var queue: [(node: InfraNode, document: Int, fromList: Bool)] = parsed.roots.enumerated().map { ($0.element, $0.offset + 1, false) }
        var k = 0
        while k < queue.count {
            let (doc, number, fromList) = queue[k]
            k += 1
            guard doc.isObject else { if !doc.isNull { other += 1 }; continue }
            guard let apiVersion = doc["apiVersion"]?.text, let kind = doc["kind"]?.text else { other += 1; continue }
            if kind.hasSuffix("List"), let items = doc["items"], items.isArray, !fromList {
                for item in items.items {
                    if queue.count < InfraReader.maxItems * 4 { queue.append((item, number, true)) } else { truncated = true }
                }
                continue
            }
            let metadata = doc["metadata"]
            let name = metadata?["name"]?.text ?? metadata?["generateName"]?.text
            let namespace = metadata?["namespace"]?.text
            objects.append(.init(apiVersion: apiVersion, kind: kind, name: name, namespace: namespace, document: number))
            kinds.add(kind)
            if let namespace { namespaces.add(namespace) }
            let owner = "\(kind)/\(name ?? "?")"

            if kind == "Secret" {
                var keys = (doc["data"]?.entries.map(\.key) ?? []) + (doc["stringData"]?.entries.map(\.key) ?? [])
                if keys.count > 500 { keys = Array(keys.prefix(500)); truncated = true }
                secrets.append(.init(name: name, namespace: namespace, type: doc["type"]?.text, keys: keys.map { InfraText.cut($0, 200) }))
            }
            guard let pod = podSpec(doc, kind: kind) else { continue }
            if pod["hostNetwork"]?.isTrue == true {
                warnings.add(.caution, .hostNetwork, String(localized: "Uses the node's network directly, so its ports are open on the node.", bundle: .module, comment: "Infra card warning on a Kubernetes workload with hostNetwork."), subject: owner)
            }
            if pod["hostPID"]?.isTrue == true || pod["hostIPC"]?.isTrue == true {
                warnings.add(.caution, .hostNamespace, String(localized: "Shares the node's process or IPC namespace, so it can see the node's processes.", bundle: .module, comment: "Infra card warning on a Kubernetes workload with hostPID or hostIPC."), subject: owner)
            }
            for volume in pod["volumes"]?.items ?? [] {
                guard let hostPath = volume["hostPath"] else { continue }
                let path = InfraText.cut(hostPath["path"]?.text ?? "?", 120)
                if path.contains("docker.sock") || path.contains("containerd.sock") || path.contains("crio.sock") {
                    warnings.add(.danger, .dockerSocket, String(localized: "Mounts the node's container runtime socket (\(path)), which controls every container on the node.", bundle: .module, comment: "Infra card warning (danger) on a Kubernetes workload; the argument is a file path, kept as written."), subject: owner)
                } else {
                    warnings.add(.caution, .hostPath, String(localized: "Mounts \(path) from the node's own disk (hostPath).", bundle: .module, comment: "Infra card warning on a Kubernetes workload; hostPath is a Kubernetes term, kept as written; the argument is a file path."), subject: owner)
                }
            }
            let podUser = pod["securityContext"]?["runAsUser"]?.int
            for (field, role) in [("containers", "container"), ("initContainers", "init"), ("ephemeralContainers", "ephemeral")] {
                for c in pod[field]?.items ?? [] {
                    let cname = c["name"]?.text ?? "?"
                    let image = c["image"]?.text.map(InfraImage.init)
                    let security = c["securityContext"]
                    let privileged = security?["privileged"]?.isTrue == true
                    let user = security?["runAsUser"]?.int ?? podUser
                    containers.append(.init(owner: owner, name: cname, image: image, role: role, privileged: privileged, runAsUser: user))
                    let subject = "\(owner) \(cname)"
                    if let image, image.floats {
                        let reference = InfraText.cut(image.reference, 120)
                        warnings.add(.caution, .unpinnedImage, String(localized: "Image \(reference) has no fixed tag or digest, so it can change between pulls.", bundle: .module, comment: "Infra card warning on a Kubernetes container; the argument is the container image reference, kept as written."), subject: subject)
                    } else if image == nil {
                        warnings.add(.caution, .unpinnedImage, String(localized: "Container has no image.", bundle: .module, comment: "Infra card warning on a Kubernetes container that names no image."), subject: subject)
                    }
                    if privileged {
                        warnings.add(.danger, .privileged, String(localized: "Runs privileged: the container gets almost every power of the node.", bundle: .module, comment: "Infra card warning (danger) on a Kubernetes container."), subject: subject)
                    }
                    if user == 0 {
                        warnings.add(.caution, .runsAsRoot, String(localized: "Runs as user 0 (root).", bundle: .module, comment: "Infra card warning on a Kubernetes container whose runAsUser is 0."), subject: subject)
                    }
                    if let caps = security?["capabilities"]?["add"]?.stringList,
                       let found = caps.first(where: { ["ALL", "SYS_ADMIN"].contains($0.uppercased().replacingOccurrences(of: "CAP_", with: "")) }) {
                        let c = found.uppercased()
                        warnings.add(.danger, .dangerousCapability, String(localized: "Adds the \(c) capability, which is close to running privileged.", bundle: .module, comment: "Infra card warning on a container; the argument is a Linux capability name such as SYS_ADMIN, kept as written."), subject: subject)
                    }
                }
            }
        }
        guard objects.total > 0 else { return nil }
        truncated = truncated || objects.truncated || containers.truncated || secrets.truncated || kinds.truncated
            || namespaces.truncated || warnings.truncated

        let kindList = kinds.sorted
        var facts: [InfraFact] = [
            .init(id: "objects", label: String(localized: "Objects", bundle: .module, comment: "Infra card fact label: Kubernetes objects in the manifest."), value: objects.total.formatted()),
            .init(id: "kinds", label: String(localized: "Kinds", bundle: .module, comment: "Infra card fact label: Kubernetes object kinds (Deployment, Service …) with counts."), value: kindList.prefix(12).map { "\($0.name) \($0.count)" }.joined(separator: ", ")),
        ]
        if !namespaces.isEmpty { facts.append(.init(id: "namespaces", label: String(localized: "Namespaces", bundle: .module, comment: "Infra card fact label: Kubernetes namespaces."), value: namespaces.inOrder.map(\.name).prefix(20).joined(separator: ", "))) }
        if containers.total > 0 { facts.append(.init(id: "containers", label: String(localized: "Containers", bundle: .module, comment: "Infra card fact label: containers in Kubernetes pod templates."), value: containers.total.formatted())) }
        if secrets.total > 0 {
            let keys = secrets.items.reduce(0) { $0 + $1.keys.count }
            facts.append(.init(id: "secrets", label: String(localized: "Secrets", bundle: .module, comment: "Infra card fact label: Kubernetes Secret objects."), value: String(localized: "\(secrets.total) (\(keys) keys, values not shown)", bundle: .module, comment: "Infra card fact value: Kubernetes Secrets and how many data keys they hold; their values are never shown.")))
        }
        if other > 0 { facts.append(.init(id: "otherDocuments", label: String(localized: "Other documents", bundle: .module, comment: "Infra card fact label: YAML documents in the file that are not Kubernetes objects."), value: other.formatted())) }

        let headline: String
        if objects.total == 1 {
            let kind = objects.items[0].kind
            if let name = objects.items[0].name {
                headline = String(localized: "Kubernetes \(kind) · \(name)", bundle: .module, comment: "Infra card headline for a Kubernetes manifest with one object: its kind (kept as written, e.g. Deployment) and name.")
            } else {
                headline = String(localized: "Kubernetes \(kind)", bundle: .module, comment: "Infra card headline for a Kubernetes manifest with one unnamed object: its kind, kept as written.")
            }
        } else {
            let kindCount = kindList.count
            headline = String(localized: "Kubernetes · \(objects.total) objects · \(kindCount) kinds", bundle: .module, comment: "Infra card headline for a Kubernetes manifest: object count and how many different kinds.")
        }
        return KubernetesSummary(objects: objects.items, totalObjects: objects.total, kinds: kindList,
                                 namespaces: namespaces.inOrder.map(\.name), containers: containers.items, secrets: secrets.items,
                                 otherDocuments: other, headline: headline, facts: facts, warnings: warnings.sorted, truncated: truncated)
    }

    /// The pod spec of a Pod, a pod-template workload, or a CronJob; for an unknown kind, `spec.template.spec` or a
    /// `spec` that has containers.
    static func podSpec(_ doc: InfraNode, kind: String) -> InfraNode? {
        guard let spec = doc["spec"] else { return nil }
        switch kind {
        case "Pod": return spec
        case "CronJob": return spec["jobTemplate"]?["spec"]?["template"]?["spec"]
        default:
            if let template = spec["template"]?["spec"] { return template }
            return spec["containers"] != nil ? spec : nil
        }
    }
}
