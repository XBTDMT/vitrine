import Foundation

/// What a Terraform state file (`.tfstate`, JSON format version 4) records: the Terraform version that wrote it, its
/// resources and outputs, and a secrets banner that counts sensitive attributes and secret-looking attribute names.
/// Names and counts only: no attribute or output value is ever kept. roadmap: S-22
public struct TerraformStateSummary: Sendable, Equatable {
    /// One `resources[]` entry. roadmap: S-22
    public struct Resource: Sendable, Equatable {
        /// `managed` or `data`.
        public var mode: String
        public var type: String
        public var name: String
        /// The provider shortened to `namespace/name` (`hashicorp/aws`), with its alias when it has one.
        public var provider: String?
        /// `module.network` when the resource lives in a module.
        public var module: String?
        public var instanceCount: Int

        public init(mode: String, type: String, name: String, provider: String?, module: String?, instanceCount: Int) {
            self.mode = mode
            self.type = type
            self.name = name
            self.provider = provider
            self.module = module
            self.instanceCount = instanceCount
        }

        /// `module.network.aws_vpc.main`, `data.aws_ami.base`.
        public var address: String {
            let base = mode == "data" ? "data.\(type).\(name)" : "\(type).\(name)"
            return module.map { "\($0).\(base)" } ?? base
        }
    }

    /// One output, by name. roadmap: S-22
    public struct Output: Sendable, Equatable {
        public var name: String
        public var sensitive: Bool

        public init(name: String, sensitive: Bool) {
            self.name = name
            self.sensitive = sensitive
        }
    }

    /// The secrets banner: what in the state holds a secret in plain text, by count and name. roadmap: S-22
    public struct Secrets: Sendable, Equatable {
        /// Attribute paths Terraform itself marked sensitive (`sensitive_attributes`), across every instance.
        public var sensitiveAttributes: Int
        /// Attributes whose name looks like a secret (password, token, private_key …) and that hold a value.
        public var secretNamedAttributes: Int
        /// Outputs marked sensitive.
        public var sensitiveOutputs: Int
        /// The attribute names behind the two attribute counts, most frequent first.
        public var names: [InfraNameCount]

        public init(sensitiveAttributes: Int, secretNamedAttributes: Int, sensitiveOutputs: Int, names: [InfraNameCount]) {
            self.sensitiveAttributes = sensitiveAttributes
            self.secretNamedAttributes = secretNamedAttributes
            self.sensitiveOutputs = sensitiveOutputs
            self.names = names
        }

        public var total: Int { sensitiveAttributes + secretNamedAttributes + sensitiveOutputs }
    }

    /// The state's own `version` (4 for every Terraform since 0.12).
    public var formatVersion: Int?
    public var terraformVersion: String?
    public var serial: Int?
    public var resources: [Resource]
    /// Every resource counted, even past the cap on `resources`.
    public var totalResources: Int
    public var totalInstances: Int
    public var outputs: [Output]
    public var totalOutputs: Int
    /// Distinct providers in first-seen order, with how many resources use each.
    public var providers: [InfraNameCount]
    public var secrets: Secrets
    public var headline: String
    public var facts: [InfraFact]
    public var warnings: [InfraWarning]
    public var truncated: Bool
}

