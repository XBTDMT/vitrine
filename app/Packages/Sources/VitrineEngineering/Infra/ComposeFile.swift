import Foundation

/// What a Compose file (`compose.yaml`, `docker-compose.yml`, `docker-compose.*.yml`) defines: its services with
/// their image or build, ports, volumes, networks and restart policy, the `depends_on` graph, environment variable
/// names (never values), and the top-level networks, volumes, secrets and configs, with warnings for privileged
/// containers, host networking, a mounted Docker socket and dangerous capabilities. roadmap: S-22
public struct ComposeSummary: Sendable, Equatable {
    /// One service. roadmap: S-22
    public struct Service: Sendable, Equatable {
        public var name: String
        public var image: InfraImage?
        /// The build context (`build: ./api` or `build.context`), `.` when `build` is given without one.
        public var build: String?
        /// Port mappings as Compose writes them (`8080:80`, `127.0.0.1:5432:5432/tcp`).
        public var ports: [String]
        /// Mounts as `source:target` (or just the target for an anonymous volume), with `:ro` when read-only.
        public var volumes: [String]
        public var networks: [String]
        public var restart: String?
        public var dependsOn: [String]
        /// Environment variable names from `environment`, never their values.
        public var environmentKeys: [String]
        public var envFiles: [String]
        public var secrets: [String]
        public var configs: [String]
        public var privileged: Bool
        public var networkMode: String?
        public var capAdd: [String]
        public var user: String?

        public init(name: String, image: InfraImage? = nil, build: String? = nil, ports: [String] = [], volumes: [String] = [],
                    networks: [String] = [], restart: String? = nil, dependsOn: [String] = [], environmentKeys: [String] = [],
                    envFiles: [String] = [], secrets: [String] = [], configs: [String] = [], privileged: Bool = false,
                    networkMode: String? = nil, capAdd: [String] = [], user: String? = nil) {
            self.name = name; self.image = image; self.build = build; self.ports = ports; self.volumes = volumes
            self.networks = networks; self.restart = restart; self.dependsOn = dependsOn; self.environmentKeys = environmentKeys
            self.envFiles = envFiles; self.secrets = secrets; self.configs = configs; self.privileged = privileged
            self.networkMode = networkMode; self.capAdd = capAdd; self.user = user
        }
    }

    /// The top-level `name:` (the project name).
    public var projectName: String?
    /// The obsolete top-level `version:` when the file still has one.
    public var declaredVersion: String?
    public var services: [Service]
    public var totalServices: Int
    /// Services as nodes, `depends_on` as edges.
    public var graph: InfraGraph
    public var networks: [String]
    public var volumes: [String]
    public var secrets: [String]
    public var configs: [String]
    public var headline: String
    public var facts: [InfraFact]
    public var warnings: [InfraWarning]
    public var truncated: Bool
}

enum ComposeReader {
    static let maxPerService = 500

