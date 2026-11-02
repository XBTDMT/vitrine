import Foundation
import VitrineSupport

/// A model input or output: name, element type and shape (symbolic dimensions by name). roadmap: S-21
public struct ModelIO: Sendable, Equatable {
    public var name: String
    /// FLOAT, INT64, image, multiArray, string …
    public var type: String
    /// Dimensions as text: "1", "batch", "?" for unknown.
    public var shape: [String]
    public var detail: String?
}

/// An ONNX model's header (ModelProto, read with our own wire-format reader): IR version, producer, opsets, graph,
/// inputs and outputs, node count and the most used operators, initializers. Tensor data is skipped by offset.
/// roadmap: S-21
public struct ONNXSummary: Sendable, Equatable {
    public var irVersion: Int64?
    public var producerName: String?
    public var producerVersion: String?
    public var domain: String?
    public var modelVersion: Int64?
    public var docString: String?
    /// "ai.onnx 17", "ai.onnx.ml 3", "com.microsoft 1".
    public var opsets: [String]
    public var graphName: String?
    public var inputs: [ModelIO]
    public var outputs: [ModelIO]
    public var nodeCount: Int
    /// The ten most used operators with their counts, most used first.
    public var topOperators: [AIFact]
    public var initializerCount: Int
    /// The sum of the initializers' elements, nil when a shape overflowed.
    public var parameterCount: Int64?
    /// Files the weights live in, when stored outside the model.
    public var externalDataFiles: [String]
    public var metadata: [AIFact]
    public var partial: String?
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]
}

enum ONNXReader {
    static let elementTypes = [1: "FLOAT", 2: "UINT8", 3: "INT8", 4: "UINT16", 5: "INT16", 6: "INT32", 7: "INT64", 8: "STRING",
                               9: "BOOL", 10: "FLOAT16", 11: "DOUBLE", 12: "UINT32", 13: "UINT64", 14: "COMPLEX64",
                               15: "COMPLEX128", 16: "BFLOAT16", 17: "FLOAT8E4M3FN", 18: "FLOAT8E4M3FNUZ", 19: "FLOAT8E5M2",
                               20: "FLOAT8E5M2FNUZ", 21: "UINT4", 22: "INT4", 23: "FLOAT4E2M1"]
    static let knownDomains: Set<String> = ["", "ai.onnx", "ai.onnx.ml", "ai.onnx.training", "ai.onnx.preview.training", "com.microsoft",
                                            "com.microsoft.nchwc", "com.microsoft.experimental", "org.pytorch.aten", "com.ms.internal.nhwc"]