enum TerraformStateReader {
    static func read(_ parsed: InfraParse.Result, capped: Bool) -> TerraformStateSummary? {
        guard let root = parsed.roots.first, root.isObject else { return nil }
        let formatVersion = root["version"]?.int
        let terraformVersion = root["terraform_version"]?.text
        guard formatVersion != nil || terraformVersion != nil, root["resources"] != nil || root["modules"] != nil
            || root["lineage"] != nil else { return nil }

        var truncated = capped || !parsed.complete
        var resources = Capped<TerraformStateSummary.Resource>()
        var providers = NameCounter()
        var secretNames = NameCounter()
        var sensitiveAttributes = 0, secretNamed = 0, instances = 0, managed = 0
        var modules: Set<String> = []

        for r in root["resources"]?.items ?? [] {
            let instanceNodes = r["instances"]?.items ?? []
            let provider = shortProvider(r["provider"]?.text)
            let mode = r["mode"]?.text ?? "managed"
            if mode != "data" { managed += 1 }
            if let module = r["module"]?.text, modules.count < InfraReader.maxItems { modules.insert(module) }
            if let provider { providers.add(provider) }
            resources.append(.init(mode: mode, type: r["type"]?.text ?? "?", name: r["name"]?.text ?? "?",
                                   provider: provider, module: r["module"]?.text, instanceCount: instanceNodes.count))
            instances += instanceNodes.count
            for instance in instanceNodes {
                for path in instance["sensitive_attributes"]?.items ?? [] {
                    sensitiveAttributes += 1
                    secretNames.add(attributeName(path))
                }
                if let attributes = instance["attributes"] {
                    let hits = secretNamedAttributes(attributes)
                    for (name, n) in hits { secretNames.add(name, n); secretNamed += n }
                }
            }
        }

        var outputs = Capped<TerraformStateSummary.Output>()
        var sensitiveOutputs = 0
        for (name, value) in root["outputs"]?.entries ?? [] {
            let sensitive = value["sensitive"]?.isTrue == true
            if sensitive { sensitiveOutputs += 1 }
            outputs.append(.init(name: name, sensitive: sensitive))
        }
        truncated = truncated || resources.truncated || outputs.truncated || providers.truncated || secretNames.truncated

        let secrets = TerraformStateSummary.Secrets(sensitiveAttributes: sensitiveAttributes, secretNamedAttributes: secretNamed,
                                                    sensitiveOutputs: sensitiveOutputs, names: secretNames.sorted)
        var warnings = WarningList()
        if secrets.total > 0 {
            var parts: [String] = []
            if sensitiveAttributes > 0 { parts.append(String(localized: "\(sensitiveAttributes) sensitive attributes", bundle: .module, comment: "Part of the Terraform secrets warning: attributes Terraform marked sensitive; joined into a list.")) }
            if secretNamed > 0 { parts.append(String(localized: "\(secretNamed) secret-named attributes", bundle: .module, comment: "Part of the Terraform secrets warning: attributes whose names look like passwords, tokens or keys; joined into a list.")) }
            if sensitiveOutputs > 0 { parts.append(String(localized: "\(sensitiveOutputs) sensitive outputs", bundle: .module, comment: "Part of the Terraform secrets warning: outputs marked sensitive; joined into a list.")) }
            let list = parts.formatted(.list(type: .and))
            warnings.add(.danger, .secretsInState, String(localized: "Terraform writes state values in plain text: this file holds \(list); treat it as a secret.", bundle: .module, comment: "Infra card warning on a Terraform state file; the argument is a list such as '2 sensitive attributes and 1 sensitive output'. Values are never shown."))
        }
        if let v = formatVersion, v != 4 {
            warnings.add(.caution, .unknownStateVersion,
                         String(localized: "State format version \(v) is not version 4, so parts of this file may not be shown.", bundle: .module, comment: "Infra card warning on a Terraform state file written in an older format; the argument is its version number."))
        }

        let dataSources = resources.total - managed
        var facts: [InfraFact] = []
        if let terraformVersion { facts.append(.init(id: "terraformVersion", label: String(localized: "Terraform", bundle: .module, comment: "Infra card fact label: the Terraform version that wrote the state."), value: terraformVersion)) }
        if let formatVersion { facts.append(.init(id: "formatVersion", label: String(localized: "State format", bundle: .module, comment: "Infra card fact label: the state file's own format version."), value: String(localized: "version \(formatVersion)", bundle: .module, comment: "Infra card fact value: a Terraform state format version number."))) }
        if let serial = root["serial"]?.int { facts.append(.init(id: "serial", label: String(localized: "Serial", bundle: .module, comment: "Infra card fact label: Terraform state serial number (how many times it was written)."), value: "\(serial)")) }
        facts.append(.init(id: "resources", label: String(localized: "Resources", bundle: .module, comment: "Infra card fact label: Terraform resources."), value: String(localized: "\(resources.total) (\(managed) managed, \(dataSources) data)", bundle: .module, comment: "Infra card fact value: Terraform resources in total, then how many are managed resources and how many are data sources.")))
        facts.append(.init(id: "instances", label: String(localized: "Instances", bundle: .module, comment: "Infra card fact label: Terraform resource instances."), value: instances.formatted()))
        if !modules.isEmpty { facts.append(.init(id: "modules", label: String(localized: "Modules", bundle: .module, comment: "Infra card fact label: Terraform modules."), value: modules.count.formatted())) }
        if !providers.isEmpty { facts.append(.init(id: "providers", label: String(localized: "Providers", bundle: .module, comment: "Infra card fact label: Terraform providers."), value: providers.inOrder.map(\.name).joined(separator: ", "))) }
        facts.append(.init(id: "outputs", label: String(localized: "Outputs", bundle: .module, comment: "Infra card fact label: Terraform outputs."), value: String(localized: "\(outputs.total) (\(sensitiveOutputs) sensitive)", bundle: .module, comment: "Infra card fact value: Terraform outputs in total and how many are marked sensitive.")))

        let headline = terraformVersion.map { version in
            String(localized: "Terraform state · \(resources.total) resources · Terraform \(version)", bundle: .module, comment: "Infra card headline for a Terraform state file: resource count and the Terraform version that wrote it.")
        } ?? String(localized: "Terraform state · \(resources.total) resources", bundle: .module, comment: "Infra card headline for a Terraform state file: resource count.")

        return TerraformStateSummary(formatVersion: formatVersion, terraformVersion: terraformVersion, serial: root["serial"]?.int,
                                     resources: resources.items, totalResources: resources.total, totalInstances: instances,
                                     outputs: outputs.items, totalOutputs: outputs.total, providers: providers.inOrder,
                                     secrets: secrets, headline: headline, facts: facts, warnings: warnings.sorted,
                                     truncated: truncated || warnings.truncated)
    }

