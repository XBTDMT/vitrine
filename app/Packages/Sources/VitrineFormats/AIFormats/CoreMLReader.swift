import Foundation
import VitrineSupport

/// A Core ML model's header: a `.mlmodel` spec, or the spec inside an `.mlpackage` (found through Manifest.json):
/// specification version, model type, inputs and outputs, and the author, license and description metadata.
/// roadmap: S-21
public struct CoreMLSummary: Sendable, Equatable {
    public var isPackage: Bool
    public var specificationVersion: Int64?
    /// neuralNetwork, mlProgram, pipeline, treeEnsembleClassifier …
    public var modelType: String?
    public var inputs: [ModelIO]
    public var outputs: [ModelIO]
    public var shortDescription: String?
    public var author: String?
    public var license: String?
    public var version: String?
    public var userMetadata: [AIFact]
    public var isUpdatable: Bool
    /// ML Program functions (main …) and their opset.
    public var programFunctions: [String]
    /// Package items from Manifest.json: path and size.
    public var packageItems: [AIFact]
    public var partial: String?
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]
}

enum CoreMLReader {
    static let modelTypes: [Int: String] = [
        200: "pipelineClassifier", 201: "pipelineRegressor", 202: "pipeline", 300: "glmRegressor", 301: "supportVectorRegressor",
        302: "treeEnsembleRegressor", 303: "neuralNetworkRegressor", 304: "bayesianProbitRegressor", 400: "glmClassifier",
        401: "supportVectorClassifier", 402: "treeEnsembleClassifier", 403: "neuralNetworkClassifier",
        404: "kNearestNeighborsClassifier", 500: "neuralNetwork", 501: "itemSimilarityRecommender", 502: "mlProgram",
        555: "customModel", 556: "linkedModel", 560: "classConfidenceThresholding", 600: "oneHotEncoder", 601: "imputer",
        602: "featureVectorizer", 603: "dictVectorizer", 604: "scaler", 606: "categoricalMapping", 607: "normalizer",
        609: "arrayFeatureExtractor", 610: "nonMaximumSuppression", 900: "identity", 2000: "textClassifier", 2001: "wordTagger",
        2002: "visionFeaturePrint", 2003: "soundAnalysisPreprocessing", 2004: "gazetteer", 2005: "wordEmbedding",
        2006: "audioFeaturePrint", 3000: "serializedModel",
    ]
    static let arrayTypes: [UInt64: String] = [65568: "FLOAT32", 65600: "DOUBLE", 131104: "INT32", 65552: "FLOAT16", 131080: "INT8"]
    static let colorSpaces: [UInt64: String] = [10: "grayscale", 20: "RGB", 30: "BGR", 40: "grayscale float16"]

    static func read(source: any ByteSource, fileName: String) -> CoreMLSummary? {
        read(source: source, isPackage: false, packageItems: [], packageWarnings: [])
    }

