import Foundation
import VitrineSupport

/// One GGUF metadata key with its type and value as display text (arrays summarised: type, count, first items).
/// roadmap: S-21
public struct GGUFMetadataEntry: Sendable, Equatable {
    public var key: String
    /// "uint32", "string", "array<string>" …
    public var type: String
    public var value: String
    /// Element count for arrays.
    public var arrayCount: Int?
}

/// One tensor's name, shape and storage type. roadmap: S-21
public struct GGUFTensor: Sendable, Equatable {
    public var name: String
    public var shape: [Int64]
    /// The ggml type name (F16, Q4_K, …).
    public var type: String
    public var elementCount: Int64?
}

/// A GGUF model header (llama.cpp's format, v1–v3): every metadata key, the facts a model card needs, and the first
/// tensors. Nothing past the tensor table is read. roadmap: S-21
public struct GGUFSummary: Sendable, Equatable {
    public var version: Int
    public var bigEndian: Bool
    public var tensorCount: Int64
    public var metadataCount: Int64
    public var metadata: [GGUFMetadataEntry]
    public var metadataTruncated: Bool
    public var architecture: String?
    public var name: String?
    /// The sum of every tensor's elements; nil when the tensor table was not read to its end.
    public var parameterCount: Int64?
    /// `general.size_label` (e.g. "8B").
    public var sizeLabel: String?
    /// The quantisation (`general.file_type`), e.g. "Q4_K_M".
    public var fileType: String?
    public var contextLength: Int64?
    public var embeddingLength: Int64?
    public var blockCount: Int64?
    public var headCount: Int64?
    public var headCountKV: Int64?
    public var vocabSize: Int64?
    public var license: String?
    public var tokenizerModel: String?
    public var hasChatTemplate: Bool
    /// The first 50 tensors.
    public var tensors: [GGUFTensor]
    /// Tensor counts per ggml type.
    public var tensorTypes: [String: Int]
    /// Where the tensor data starts, when the table was read to its end.
    public var dataOffset: Int64?
    /// Why reading stopped before the end of the header.
    public var partial: String?
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]
}

enum GGUFReader {
    static let maxTensorsListed = 50
    static let maxTemplateBytes = 1 << 20

    enum Value {
        case int(Int64), uint(UInt64), float(Double), bool(Bool), string(String), array(type: String, count: Int, preview: [String])
        var display: String {
            switch self {
            case .int(let v): "\(v)"
            case .uint(let v): "\(v)"
            case .float(let v): "\(v)"
            case .bool(let v): v ? "true" : "false"
            case .string(let s): AIFormat.clip(s, 200)
            case .array(_, let count, let preview):
                "[" + preview.joined(separator: ", ") + (count > preview.count ? ", …" : "") + "] "
                    + String(localized: "(\(count) items)", bundle: .module, comment: "After a list's first values on a GGUF model card: its length (plural forms).")
            }
        }
        var integer: Int64? {
            switch self {
            case .int(let v): v
            case .uint(let v): v <= UInt64(Int64.max) ? Int64(v) : nil
            default: nil
            }
        }
        var string: String? { if case .string(let s) = self { s } else { nil } }
    }

    static let typeNames = ["uint8", "int8", "uint16", "int16", "uint32", "int32", "float32", "bool", "string", "array",
                            "uint64", "int64", "float64"]