    /// `provider["registry.terraform.io/hashicorp/aws"].west` → `hashicorp/aws.west`; older `provider.aws` → `aws`.
    static func shortProvider(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let open = raw.range(of: "[\""), let close = raw.range(of: "\"]", range: open.upperBound..<raw.endIndex) {
            var source = String(raw[open.upperBound..<close.lowerBound])
            if source.hasPrefix("registry.terraform.io/") { source.removeFirst("registry.terraform.io/".count) }
            let alias = raw[close.upperBound...]
            return InfraText.cut(source + alias, 200)
        }
        return InfraText.cut(raw.hasPrefix("provider.") ? String(raw.dropFirst("provider.".count)) : raw, 200)
    }

    /// The readable name of a `sensitive_attributes` path: its `get_attr` steps joined with dots, or the string form
    /// newer Terraform versions write.
    static func attributeName(_ path: InfraNode) -> String {
        if let s = path.text { return InfraText.cut(s, 200) }
        let steps = (path["path"] ?? path).items.prefix(16).compactMap { step -> String? in
            if step["type"]?.text == "get_attr" { return step["value"]?.text }
            return nil
        }
        return steps.isEmpty ? String(localized: "(unnamed)", bundle: .module, comment: "Name shown for a sensitive Terraform attribute whose path has no readable name.") : InfraText.cut(steps.joined(separator: "."), 200)
    }

    /// Secret-looking attribute names that hold a non-empty value, anywhere under `attributes`, walked with an
    /// explicit stack (the tree's depth is already bounded).
    static func secretNamedAttributes(_ attributes: InfraNode) -> [(String, Int)] {
        var counts: [String: Int] = [:], order: [String] = []
        var stack = [attributes]
        var visited = 0
        while let node = stack.popLast(), visited < 200_000 {
            visited += 1
            if node.isObject {
                for (key, value) in node.entries {
                    if InfraText.looksSecret(key), holdsValue(value) {
                        if counts[key] == nil { order.append(key) }
                        counts[key, default: 0] += 1
                    } else if !value.isScalar {
                        stack.append(value)
                    }
                }
            } else if node.isArray {
                stack.append(contentsOf: node.items)
            }
        }
        return order.map { ($0, counts[$0]!) }
    }

    private static func holdsValue(_ node: InfraNode) -> Bool {
        if node.isScalar { return !(node.text ?? "").isEmpty && node.raw.kind != .bool }
        return node.count > 0
    }
}
