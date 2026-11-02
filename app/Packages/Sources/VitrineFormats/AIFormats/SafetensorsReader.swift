import Foundation
import VitrineData
import VitrineSupport

/// A safetensors header: the JSON table in front of the weights — tensor count, dtypes, total parameters and the
/// free-form `__metadata__`. Only the 8-byte length and the header are read. roadmap: S-21
public struct SafetensorsSummary: Sendable, Equatable {
    /// One tensor's name, dtype and shape. roadmap: S-21
    public struct Tensor: Sendable, Equatable {
        public var name: String
        public var dtype: String
        public var shape: [Int64]
    }

    public var headerLength: Int64
    public var tensorCount: Int
    /// Tensor counts per dtype (F16, BF16, F32 …).
    public var dtypes: [String: Int]
    /// The sum of every tensor's elements, nil when a shape overflowed.
    public var parameterCount: Int64?
    /// Bytes the tensors' data offsets cover.
    public var dataBytes: Int64
    /// `__metadata__`, string to string (at most 50 entries, values clipped).
    public var metadata: [AIFact]
    /// The first 50 tensors, in header order.
    public var tensors: [Tensor]
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]
}

enum SafetensorsReader {
    static let dtypeBits: [String: Int] = [
        "F64": 64, "F32": 32, "F16": 16, "BF16": 16, "I64": 64, "I32": 32, "I16": 16, "I8": 8, "U64": 64, "U32": 32,
        "U16": 16, "U8": 8, "BOOL": 8, "F8_E4M3": 8, "F8_E5M2": 8, "F8_E8M0": 8, "C64": 64, "F6_E2M3": 6, "F6_E3M2": 6, "F4": 4,
    ]