    static func read(_ parsed: InfraParse.Result, capped: Bool) -> ComposeSummary? {
        guard let root = parsed.roots.first, root.isObject else { return nil }
        let servicesNode = root["services"]
        guard servicesNode?.isObject == true || root["version"] != nil && servicesNode != nil else { return nil }

        var truncated = capped || !parsed.complete
        var services = Capped<ComposeSummary.Service>()
        var edges: [InfraGraph.Edge] = []
        var warnings = WarningList()

        for (name, s) in servicesNode?.entries ?? [] where s.isObject {
            var service = ComposeSummary.Service(name: name)
            if let image = s["image"]?.text { service.image = InfraImage(image) }
            if let build = s["build"] { service.build = build.text ?? build["context"]?.text ?? "." }
            service.ports = limited(s["ports"]?.items.compactMap(port) ?? [], &truncated)
            service.volumes = limited(s["volumes"]?.items.compactMap(volume) ?? [], &truncated)
            service.networks = limited(s["networks"]?.keysOrStrings ?? [], &truncated)
            service.restart = s["restart"]?.text
            if let deps = s["depends_on"] {
                service.dependsOn = limited(deps.keysOrStrings, &truncated)
                for dep in service.dependsOn {
                    if edges.count < InfraReader.maxItems {
                        edges.append(.init(from: name, to: dep, label: deps.isObject ? deps[dep]?["condition"]?.text : nil))
                    } else { truncated = true }
                }
            }
            let (keys, inlineSecrets) = environment(s["environment"])
            service.environmentKeys = limited(keys, &truncated)
            service.envFiles = limited(s["env_file"].map { $0.text.map { [$0] } ?? $0.items.compactMap { $0.text ?? $0["path"]?.text } } ?? [], &truncated)
            service.secrets = limited(s["secrets"]?.keysOrStrings ?? [], &truncated)
            service.configs = limited(s["configs"]?.keysOrStrings ?? [], &truncated)
            service.privileged = s["privileged"]?.isTrue == true
            service.networkMode = s["network_mode"]?.text
            service.capAdd = limited(s["cap_add"]?.stringList ?? [], &truncated)
            service.user = s["user"]?.text

            if service.privileged {
                warnings.add(.danger, .privileged, String(localized: "Runs privileged: the container gets almost every power of the host.", bundle: .module, comment: "Infra card warning on a Compose service."), subject: name)
            }
            if service.networkMode == "host" {
                warnings.add(.caution, .hostNetwork, String(localized: "Uses the host's network directly, so its ports are open on the host without mapping.", bundle: .module, comment: "Infra card warning on a Compose service with network_mode host."), subject: name)
            }
            if s["pid"]?.text == "host" || s["ipc"]?.text == "host" {
                warnings.add(.caution, .hostNamespace, String(localized: "Shares the host's process or IPC namespace, so it can see the host's processes.", bundle: .module, comment: "Infra card warning on a Compose service with pid or ipc set to host."), subject: name)
            }
            if service.volumes.contains(where: { $0.contains("docker.sock") }) {
                warnings.add(.danger, .dockerSocket, String(localized: "Mounts the Docker socket: anything in the container can control Docker, and through it the host.", bundle: .module, comment: "Infra card warning on a Compose service that mounts docker.sock."), subject: name)
            }
            for cap in service.capAdd {
                let c = cap.uppercased().replacingOccurrences(of: "CAP_", with: "")
                if c == "ALL" || c == "SYS_ADMIN" {
                    warnings.add(.danger, .dangerousCapability, String(localized: "Adds the \(c) capability, which is close to running privileged.", bundle: .module, comment: "Infra card warning on a container; the argument is a Linux capability name such as SYS_ADMIN, kept as written."), subject: name)
                }
            }
            if let image = service.image, image.floats {
                let reference = InfraText.cut(image.reference, 120)
                warnings.add(.caution, .unpinnedImage, String(localized: "Image \(reference) has no fixed tag or digest, so it can change between runs.", bundle: .module, comment: "Infra card warning on a Compose service; the argument is the container image reference, kept as written."), subject: name)
            }
            if inlineSecrets > 0 {
                warnings.add(.caution, .inlineSecretEnvironment,
                             String(localized: "\(inlineSecrets) secret-looking environment variables set with a value written in the file.", bundle: .module, comment: "Infra card warning on a Compose service: environment variables named like passwords or tokens whose value is in the file (the values are never shown)."), subject: name)
            }
            services.append(service)
        }

        let graph = InfraGraph(nodes: services.items.map(\.name), edges: edges)
        if !services.truncated {
            for missing in graph.missing {
                warnings.add(.caution, .missingDependency, String(localized: "A depends_on names \(missing), which this file does not define.", bundle: .module, comment: "Infra card warning on a Compose file; depends_on is a Compose key, kept as written; the argument is a service name."), subject: missing)
            }
        }
        if graph.hasCycle { warnings.add(.caution, .dependencyCycle, String(localized: "The depends_on entries form a loop, so Compose cannot start these services.", bundle: .module, comment: "Infra card warning on a Compose file; depends_on is a Compose key, kept as written.")) }

        let networks = limited(root["networks"]?.keysOrStrings ?? [], &truncated)
        let volumes = limited(root["volumes"]?.keysOrStrings ?? [], &truncated)
        let secrets = limited(root["secrets"]?.keysOrStrings ?? [], &truncated)
        let configs = limited(root["configs"]?.keysOrStrings ?? [], &truncated)
        truncated = truncated || services.truncated || warnings.truncated

        var facts: [InfraFact] = []
        if let project = root["name"]?.text { facts.append(.init(id: "project", label: String(localized: "Project", bundle: .module, comment: "Infra card fact label: the Compose project name."), value: project)) }
        facts.append(.init(id: "services", label: String(localized: "Services", bundle: .module, comment: "Infra card fact label: Compose services."), value: services.total.formatted()))
        let images = services.items.filter { $0.image != nil }.count, builds = services.items.filter { $0.build != nil }.count
        facts.append(.init(id: "sources", label: String(localized: "Images / builds", bundle: .module, comment: "Infra card fact label: how many Compose services use a prebuilt image and how many are built from source."), value: "\(images.formatted()) / \(builds.formatted())"))
        let ports = services.items.reduce(0) { $0 + $1.ports.count }
        if ports > 0 { facts.append(.init(id: "ports", label: String(localized: "Published ports", bundle: .module, comment: "Infra card fact label: Compose port mappings."), value: ports.formatted())) }
        if !networks.isEmpty { facts.append(.init(id: "networks", label: String(localized: "Networks", bundle: .module, comment: "Infra card fact label: Compose networks."), value: networks.joined(separator: ", "))) }
        if !volumes.isEmpty { facts.append(.init(id: "volumes", label: String(localized: "Volumes", bundle: .module, comment: "Infra card fact label: Compose volumes."), value: volumes.joined(separator: ", "))) }
        if !secrets.isEmpty { facts.append(.init(id: "secrets", label: String(localized: "Secrets", bundle: .module, comment: "Infra card fact label: Compose secrets, by name."), value: secrets.joined(separator: ", "))) }
        if !configs.isEmpty { facts.append(.init(id: "configs", label: String(localized: "Configs", bundle: .module, comment: "Infra card fact label: Compose configs, by name."), value: configs.joined(separator: ", "))) }
        if let v = root["version"]?.text { facts.append(.init(id: "version", label: String(localized: "Version key", bundle: .module, comment: "Infra card fact label: the obsolete top-level version key of a Compose file."), value: String(localized: "\(v) (obsolete, ignored by Compose v2)", bundle: .module, comment: "Infra card fact value: the Compose file's version key, which current Compose ignores."))) }

        return ComposeSummary(projectName: root["name"]?.text, declaredVersion: root["version"]?.text, services: services.items,
                              totalServices: services.total, graph: graph, networks: networks, volumes: volumes, secrets: secrets,
                              configs: configs, headline: String(localized: "Compose · \(services.total) services", bundle: .module, comment: "Infra card headline for a Compose file: service count."),
                              facts: facts, warnings: warnings.sorted, truncated: truncated)
    }