    static func read(source: any ByteSource) -> GGUFSummary? {
        let reader = AIByteReader(source, budget: AIFormatsLimits.maxModelHeaderBytes)
        guard let magic = try? reader.bytes(at: 0, count: 8, "the header"), magic.starts(with: Array("GGUF".utf8)) else { return nil }
        let le = UInt32(magic[4]) | UInt32(magic[5]) << 8 | UInt32(magic[6]) << 16 | UInt32(magic[7]) << 24
        let be = UInt32(magic[7]) | UInt32(magic[6]) << 8 | UInt32(magic[5]) << 16 | UInt32(magic[4]) << 24
        let bigEndian = le > 0xFFFF && be <= 0xFFFF
        let version = Int(bigEndian ? be : le)
        var cursor = AICursor(reader, at: 8, bigEndian: bigEndian)

        var metadata: [GGUFMetadataEntry] = []
        var values: [String: Value] = [:]
        var tensors: [GGUFTensor] = []
        var tensorTypes: [String: Int] = [:]
        var parameters: Int64? = 0
        var dataOffset: Int64?
        var partial: String?
        var tensorCount: Int64 = 0, kvCount: Int64 = 0
        var template: String?
        var warnings: [AIWarning] = []

        do {
            guard (1...3).contains(version) else { throw AIReadError.malformed("GGUF version \(version) is not one this reader knows (1–3)") }
            if version == 1 {
                tensorCount = Int64(try cursor.u32("the tensor count")); kvCount = Int64(try cursor.u32("the metadata count"))
            } else {
                let t = try cursor.u64("the tensor count"), k = try cursor.u64("the metadata count")
                guard t < 10_000_000, k < 10_000_000 else { throw AIReadError.malformed("it declares \(t) tensors and \(k) metadata keys") }
                tensorCount = Int64(t); kvCount = Int64(k)
            }
            for _ in 0..<kvCount {
                let key = try string(&cursor, version: version, "a metadata key")
                let type = try cursor.u32("the type of \(key)")
                if key == "tokenizer.chat_template", type == 8 {
                    let full = try string(&cursor, version: version, key, keep: maxTemplateBytes)
                    template = full
                    values[key] = .string(full)
                    if metadata.count < AIFormatsLimits.maxListItems {
                        metadata.append(GGUFMetadataEntry(key: key, type: "string", value: AIFormat.clip(full, 200), arrayCount: nil))
                    }
                    continue
                }
                let value = try readValue(&cursor, type: type, version: version, key: key, depth: 0)
                values[key] = value
                if metadata.count < AIFormatsLimits.maxListItems {
                    var typeName = type < typeNames.count ? typeNames[Int(type)] : "type \(type)"
                    var count: Int?
                    if case .array(let inner, let n, _) = value { typeName = "array<\(inner)>"; count = n }
                    metadata.append(GGUFMetadataEntry(key: key, type: typeName, value: value.display, arrayCount: count))
                }
            }
            for i in 0..<tensorCount {
                let name = try string(&cursor, version: version, "a tensor name")
                let dims = Int(try cursor.u32("the dimensions of \(name)"))
                guard dims <= 8 else { throw AIReadError.malformed("tensor \(name) has \(dims) dimensions") }
                var shape: [Int64] = []
                for _ in 0..<dims {
                    let d = version == 1 ? UInt64(try cursor.u32("a dimension")) : try cursor.u64("a dimension")
                    shape.append(d > UInt64(Int64.max) ? -1 : Int64(d))
                }
                let type = try cursor.u32("the type of \(name)")
                _ = try cursor.u64("the offset of \(name)")
                let typeName = ggmlType(type)
                tensorTypes[typeName, default: 0] += 1
                let elements = AIFormat.product(shape)
                if let p = parameters, let e = elements { parameters = p.addingReportingOverflow(e).overflow ? nil : p + e } else { parameters = nil }
                if i < maxTensorsListed { tensors.append(GGUFTensor(name: name, shape: shape, type: typeName, elementCount: elements)) }
            }
            let alignment = values["general.alignment"]?.integer.flatMap { $0 > 0 && $0 <= 1 << 20 ? $0 : nil } ?? 32
            dataOffset = (cursor.offset + alignment - 1) / alignment * alignment
        } catch let error as AIReadError {
            partial = error.reason
            parameters = nil
        } catch {
            partial = "\(error)"
            parameters = nil
        }

        let arch = values["general.architecture"]?.string
        func archInt(_ suffix: String) -> Int64? { arch.flatMap { values["\($0).\(suffix)"]?.integer } }
        var vocab = archInt("vocab_size")
        if vocab == nil, case .array(_, let n, _)? = values["tokenizer.ggml.tokens"] { vocab = Int64(n) }
        let fileType = values["general.file_type"]?.integer.map(fileTypeName)
        let name = values["general.name"]?.string
        let license = values["general.license"]?.string
        let tokenizer = values["tokenizer.ggml.model"]?.string
        let sizeLabel = values["general.size_label"]?.string

        if let template {
            let markers = ["__class__", "__globals__", "__subclasses__", "__builtins__", "__import__", "__init__", "__mro__", "__base__", "os.popen", "subprocess", "lipsum", "cycler.__init__"]
            let found = markers.filter { template.contains($0) }
            if !found.isEmpty {
                let markers = found.prefix(3).joined(separator: ", ")
                warnings.append(AIWarning(.danger, String(localized: "The chat template reaches into Python internals (\(markers)), the pattern of a template-injection attack that runs code in loaders that render it with Jinja.", bundle: .module, comment: "Danger on a GGUF model card. The argument lists Python names such as __globals__; Jinja is a product name."), subject: "tokenizer.chat_template"))
            }
        }
        if let partial {
            warnings.append(AIWarning(.caution, String(localized: "The header could not be read to its end: \(partial)", bundle: .module, comment: "Warning on a GGUF model card. The argument is a sentence saying why.")))
        }

        let format = bigEndian
            ? String(localized: "GGUF v\(version) (big-endian)", bundle: .module, comment: "The format of a GGUF model file. The argument is its version number.")
            : "GGUF v\(version)"
        var facts: [AIFact] = [AIFact(AIFormat.formatLabel, format)]
        if let arch { facts.append(AIFact(String(localized: "Architecture", bundle: .module, comment: "Fact label on a GGUF model card, such as llama."), arch)) }
        if let name { facts.append(AIFact(AIFormat.nameLabel, name)) }
        if let parameters, parameters > 0 { facts.append(AIFact(AIFormat.parametersLabel, AIFormat.parameters(parameters))) }
        else if let sizeLabel { facts.append(AIFact(String(localized: "Size", bundle: .module, comment: "Fact label on a GGUF model card: its size label, such as 8B."), sizeLabel)) }
        if let fileType { facts.append(AIFact(String(localized: "Quantisation", bundle: .module, comment: "Fact label on a GGUF model card: how its weights are compressed, such as Q4_K_M."), fileType)) }
        if let v = archInt("context_length") {
            facts.append(AIFact(String(localized: "Context length", bundle: .module, comment: "Fact label on a GGUF model card: the most tokens it reads at once."), AIFormat.count(v)))
        }
        if let v = archInt("embedding_length") {
            facts.append(AIFact(String(localized: "Embedding length", bundle: .module, comment: "Fact label on a GGUF model card."), AIFormat.count(v)))
        }
        if let v = archInt("block_count") {
            facts.append(AIFact(String(localized: "Blocks", bundle: .module, comment: "Fact label on a GGUF model card: its number of transformer layers."), AIFormat.count(v)))
        }
        if let v = archInt("attention.head_count") {
            let heads = AIFormat.count(v)
            let value: String
            if let kv = archInt("attention.head_count_kv") {
                let kvHeads = AIFormat.count(kv)
                value = String(localized: "\(heads) (\(kvHeads) key/value)", bundle: .module, comment: "Attention heads on a GGUF model card: query heads, then key/value heads.")
            } else { value = heads }
            facts.append(AIFact(String(localized: "Attention heads", bundle: .module, comment: "Fact label on a GGUF model card."), value))
        }
        if let vocab { facts.append(AIFact(AIFormat.vocabularyLabel, AIFormat.count(vocab))) }
        if let tokenizer { facts.append(AIFact(AIFormat.tokenizerLabel, tokenizer)) }
        if let license { facts.append(AIFact(AIFormat.licenseLabel, license)) }
        facts.append(AIFact(AIFormat.tensorsLabel, AIFormat.count(tensorCount)))
        facts.append(AIFact(String(localized: "Metadata keys", bundle: .module, comment: "Fact label on a GGUF model card."), AIFormat.count(kvCount)))
        if template != nil {
            facts.append(AIFact(String(localized: "Chat template", bundle: .module, comment: "Fact label on a GGUF model card: whether it carries a chat prompt template."), AIFormat.yes))
        }

        var headline: String
        if let name { headline = name }
        else if let arch { headline = String(localized: "\(arch) model", bundle: .module, comment: "Headline of a GGUF model card without a name. The argument is an architecture such as llama.") }
        else { headline = String(localized: "GGUF model", bundle: .module, comment: "Headline of a GGUF model card without a name or architecture.") }
        var extras: [String] = []
        if let parameters, parameters > 0 { extras.append(AIFormat.parameters(parameters)) } else if let sizeLabel { extras.append(sizeLabel) }
        if let fileType { extras.append(fileType) }
        if !extras.isEmpty { headline += " · " + extras.joined(separator: " · ") }

        return GGUFSummary(version: version, bigEndian: bigEndian, tensorCount: tensorCount, metadataCount: kvCount,
                           metadata: metadata, metadataTruncated: Int64(metadata.count) < kvCount, architecture: arch, name: name,
                           parameterCount: parameters, sizeLabel: sizeLabel, fileType: fileType,
                           contextLength: archInt("context_length"), embeddingLength: archInt("embedding_length"),
                           blockCount: archInt("block_count"), headCount: archInt("attention.head_count"),
                           headCountKV: archInt("attention.head_count_kv"), vocabSize: vocab, license: license,
                           tokenizerModel: tokenizer, hasChatTemplate: template != nil, tensors: tensors,
                           tensorTypes: tensorTypes, dataOffset: dataOffset, partial: partial, headline: headline,
                           facts: facts, warnings: warnings)
    }