    static func read(source: any ByteSource) -> SafetensorsSummary? {
        let reader = AIByteReader(source, budget: AIFormatsLimits.maxModelHeaderBytes)
        guard let lengthBytes = try? reader.bytes(at: 0, count: 8, "the header length") else { return nil }
        var length: UInt64 = 0
        for (i, b) in lengthBytes.enumerated() { length |= UInt64(b) << (8 * UInt64(i)) }
        let headerLabel = String(localized: "Header", bundle: .module, comment: "Fact label on a safetensors card: the size of its JSON header.")
        let claimed = AIFormat.bytes(Int64(clamping: length))
        func failed(_ why: String) -> SafetensorsSummary {
            SafetensorsSummary(headerLength: Int64(clamping: length), tensorCount: 0, dtypes: [:], parameterCount: nil, dataBytes: 0,
                               metadata: [], tensors: [],
                               headline: String(localized: "safetensors (unreadable header)", bundle: .module, comment: "Headline of a safetensors card whose header could not be read. safetensors is a format name."),
                               facts: [AIFact(headerLabel, claimed)], warnings: [AIWarning(.caution, why)])
        }
        guard length >= 2 else {
            let bytes = Int(length)
            return failed(String(localized: "The header length is \(bytes) bytes, too short to hold a table: the file is damaged.", bundle: .module, comment: "Warning on a safetensors card. The argument is a byte count."))
        }
        guard length <= UInt64(AIFormatsLimits.maxModelHeaderBytes - 8) else {
            return failed(String(localized: "The header claims \(claimed), more than the 64 MB this reader reads; a real header is far smaller, so the file is damaged or hostile.", bundle: .module, comment: "Warning on a safetensors card. The argument is a size."))
        }
        guard Int64(length) <= source.size - 8,
              let header = try? reader.bytes(at: 8, count: Int(length), "the header") else {
            return failed(String(localized: "The header claims \(claimed) but the file ends first.", bundle: .module, comment: "Warning on a safetensors card. The argument is a size."))
        }
        guard header.first == UInt8(ascii: "{") else {
            return failed(String(localized: "The header does not start with a JSON object: this is not a safetensors file.", bundle: .module, comment: "Warning on a safetensors card."))
        }
        let (rootView, result) = AIJSONView.parse(header, format: .json, maxPreviewBytes: 1024, maxDepth: 8, maxNodes: 2_000_000)
        guard let root = rootView, root.isObject else {
            return failed(String(localized: "The header is not valid JSON.", bundle: .module, comment: "Warning on a safetensors card."))
        }

        var warnings: [AIWarning] = []
        if let error = result.error {
            let detail = error.description
            warnings.append(AIWarning(.caution, String(localized: "The header JSON has an error (\(detail)); loaders will refuse it.", bundle: .module, comment: "Warning on a safetensors card. The argument is a technical parser message in English.")))
        }
        var dtypes: [String: Int] = [:]
        var tensors: [SafetensorsSummary.Tensor] = []
        var parameters: Int64? = 0
        var ranges: [(Int64, Int64, String)] = []
        var count = 0
        var metadata: [AIFact] = []
        var sizeMismatches: [String] = []
        for child in root.children {
            guard let name = child.name else { continue }
            if name == "__metadata__" {
                for entry in child.children.prefix(50) {
                    metadata.append(AIFact(entry.name ?? "", AIFormat.clip(entry.scalarText ?? "(\(entry.kind.displayName))", 300)))
                }
                continue
            }
            count += 1
            let dtype = child["dtype"]?.string ?? "?"
            dtypes[dtype, default: 0] += 1
            let shape = child["shape"]?.children.compactMap(\.int64) ?? []
            let elements = AIFormat.product(shape)
            if let p = parameters, let e = elements, !p.addingReportingOverflow(e).overflow { parameters = p + e } else { parameters = nil }
            if tensors.count < 50 { tensors.append(.init(name: name, dtype: dtype, shape: shape)) }
            let offsets = child["data_offsets"]?.children.compactMap(\.int64) ?? []
            if offsets.count == 2, offsets[0] >= 0, offsets[1] >= offsets[0] {
                ranges.append((offsets[0], offsets[1], name))
                if let bits = dtypeBits[dtype], bits % 8 == 0, let e = elements {
                    let (want, o) = e.multipliedReportingOverflow(by: Int64(bits / 8))
                    if o || want != offsets[1] - offsets[0] { sizeMismatches.append(name) }
                }
            } else {
                sizeMismatches.append(name)
            }
            if dtypeBits[dtype] == nil, dtype != "?" {
                warnings.append(AIWarning(.caution, String(localized: "Tensor \(name) has dtype \(dtype), which loaders may not know.", bundle: .module, comment: "Warning on a safetensors card. A tensor name, then a data type code."), subject: name))
            }
        }
        ranges.sort { $0.0 < $1.0 }
        var overlaps: [String] = []
        var end: Int64 = 0
        for r in ranges {
            if r.0 < end { overlaps.append(r.2) }
            end = max(end, r.1)
        }
        if !sizeMismatches.isEmpty {
            let n = sizeMismatches.count, names = sizeMismatches.prefix(3).joined(separator: ", ")
            warnings.append(AIWarning(.caution, String(localized: "\(n) tensors have a data range that does not match their shape and dtype (\(names)): the file is damaged or crafted.", bundle: .module, comment: "Warning on a safetensors card. A number of tensors (plural forms), then some of their names.")))
        }
        if !overlaps.isEmpty {
            let n = overlaps.count, names = overlaps.prefix(3).joined(separator: ", ")
            warnings.append(AIWarning(.caution, String(localized: "\(n) tensors overlap another tensor's data (\(names)), which a normal writer never produces.", bundle: .module, comment: "Warning on a safetensors card. A number of tensors (plural forms), then some of their names.")))
        }

        let histogram = dtypes.sorted { $0.value > $1.value }.map { "\($0.key) × \(AIFormat.count($0.value))" }.joined(separator: ", ")
        var facts = [AIFact(AIFormat.formatLabel, "safetensors"), AIFact(AIFormat.tensorsLabel, AIFormat.count(count))]
        if let parameters { facts.append(AIFact(AIFormat.parametersLabel, AIFormat.parameters(parameters))) }
        if !histogram.isEmpty {
            facts.append(AIFact(String(localized: "Dtypes", bundle: .module, comment: "Fact label on a model card: how many tensors use each data type."), histogram))
        }
        facts.append(AIFact(headerLabel, AIFormat.bytes(Int64(length))))
        if end > 0 {
            facts.append(AIFact(String(localized: "Tensor data", bundle: .module, comment: "Fact label on a safetensors card: the size of the weights after the header."), AIFormat.bytes(end)))
        }
        for m in metadata.prefix(6) {
            let key = m.label
            facts.append(AIFact(String(localized: "Metadata: \(key)", bundle: .module, comment: "Fact label on a safetensors card for one metadata entry. The argument is the entry's key."), m.value))
        }

        let tensorsText = String(localized: "\(count) tensors", bundle: .module, comment: "Part of a safetensors card's headline: the number of tensors (plural forms).")
        var headline = "safetensors · \(tensorsText)"
        if let parameters, parameters > 0 { headline += " · \(AIFormat.parameters(parameters))" }
        if let top = dtypes.max(by: { $0.value < $1.value })?.key { headline += " · \(top)" }
        return SafetensorsSummary(headerLength: Int64(length), tensorCount: count, dtypes: dtypes, parameterCount: parameters,
                                  dataBytes: end, metadata: metadata, tensors: tensors, headline: headline, facts: facts,
                                  warnings: warnings)
    }
}