    static func limited(_ list: [String], _ truncated: inout Bool) -> [String] {
        if list.count > maxPerService { truncated = true; return Array(list.prefix(maxPerService)) }
        return list
    }

    /// Short (`"8080:80"`) or long (`{target: 80, published: 8080, protocol: tcp}`) syntax.
    static func port(_ node: InfraNode) -> String? {
        if let s = node.text { return InfraText.cut(s, 120) }
        guard node.isObject, let target = node["target"]?.text else { return nil }
        var out = target
        if let published = node["published"]?.text { out = "\(published):\(target)" }
        if let ip = node["host_ip"]?.text { out = "\(ip):\(out)" }
        if let proto = node["protocol"]?.text { out += "/\(proto)" }
        return InfraText.cut(out, 120)
    }

    /// Short (`./data:/var/lib/data:ro`) or long (`{type: bind, source:, target:, read_only:}`) syntax.
    static func volume(_ node: InfraNode) -> String? {
        if let s = node.text { return InfraText.cut(s, 240) }
        guard node.isObject, let target = node["target"]?.text else { return nil }
        var out = node["source"]?.text.map { "\($0):\(target)" } ?? target
        if node["read_only"]?.isTrue == true { out += ":ro" }
        return InfraText.cut(out, 240)
    }

    /// The variable names, and how many secret-looking ones carry a literal value (not `${VAR}`, not empty).
    static func environment(_ node: InfraNode?) -> ([String], Int) {
        guard let node else { return ([], 0) }
        var keys: [String] = [], inline = 0
        if node.isObject {
            for (key, value) in node.entries {
                keys.append(InfraText.cut(key, 200))
                if InfraText.looksSecret(key), let v = value.text, !v.hasPrefix("$") { inline += 1 }
            }
        } else {
            for item in node.items {
                guard let entry = item.text else { continue }
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                keys.append(InfraText.cut(key, 200))
                if parts.count == 2, InfraText.looksSecret(key), !parts[1].isEmpty, !parts[1].hasPrefix("$") { inline += 1 }
            }
        }
        return (keys, inline)
    }
}