    static func read(source: any ByteSource) -> ONNXSummary? {
        // Small windows: the reader hops over weight payloads, and each hop refills the window.
        let reader = AIByteReader(source, budget: AIFormatsLimits.maxModelHeaderBytes, windowSize: 16 * 1024)
        let proto = AIProtobuf(reader: reader)
        // A ModelProto starts with ir_version (field 1, varint): byte 0x08.
        guard let first = try? reader.bytes(at: 0, count: 1, "the first byte"), first == [0x08] else { return nil }

        var s = ONNXSummary(irVersion: nil, producerName: nil, producerVersion: nil, domain: nil, modelVersion: nil, docString: nil,
                            opsets: [], graphName: nil, inputs: [], outputs: [], nodeCount: 0, topOperators: [],
                            initializerCount: 0, parameterCount: 0, externalDataFiles: [], metadata: [], partial: nil,
                            headline: "", facts: [], warnings: [])
        var ops: [String: Int] = [:]
        var customDomains: Set<String> = []
        var initializerNames: Set<String> = []
        var graphInputs: [ModelIO] = []
        var unsafeExternal: [String] = []
        do {
            try proto.fields(in: 0..<reader.size) { f in
                switch (f.number, f.wireType) {
                case (1, 0): s.irVersion = f.int64
                case (2, 2): s.producerName = try proto.string(f, limit: 200)
                case (3, 2): s.producerVersion = try proto.string(f, limit: 200)
                case (4, 2): s.domain = try proto.string(f, limit: 200)
                case (5, 0): s.modelVersion = f.int64
                case (6, 2): s.docString = try proto.string(f, limit: 1000)
                case (8, 2):
                    var domain = "", version: Int64 = 0
                    try proto.fields(in: f.payload) { o in
                        if o.number == 1, o.wireType == 2 { domain = try proto.string(o, limit: 200) }
                        if o.number == 2, o.wireType == 0 { version = o.int64 }
                        return true
                    }
                    if s.opsets.count < 50 { s.opsets.append("\(domain.isEmpty ? "ai.onnx" : domain) \(version)") }
                    if !knownDomains.contains(domain) { customDomains.insert(domain) }
                case (14, 2):
                    var key = "", value = ""
                    try proto.fields(in: f.payload) { e in
                        if e.number == 1, e.wireType == 2 { key = try proto.string(e, limit: 200) }
                        if e.number == 2, e.wireType == 2 { value = try proto.string(e, limit: 300) }
                        return true
                    }
                    if s.metadata.count < 50 { s.metadata.append(AIFact(key, value)) }
                case (7, 2):
                    try proto.fields(in: f.payload) { g in
                        switch (g.number, g.wireType) {
                        case (1, 2):
                            s.nodeCount += 1
                            var op = "?", domain = ""
                            try proto.fields(in: g.payload) { n in
                                if n.number == 4, n.wireType == 2 { op = try proto.string(n, limit: 100) }
                                if n.number == 7, n.wireType == 2 { domain = try proto.string(n, limit: 100) }
                                return true
                            }
                            let label = domain.isEmpty || domain == "ai.onnx" ? op : "\(domain).\(op)"
                            if ops.count < 10_000 || ops[label] != nil { ops[label, default: 0] += 1 }
                        case (2, 2): s.graphName = try proto.string(g, limit: 200)
                        case (5, 2):
                            s.initializerCount += 1
                            let t = try tensor(proto, g)
                            if initializerNames.count < 200_000 { initializerNames.insert(t.name) }
                            if let p = s.parameterCount, let e = t.elements, !p.addingReportingOverflow(e).overflow { s.parameterCount = p + e }
                            else { s.parameterCount = nil }
                            if let location = t.location {
                                if !s.externalDataFiles.contains(location), s.externalDataFiles.count < 50 { s.externalDataFiles.append(location) }
                                if location.hasPrefix("/") || location.hasPrefix("~") || location.split(separator: "/").contains("..")
                                    || location.contains("\\") || location.contains(":") {
                                    if !unsafeExternal.contains(location) { unsafeExternal.append(location) }
                                }
                            }
                        case (11, 2): if graphInputs.count < 2_000 { graphInputs.append(try valueInfo(proto, g)) }
                        case (12, 2): if s.outputs.count < 500 { s.outputs.append(try valueInfo(proto, g)) }
                        default: break
                        }
                        return true
                    }
                default: break
                }
                return true
            }
        } catch let error as AIReadError {
            s.partial = error.reason
        } catch {
            s.partial = "\(error)"
        }
        guard s.irVersion != nil, s.graphName != nil || s.nodeCount > 0 || s.producerName != nil || !s.opsets.isEmpty else { return nil }

        // Older exporters list every initializer as a graph input too; those are weights, not inputs.
        s.inputs = Array(graphInputs.filter { !initializerNames.contains($0.name) }.prefix(500))
        s.topOperators = ops.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10)
            .map { AIFact($0.key, AIFormat.count($0.value)) }

        if let partial = s.partial {
            s.warnings.append(AIWarning(.caution, String(localized: "The model could not be read to its end: \(partial) Inputs, outputs or opsets after that point are missing.", bundle: .module, comment: "Warning on an ONNX model card. The argument is a sentence saying why.")))
        }
        for location in unsafeExternal {
            s.warnings.append(AIWarning(.danger, String(localized: "A weight file is named by a path outside the model's folder (\(location)); loading the model would read that file, a known path-traversal trick.", bundle: .module, comment: "Danger on an ONNX model card. The argument is a file path."), subject: location))
        }
        if !customDomains.isEmpty {
            let domains = customDomains.sorted().joined(separator: ", ")
            s.warnings.append(AIWarning(.caution, String(localized: "It uses custom operator domains (\(domains)); running it needs a native custom-op library, which is code you must trust.", bundle: .module, comment: "Warning on an ONNX model card. The argument lists operator domains such as com.example.ops.")))
        }