    /// A GGUF string: a length (u64; u32 in v1) and UTF-8 bytes. Longer than `keep` is skipped past and clipped.
    static func string(_ cursor: inout AICursor, version: Int, _ what: String, keep: Int = 64 * 1024) throws -> String {
        let length = version == 1 ? UInt64(try cursor.u32("the length of \(what)")) : try cursor.u64("the length of \(what)")
        guard length <= UInt64(cursor.remaining) else { throw AIReadError.truncated("inside \(what)") }
        let n = Int64(length)
        if n <= Int64(keep) { return AIFormat.text(try cursor.take(Int(n), what)) }
        let head = try cursor.take(keep, what)
        try cursor.skip(n - Int64(keep), what)
        return AIFormat.text(head) + "…"
    }

    static func readValue(_ cursor: inout AICursor, type: UInt32, version: Int, key: String, depth: Int) throws -> Value {
        switch type {
        case 0: return .uint(UInt64(try cursor.u8(key)))
        case 1: return .int(Int64(Int8(bitPattern: try cursor.u8(key))))
        case 2: return .uint(UInt64(try cursor.u16(key)))
        case 3: return .int(Int64(Int16(bitPattern: try cursor.u16(key))))
        case 4: return .uint(UInt64(try cursor.u32(key)))
        case 5: return .int(Int64(Int32(bitPattern: try cursor.u32(key))))
        case 6: return .float(Double(Float(bitPattern: try cursor.u32(key))))
        case 7: return .bool(try cursor.u8(key) != 0)
        case 8: return .string(try string(&cursor, version: version, key, keep: 4096))
        case 10: return .uint(try cursor.u64(key))
        case 11: return .int(Int64(bitPattern: try cursor.u64(key)))
        case 12: return .float(Double(bitPattern: try cursor.u64(key)))
        case 9:
            guard depth < 3 else { throw AIReadError.malformed("\(key) nests arrays too deeply") }
            let inner = try cursor.u32("the element type of \(key)")
            let count = version == 1 ? UInt64(try cursor.u32("the length of \(key)")) : try cursor.u64("the length of \(key)")
            guard count <= UInt64(cursor.remaining) else { throw AIReadError.truncated("inside \(key)") }
            let n = Int(count)
            let innerName = inner < typeNames.count ? typeNames[Int(inner)] : "type \(inner)"
            let fixed: [UInt32: Int64] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
            var preview: [String] = []
            if let width = fixed[inner] {
                for _ in 0..<min(n, 8) { preview.append(try readValue(&cursor, type: inner, version: version, key: key, depth: depth + 1).display) }
                if n > 8 { try cursor.skip(Int64(n - 8) * width, key) }
            } else {
                for i in 0..<n {
                    if inner == 8 {
                        let s = try string(&cursor, version: version, key, keep: i < 8 ? 200 : 0)
                        if i < 8 { preview.append("“\(s)”") }
                    } else {
                        let v = try readValue(&cursor, type: inner, version: version, key: key, depth: depth + 1)
                        if i < 8 { preview.append(v.display) }
                    }
                }
            }
            return .array(type: innerName, count: n, preview: preview)
        default:
            throw AIReadError.malformed("\(key) has unknown value type \(type)")
        }
    }

    static func ggmlType(_ t: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 6: "Q5_0", 7: "Q5_1", 8: "Q8_0", 9: "Q8_1", 10: "Q2_K", 11: "Q3_K",
            12: "Q4_K", 13: "Q5_K", 14: "Q6_K", 15: "Q8_K", 16: "IQ2_XXS", 17: "IQ2_XS", 18: "IQ3_XXS", 19: "IQ1_S",
            20: "IQ4_NL", 21: "IQ3_S", 22: "IQ2_S", 23: "IQ4_XS", 24: "I8", 25: "I16", 26: "I32", 27: "I64", 28: "F64",
            29: "IQ1_M", 30: "BF16", 34: "TQ1_0", 35: "TQ2_0", 39: "MXFP4",
        ]
        return names[t] ?? "type \(t)"
    }

    static func fileTypeName(_ t: Int64) -> String {
        let names: [Int64: String] = [
            0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 4: "Q4_1_SOME_F16", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1", 10: "Q2_K",
            11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K",
            19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL", 26: "IQ3_S",
            27: "IQ3_M", 28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M", 32: "BF16", 36: "TQ1_0", 37: "TQ2_0",
            38: "MXFP4_MOE",
        ]
        return names[t] ?? "file type \(t)"
    }
}