    static func read(source: any ByteSource, isPackage: Bool, packageItems: [AIFact], packageWarnings: [AIWarning]) -> CoreMLSummary? {
        let reader = AIByteReader(source, budget: AIFormatsLimits.maxModelHeaderBytes, windowSize: 16 * 1024)
        let proto = AIProtobuf(reader: reader)
        // A Model starts with specificationVersion (field 1, varint): byte 0x08.
        guard let first = try? reader.bytes(at: 0, count: 1, "the first byte"), first == [0x08] else { return nil }
        var s = CoreMLSummary(isPackage: isPackage, specificationVersion: nil, modelType: nil, inputs: [], outputs: [],
                              shortDescription: nil, author: nil, license: nil, version: nil, userMetadata: [],
                              isUpdatable: false, programFunctions: [], packageItems: packageItems, partial: nil,
                              headline: "", facts: [], warnings: packageWarnings)
        do {
            try proto.fields(in: 0..<reader.size) { f in
                switch (f.number, f.wireType) {
                case (1, 0): s.specificationVersion = f.int64
                case (2, 2): try description(proto, f, into: &s)
                case (10, 0): s.isUpdatable = f.value != 0
                case (let n, 2) where n >= 200:
                    if s.modelType == nil { s.modelType = modelTypes[n] ?? "model type \(n)" }
                    if n == 502 { s.programFunctions = try programFunctions(proto, f) }
                default: break
                }
                return true
            }
        } catch let error as AIReadError {
            s.partial = error.reason
        } catch {
            s.partial = "\(error)"
        }
        guard s.specificationVersion != nil, s.modelType != nil || !s.inputs.isEmpty || !s.outputs.isEmpty || s.partial != nil else { return nil }

        if s.modelType == "customModel" {
            s.warnings.append(AIWarning(.caution, String(localized: "It is a custom model: native code shipped with an app does the work, so the file alone does not say what runs.", bundle: .module, comment: "Warning on a Core ML model card.")))
        }
        if s.modelType == "linkedModel" {
            s.warnings.append(AIWarning(.caution, String(localized: "It links to another model file by name, which this card cannot see.", bundle: .module, comment: "Warning on a Core ML model card.")))
        }
        if let partial = s.partial {
            s.warnings.append(AIWarning(.caution, String(localized: "The model could not be read to its end: \(partial)", bundle: .module, comment: "Warning on a Core ML model card. The argument is a sentence saying why.")))
        }
        let format = isPackage
            ? String(localized: "Core ML package (.mlpackage)", bundle: .module, comment: "The format of a Core ML model. Core ML is a product name.")
            : String(localized: "Core ML model (.mlmodel)", bundle: .module, comment: "The format of a Core ML model. Core ML is a product name.")
        var facts = [AIFact(AIFormat.formatLabel, format)]
        if let t = s.modelType { facts.append(AIFact(String(localized: "Model type", bundle: .module, comment: "Fact label on a Core ML model card, such as neuralNetwork."), t)) }
        if let v = s.specificationVersion {
            facts.append(AIFact(String(localized: "Specification version", bundle: .module, comment: "Fact label on a Core ML model card."), "\(v)"))
        }
        if !s.programFunctions.isEmpty {
            facts.append(AIFact(String(localized: "Functions", bundle: .module, comment: "Fact label on a Core ML ML Program card: its function names."), s.programFunctions.joined(separator: ", ")))
        }
        for io in s.inputs.prefix(8) { facts.append(AIFact(AIFormat.inputLabel, ONNXReader.describe(io))) }
        for io in s.outputs.prefix(8) { facts.append(AIFact(AIFormat.outputLabel, ONNXReader.describe(io))) }
        if let a = s.author { facts.append(AIFact(String(localized: "Author", bundle: .module, comment: "Fact label on a Core ML model card."), a)) }
        if let l = s.license { facts.append(AIFact(AIFormat.licenseLabel, l)) }
        if let v = s.version { facts.append(AIFact(String(localized: "Version", bundle: .module, comment: "Fact label on a Core ML model card."), v)) }
        if let d = s.shortDescription { facts.append(AIFact(AIFormat.descriptionLabel, AIFormat.clip(d, 300))) }
        if s.isUpdatable {
            facts.append(AIFact(String(localized: "Updatable", bundle: .module, comment: "Fact label on a Core ML model card."),
                                String(localized: "yes (can be trained on device)", bundle: .module, comment: "Value of the Updatable fact on a Core ML model card.")))
        }
        facts += s.packageItems
        s.facts = facts
        let type = s.modelType ?? String(localized: "model", bundle: .module, comment: "Stands in for a Core ML model type in a headline when the file does not say.")
        s.headline = String(localized: "Core ML \(type)", bundle: .module, comment: "Headline of a Core ML model card. The argument is a model type such as neuralNetwork.")
            + (s.shortDescription.map { " · \(AIFormat.clip($0, 60))" } ?? "")
        return s
    }

    static func description(_ proto: AIProtobuf, _ f: AIProtoField, into s: inout CoreMLSummary) throws {
        try proto.fields(in: f.payload) { d in
            switch (d.number, d.wireType) {
            case (1, 2): if s.inputs.count < 500 { s.inputs.append(try feature(proto, d)) }
            case (10, 2): if s.outputs.count < 500 { s.outputs.append(try feature(proto, d)) }
            case (100, 2):
                try proto.fields(in: d.payload) { m in
                    switch (m.number, m.wireType) {
                    case (1, 2): s.shortDescription = try proto.string(m, limit: 1000)
                    case (2, 2): s.version = try proto.string(m, limit: 200)
                    case (3, 2): s.author = try proto.string(m, limit: 300)
                    case (4, 2): s.license = try proto.string(m, limit: 300)
                    case (100, 2):
                        var k = "", v = ""
                        try proto.fields(in: m.payload) { e in
                            if e.number == 1, e.wireType == 2 { k = try proto.string(e, limit: 200) }
                            if e.number == 2, e.wireType == 2 { v = try proto.string(e, limit: 300) }
                            return true
                        }
                        if s.userMetadata.count < 50 { s.userMetadata.append(AIFact(k, v)) }
                    default: break
                    }
                    return true
                }
            default: break
            }
            return true
        }
    }