/// A Hugging Face `tokenizer.json`: model type, vocabulary and merges, added and special tokens, and the
/// normalizer, pre-tokenizer, post-processor and decoder types. roadmap: S-21
public struct TokenizerSummary: Sendable, Equatable {
    /// A token added on top of the vocabulary. roadmap: S-21
    public struct AddedToken: Sendable, Equatable {
        public var id: Int64?
        public var content: String
        public var special: Bool
    }

    /// BPE, WordPiece, Unigram, WordLevel.
    public var modelType: String?
    public var vocabSize: Int
    public var mergesCount: Int?
    public var addedTokens: [AddedToken]
    public var addedTokenCount: Int
    /// The special tokens' text (at most 50).
    public var specialTokens: [String]
    /// `Sequence[NFC, Lowercase]` style names.
    public var normalizer: String?
    public var preTokenizer: String?
    public var postProcessor: String?
    public var decoder: String?
    public var hasTruncation: Bool
    public var hasPadding: Bool
    /// Only the start of the file was read, so counts are lower bounds.
    public var partial: Bool
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]
}

enum TokenizerReader {
    static func read(bytes: [UInt8], fileSize: Int64) -> TokenizerSummary? {
        // Depth 4 reaches a Sequence normalizer's members' types; deeper values (a merge pair's halves) are only counted.
        // Past the node cap entries are still counted, so vocabulary and merge counts stay exact.
        let (rootView, result) = AIJSONView.parse(bytes, format: .json, maxPreviewBytes: 512, maxDepth: 4, maxNodes: 600_000,
                                                  fileSize: max(fileSize, Int64(bytes.count)))
        guard let root = rootView, root.isObject, root["model"] != nil || root["added_tokens"] != nil else { return nil }
        let partial = fileSize > Int64(bytes.count) || !result.isValid
        let model = root["model"]
        var modelType = model?["type"]?.string
        let vocabNode = model?["vocab"]
        let vocab = vocabNode?.count ?? 0
        let merges = model?["merges"]?.count
        if modelType == nil, model != nil {
            modelType = merges != nil ? "BPE" : vocabNode?.isArray == true ? "Unigram" : nil
        }

        var added: [TokenizerSummary.AddedToken] = []
        var special: [String] = []
        let addedNode = root["added_tokens"]
        for token in addedNode?.children ?? [] {
            let content = token["content"]?.string ?? ""
            let isSpecial = token["special"]?.bool ?? false
            if added.count < 200 { added.append(.init(id: token["id"]?.int64, content: AIFormat.clip(content, 80), special: isSpecial)) }
            if isSpecial, special.count < 50 { special.append(AIFormat.clip(content, 80)) }
        }

        func describe(_ node: AIJSONView?, list: String) -> String? {
            guard let node, node.isObject else { return nil }
            let type = node["type"]?.string ?? "?"
            if type == "Sequence", let items = node[list]?.children {
                return "Sequence[" + items.map { $0["type"]?.string ?? "?" }.joined(separator: ", ") + "]"
            }
            return type
        }
        let normalizer = describe(root["normalizer"], list: "normalizers")
        let pre = describe(root["pre_tokenizer"], list: "pretokenizers")
        let post = describe(root["post_processor"], list: "processors")
        let decoder = describe(root["decoder"], list: "decoders")
        let truncation = root["truncation"].map { $0.kind != .null } ?? false
        let padding = root["padding"].map { $0.kind != .null } ?? false

        var warnings: [AIWarning] = []
        if partial {
            if fileSize > Int64(bytes.count) {
                let read = AIFormat.bytes(Int64(bytes.count)), total = AIFormat.bytes(fileSize)
                warnings.append(AIWarning(.caution, String(localized: "Only the first \(read) of \(total) was read, so the counts are lower bounds.", bundle: .module, comment: "Warning on a tokenizer card. Two sizes.")))
            } else {
                let detail = result.error?.description ?? "?"
                warnings.append(AIWarning(.caution, String(localized: "The JSON has an error (\(detail)), so loaders will refuse it and the counts may be incomplete.", bundle: .module, comment: "Warning on a tokenizer card. The argument is a technical parser message in English.")))
            }
        }
        let plus = partial ? "+" : ""
        let unknown = String(localized: "unknown", bundle: .module, comment: "A tokenizer card's model type when the file does not say.")
        var facts = [AIFact(String(localized: "Model", bundle: .module, comment: "Fact label on a tokenizer card: its algorithm, such as BPE."), modelType ?? unknown),
                     AIFact(AIFormat.vocabularyLabel, AIFormat.count(vocab) + plus)]
        if let merges {
            facts.append(AIFact(String(localized: "Merges", bundle: .module, comment: "Fact label on a BPE tokenizer card: the number of merge rules."), AIFormat.count(merges) + plus))
        }
        facts.append(AIFact(String(localized: "Added tokens", bundle: .module, comment: "Fact label on a tokenizer card."), AIFormat.count(addedNode?.count ?? 0)))
        if !special.isEmpty {
            facts.append(AIFact(String(localized: "Special tokens", bundle: .module, comment: "Fact label on a tokenizer card."), AIFormat.clip(special.joined(separator: " "), 300)))
        }
        if let normalizer { facts.append(AIFact(String(localized: "Normalizer", bundle: .module, comment: "Fact label on a tokenizer card."), normalizer)) }
        if let pre { facts.append(AIFact(String(localized: "Pre-tokenizer", bundle: .module, comment: "Fact label on a tokenizer card."), pre)) }
        if let post { facts.append(AIFact(String(localized: "Post-processor", bundle: .module, comment: "Fact label on a tokenizer card."), post)) }
        if let decoder { facts.append(AIFact(String(localized: "Decoder", bundle: .module, comment: "Fact label on a tokenizer card."), decoder)) }

        let headline: String
        let type = modelType ?? "?"
        if partial {
            headline = String(localized: "\(type) tokenizer · at least \(vocab) tokens", bundle: .module, comment: "Headline of a tokenizer card read only in part. A model type such as BPE, then a token count (plural forms).")
        } else {
            headline = String(localized: "\(type) tokenizer · \(vocab) tokens", bundle: .module, comment: "Headline of a tokenizer card. A model type such as BPE, then a token count (plural forms).")
        }
        return TokenizerSummary(modelType: modelType, vocabSize: vocab, mergesCount: merges, addedTokens: added,
                                addedTokenCount: addedNode?.count ?? 0, specialTokens: special, normalizer: normalizer,
                                preTokenizer: pre, postProcessor: post, decoder: decoder, hasTruncation: truncation,
                                hasPadding: padding, partial: partial, headline: headline, facts: facts, warnings: warnings)
    }
}