        var format = "ONNX"
        if let ir = s.irVersion {
            let version = Int(clamping: ir)
            format = String(localized: "ONNX (IR version \(version))", bundle: .module, comment: "The format of an ONNX model. The argument is its IR version number.")
        }
        var facts: [AIFact] = [AIFact(AIFormat.formatLabel, format)]
        if let p = s.producerName {
            facts.append(AIFact(String(localized: "Producer", bundle: .module, comment: "Fact label on an ONNX model card: the tool that exported it."), p + (s.producerVersion.map { " \($0)" } ?? "")))
        }
        if !s.opsets.isEmpty {
            facts.append(AIFact(String(localized: "Opsets", bundle: .module, comment: "Fact label on an ONNX model card: operator set versions."), s.opsets.joined(separator: ", ")))
        }
        if let g = s.graphName, !g.isEmpty { facts.append(AIFact(String(localized: "Graph", bundle: .module, comment: "Fact label on an ONNX model card: the graph's name."), g)) }
        for io in s.inputs.prefix(8) { facts.append(AIFact(AIFormat.inputLabel, describe(io))) }
        for io in s.outputs.prefix(8) { facts.append(AIFact(AIFormat.outputLabel, describe(io))) }
        facts.append(AIFact(String(localized: "Nodes", bundle: .module, comment: "Fact label on an ONNX model card: the number of operations in its graph."), AIFormat.count(s.nodeCount)))
        if !s.topOperators.isEmpty {
            facts.append(AIFact(String(localized: "Top operators", bundle: .module, comment: "Fact label on an ONNX model card: the most used operations."),
                                s.topOperators.prefix(5).map { "\($0.label) × \($0.value)" }.joined(separator: ", ")))
        }
        facts.append(AIFact(String(localized: "Initializers", bundle: .module, comment: "Fact label on an ONNX model card: the number of stored weight tensors."), AIFormat.count(s.initializerCount)))
        if let p = s.parameterCount, p > 0 { facts.append(AIFact(AIFormat.parametersLabel, AIFormat.parameters(p))) }
        if !s.externalDataFiles.isEmpty {
            facts.append(AIFact(String(localized: "External weights", bundle: .module, comment: "Fact label on an ONNX model card: files its weights are stored in."), s.externalDataFiles.joined(separator: ", ")))
        }
        if let d = s.docString, !d.isEmpty { facts.append(AIFact(AIFormat.descriptionLabel, AIFormat.clip(d, 300))) }
        s.facts = facts
        let nodes = s.nodeCount
        var headline: String
        if let g = s.graphName, !g.isEmpty {
            headline = String(localized: "ONNX model “\(g)” · \(nodes) nodes", bundle: .module, comment: "Headline of an ONNX model card. The graph's name, then its number of operations (plural forms).")
        } else {
            headline = String(localized: "ONNX model · \(nodes) nodes", bundle: .module, comment: "Headline of an ONNX model card. The argument is its number of operations (plural forms).")
        }
        if let p = s.parameterCount, p > 0 { headline += " · \(AIFormat.parameters(p))" }
        s.headline = headline
        return s
    }

    static func describe(_ io: ModelIO) -> String {
        "\(io.name): \(io.type)" + (io.shape.isEmpty ? "" : " " + AIFormat.shape(io.shape))
    }

    /// A TensorProto's name, element count and external location; `raw_data` is never read.
    static func tensor(_ proto: AIProtobuf, _ f: AIProtoField) throws -> (name: String, elements: Int64?, location: String?) {
        var name = "", dims: [Int64] = [], location: String?
        var external = false
        var entries: [(String, String)] = []
        try proto.fields(in: f.payload) { t in
            switch (t.number, t.wireType) {
            case (1, _): dims += try proto.varints(t).map { Int64(bitPattern: $0) }
            case (8, 2): name = try proto.string(t, limit: 300)
            case (13, 2):
                var k = "", v = ""
                try proto.fields(in: t.payload) { e in
                    if e.number == 1, e.wireType == 2 { k = try proto.string(e, limit: 100) }
                    if e.number == 2, e.wireType == 2 { v = try proto.string(e, limit: 1024) }
                    return true
                }
                entries.append((k, v))
            case (14, 0): external = t.value == 1
            default: break
            }
            return true
        }
        if external || !entries.isEmpty { location = entries.first { $0.0 == "location" }?.1 }
        return (name, AIFormat.product(dims), location)
    }

    /// A ValueInfoProto: name and tensor type with shape.
    static func valueInfo(_ proto: AIProtobuf, _ f: AIProtoField) throws -> ModelIO {
        var io = ModelIO(name: "", type: "?", shape: [], detail: nil)
        try proto.fields(in: f.payload) { v in
            if v.number == 1, v.wireType == 2 { io.name = try proto.string(v, limit: 300) }
            if v.number == 2, v.wireType == 2 {
                try proto.fields(in: v.payload) { t in
                    switch (t.number, t.wireType) {
                    case (1, 2), (8, 2):   // tensor_type, sparse_tensor_type
                        try proto.fields(in: t.payload) { tt in
                            if tt.number == 1, tt.wireType == 0 { io.type = Int(exactly: tt.value).flatMap { elementTypes[$0] } ?? "type \(tt.value)" }
                            if tt.number == 2, tt.wireType == 2 {
                                try proto.fields(in: tt.payload) { d in
                                    guard d.number == 1, d.wireType == 2, io.shape.count < 16 else { return true }
                                    var dim = "?"
                                    try proto.fields(in: d.payload) { x in
                                        if x.number == 1, x.wireType == 0 { dim = "\(x.int64)" }
                                        if x.number == 2, x.wireType == 2 { dim = try proto.string(x, limit: 60) }
                                        return true
                                    }
                                    io.shape.append(dim)
                                    return true
                                }
                            }
                            return true
                        }
                        if t.number == 8 { io.detail = "sparse" }
                    case (4, 2): io.type = "sequence"
                    case (5, 2): io.type = "map"
                    case (9, 2): io.type = "optional"
                    default: break
                    }
                    return true
                }
            }
            return true
        }
        return io
    }
}