    static func feature(_ proto: AIProtobuf, _ f: AIProtoField) throws -> ModelIO {
        var io = ModelIO(name: "", type: "?", shape: [], detail: nil)
        try proto.fields(in: f.payload) { x in
            switch (x.number, x.wireType) {
            case (1, 2): io.name = try proto.string(x, limit: 300)
            case (2, 2): io.detail = try proto.string(x, limit: 300)
            case (3, 2):
                try proto.fields(in: x.payload) { t in
                    switch t.number {
                    case 1: io.type = "int64"
                    case 2: io.type = "double"
                    case 3: io.type = "string"
                    case 4:
                        io.type = "image"
                        var w: Int64 = 0, h: Int64 = 0, color = ""
                        try proto.fields(in: t.payload) { i in
                            if i.number == 1, i.wireType == 0 { w = i.int64 }
                            if i.number == 2, i.wireType == 0 { h = i.int64 }
                            if i.number == 3, i.wireType == 0 { color = colorSpaces[i.value] ?? "" }
                            return true
                        }
                        io.shape = ["\(w)", "\(h)"]
                        if !color.isEmpty { io.type = "image (\(color))" }
                    case 5:
                        io.type = "multiArray"
                        try proto.fields(in: t.payload) { a in
                            if a.number == 1 { io.shape += try proto.varints(a).prefix(16).map { "\(Int64(bitPattern: $0))" } }
                            if a.number == 2, a.wireType == 0 { io.type = "multiArray \(arrayTypes[a.value] ?? "type \(a.value)")" }
                            return true
                        }
                    case 6: io.type = "dictionary"
                    case 7: io.type = "sequence"
                    case 8: io.type = "state"
                    default: break
                    }
                    return true
                }
            default: break
            }
            return true
        }
        return io
    }

    /// An ML Program's function names (field 2 is a map<string, Function>) with each one's opset.
    static func programFunctions(_ proto: AIProtobuf, _ f: AIProtoField) throws -> [String] {
        var out: [String] = []
        try proto.fields(in: f.payload) { p in
            guard p.number == 2, p.wireType == 2, out.count < 20 else { return true }
            var name = "", opset = ""
            try proto.fields(in: p.payload) { e in
                if e.number == 1, e.wireType == 2 { name = try proto.string(e, limit: 100) }
                if e.number == 2, e.wireType == 2 {
                    try proto.fields(in: e.payload) { fn in
                        if fn.number == 2, fn.wireType == 2 { opset = try proto.string(fn, limit: 60) }
                        return true
                    }
                }
                return true
            }
            out.append(opset.isEmpty ? name : "\(name) (\(opset))")
            return true
        }
        return out
    }

    /// An `.mlpackage` folder: Manifest.json names the root model spec; the spec is read with the same bounds as an
    /// `.mlmodel`. Paths never leave the package.
    static func readPackage(_ directory: URL) -> CoreMLSummary? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = root.appendingPathComponent("Manifest.json")
        guard let manifestSource = try? BoundedFileSource<AIReadError>(url: manifestURL),
              let manifestBytes = try? manifestSource.read(at: 0, count: Int(AIFormatsLimits.maxOtherBytes)) else { return nil }
        let (rootView, _) = AIJSONView.parse(manifestBytes, format: .json, maxDepth: 8, maxNodes: 50_000)
        guard let manifest = rootView, let entries = manifest["itemInfoEntries"], entries.isObject else { return nil }
        let rootID = manifest["rootModelIdentifier"]?.string
        var warnings: [AIWarning] = []
        var items: [AIFact] = []
        var specPath: String?
        let dataFolder = root.appendingPathComponent("Data")
        func inside(_ relative: String) -> URL? {
            let url = dataFolder.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            return url.path.hasPrefix(root.path + "/") ? url : nil
        }
        for entry in entries.children.prefix(100) {
            guard let path = entry["path"]?.string else { continue }
            guard let url = inside(path) else {
                warnings.append(AIWarning(.danger, String(localized: "Manifest.json names a file outside the package (\(path)); a loader following it would read elsewhere on the disk.", bundle: .module, comment: "Danger on a Core ML package card. The argument is a file path; Manifest.json is a file name."), subject: path))
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            items.append(AIFact(String(localized: "Item", bundle: .module, comment: "Fact label on a Core ML package card: one file inside the package."),
                                path + (size.map { " (\(AIFormat.bytes($0)))" } ?? "")))
            if entry.name == rootID { specPath = url.path }
        }
        guard let specPath, let spec = try? BoundedFileSource<AIReadError>(url: URL(fileURLWithPath: specPath)) else { return nil }
        return read(source: spec, isPackage: true, packageItems: items, packageWarnings: warnings)
    }
}
