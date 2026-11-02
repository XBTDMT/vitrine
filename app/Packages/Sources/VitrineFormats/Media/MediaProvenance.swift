import Compression
import Foundation

/// Generation settings an AI image tool wrote into the file (Automatic1111/Forge `parameters`, InvokeAI, NovelAI,
/// Fooocus). roadmap: S-23
public struct MediaGenerationParameters: Sendable, Equatable {
    public var prompt: String?
    public var negativePrompt: String?
    public var steps: Int?
    public var sampler: String?
    public var scheduler: String?
    public var cfgScale: Double?
    /// Kept as text: seeds run past 64-bit signed integers in some tools.
    public var seed: String?
    /// "512x768".
    public var size: String?
    public var model: String?
    public var modelHash: String?
    public var loras: [String]
    /// Every other setting the tool wrote, in its order, at most 64.
    public var otherSettings: [MediaFact]

    public init() { loras = []; otherSettings = [] }
}

/// What a ComfyUI `prompt` (API graph) or `workflow` (editor graph) holds. roadmap: S-23
public struct MediaComfyWorkflow: Sendable, Equatable {
    /// "prompt" or "workflow": which graph was read.
    public var source: String
    public var nodeCount: Int
    /// Node class types, most frequent first.
    public var nodeTypes: [MediaCount]
    public var checkpoints: [String]
    public var loras: [String]
    public var seeds: [String]
    public var steps: [Int]
    public var samplers: [String]
    public var schedulers: [String]
    public var cfgScales: [Double]
    /// Text from CLIPTextEncode nodes wired to a sampler's positive input.
    public var positivePrompts: [String]
    public var negativePrompts: [String]
}

/// An image's AI provenance (T-11): generator settings from text chunks, XMP and EXIF, and C2PA content
/// credentials. Nothing is verified: this is what the file says about itself. roadmap: S-23
public struct MediaProvenance: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// "Automatic1111 / Forge", "ComfyUI", "InvokeAI", "NovelAI", "Fooocus", or the C2PA claim generator.
    public var generator: String?
    public var generation: MediaGenerationParameters?
    public var comfy: MediaComfyWorkflow?
    public var c2pa: MediaC2PASummary?
    /// The IPTC digital source type XMP declares (short name).
    public var xmpDigitalSourceType: String?
    public var xmpCreatorTool: String?
    /// Keywords of the PNG text chunks, in order, at most 100.
    public var textKeys: [String]
    /// Any signal says the image was made with AI (generator settings, C2PA or XMP source type).
    public var isAIGenerated: Bool
    public var truncated: Bool
}

enum MediaProvenanceReader {
    static let maxTextChunks = 256
    static let maxTextBytes = 32 * 1024 * 1024
    static let maxInflated = 16 * 1024 * 1024
    static let scanLimit = 64 * 1024 * 1024

    struct Found {
        var texts: [(String, String)] = []
        var xmp: String?
        var jumbf: (bytes: [UInt8], container: String)?
        var comment: String?
        var truncated = false
    }

    static func read(data: Data, exifUserComment: String?) -> MediaProvenance? {
        let b = MediaBytes(data)
        var found = Found()
        if b.u8(0) == 0x89, b.matches("PNG", at: 1) { png(b, &found) }
        else if b.u8(0) == 0xFF, b.u8(1) == 0xD8 { jpeg(b, &found) }
        else if b.matches("RIFF", at: 0), b.matches("WEBP", at: 8) { webp(b, &found) }
        else if b.matches("ftyp", at: 4) { isobmff(b, &found) }
        if found.xmp == nil, let start = b.find(Array("<x:xmpmeta".utf8), limit: min(b.count, scanLimit)),
           let end = b.find(Array("</x:xmpmeta>".utf8), from: start, limit: min(b.count, start + 4 * 1024 * 1024)) {
            found.xmp = String(decoding: b.bytes(start, end + 12 - start), as: UTF8.self)
        }
        return interpret(found, exifUserComment: exifUserComment)
    }

    // MARK: Containers

    static func png(_ b: MediaBytes, _ f: inout Found) {
        var o = 8
        var chunks = 0
        var textBytes = 0
        while o + 12 <= b.count, chunks < 100_000 {
            chunks += 1
            guard let length = b.be32(o).map(Int.init), let type = b.fourCC(o + 4) else { break }
            let body = o + 8
            guard body + length <= b.count else { f.truncated = true; break }
            switch type {
            case "tEXt", "zTXt", "iTXt":
                guard f.texts.count < maxTextChunks, textBytes < maxTextBytes else { f.truncated = true; break }
                if let (key, value) = textChunk(type, b.bytes(body, length)) {
                    textBytes += value.utf8.count
                    if key == "XML:com.adobe.xmp" { f.xmp = value } else { f.texts.append((key, value)) }
                }
            case "caBX":
                f.jumbf = (b.bytes(body, length), "PNG caBX")
            case "IEND":
                return
            default: break
            }
            o = body + length + 4
        }
    }

    static func textChunk(_ type: String, _ c: [UInt8]) -> (String, String)? {
        guard let zero = c.firstIndex(of: 0), zero > 0 else { return nil }
        let key = MediaText.latin1(c[0..<zero])
        switch type {
        case "tEXt":
            return (key, MediaText.latin1(c[(zero + 1)...]))
        case "zTXt":
            guard zero + 2 <= c.count, c[zero + 1] == 0, let raw = inflateZlib(Array(c[(zero + 2)...])) else { return nil }
            return (key, MediaText.latin1(raw))
        default:                                                              // iTXt
            guard zero + 3 <= c.count else { return nil }
            let compressed = c[zero + 1] == 1
            var i = zero + 3
            guard let langEnd = c[i...].firstIndex(of: 0) else { return nil }
            i = langEnd + 1
            guard let transEnd = c[i...].firstIndex(of: 0) else { return nil }
            let text = Array(c[(transEnd + 1)...])
            if compressed {
                guard let raw = inflateZlib(text) else { return nil }
                return (key, MediaText.utf8(raw))
            }
            return (key, MediaText.utf8(text))
        }
    }

    static func jpeg(_ b: MediaBytes, _ f: inout Found) {
        var o = 2
        var segments = 0
        var app11: [UInt16: [(UInt32, [UInt8])]] = [:]
        while o + 4 <= b.count, segments < 10_000 {
            segments += 1
            guard b.u8(o) == 0xFF, let marker = b.u8(o + 1) else { break }
            if marker == 0xFF { o += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { o += 2; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            guard let length = b.be16(o + 2).map(Int.init), length >= 2 else { break }
            let body = o + 4, n = length - 2
            if body + n > b.count { f.truncated = true }
            switch marker {
            case 0xE1:
                let xmpHeader = "http://ns.adobe.com/xap/1.0/\u{0}"
                if b.matches(xmpHeader, at: body) {
                    f.xmp = String(decoding: b.bytes(body + xmpHeader.utf8.count, n - xmpHeader.utf8.count), as: UTF8.self)
                }
            case 0xEB:
                // JUMBF in APP11: "JP", box instance (En), sequence (Z), then the box; later segments repeat its header.
                if b.matches("JP", at: body), let en = b.be16(body + 2), let z = b.be32(body + 4) {
                    app11[en, default: []].append((z, b.bytes(body + 8, n - 8)))
                }
            case 0xFE:
                if f.comment == nil { f.comment = String(decoding: b.bytes(body, min(n, 1024 * 1024)), as: UTF8.self) }
            default: break
            }
            o = body + n
        }
        for (_, parts) in app11.sorted(by: { $0.key < $1.key }) {
            let ordered = parts.sorted { $0.0 < $1.0 }
            var bytes: [UInt8] = []
            for (index, (_, part)) in ordered.enumerated() {
                if index == 0 { bytes += part; continue }
                let header = part.mediaBE32(0) == 1 ? 16 : 8
                bytes += part.dropFirst(header)
            }
            if bytes.count >= 8, MediaText.latin1(bytes[4..<8]) == "jumb" {
                f.jumbf = (bytes, "JPEG APP11")
                if MediaC2PA.summarize(bytes, container: "JPEG APP11") != nil { break }
            }
        }
    }

    static func webp(_ b: MediaBytes, _ f: inout Found) {
        var o = 12
        var chunks = 0
        while o + 8 <= b.count, chunks < 10_000 {
            chunks += 1
            guard let id = b.fourCC(o), let size = b.le32(o + 4).map(Int.init) else { break }
            let body = o + 8
            if body + size > b.count { f.truncated = true }
            switch id {
            case "XMP ": f.xmp = String(decoding: b.bytes(body, size), as: UTF8.self)
            case "C2PA": f.jumbf = (b.bytes(body, size), "WebP C2PA chunk")
            default: break
            }
            o = body + size + (size & 1)
        }
    }

    static func isobmff(_ b: MediaBytes, _ f: inout Found) {
        var o = 0
        var boxes = 0
        while o + 8 <= b.count, boxes < 4_096 {
            boxes += 1
            guard let size32 = b.be32(o), let type = b.fourCC(o + 4) else { break }
            var size = Int(size32), header = 8
            if size32 == 1 { guard let l = b.be64(o + 8), l < UInt64(Int.max) else { break }; size = Int(l); header = 16 }
            else if size32 == 0 { size = b.count - o }
            guard size >= header else { break }
            // A box past the end is cut to the end, so `o + size` below can never overflow (a 64-bit largesize near
            // Int.max made `o += size` and the loop test trap).
            if size > b.count - o { size = b.count - o }
            if type == "uuid", b.bytes(o + header, 16) == MediaC2PA.isobmffUUID {
                var p = o + header + 16 + 4                                     // full box version and flags
                let purposeStart = p
                while p < o + size, b.u8(p) != 0 { p += 1 }
                let purpose = String(decoding: b.bytes(purposeStart, p - purposeStart), as: UTF8.self)
                p += 1
                if purpose == "manifest" {
                    p += 8                                                       // offset to merkle data
                    f.jumbf = (b.bytes(p, o + size - p), "ISO BMFF uuid box")
                }
            }
            o += size
        }
    }

    /// zlib (RFC 1950) data, inflated to at most 16 MB with the system decoder; nil when damaged or larger.
    static func inflateZlib(_ input: [UInt8]) -> [UInt8]? {
        guard input.count > 2 else { return nil }
        let raw = Array(input.dropFirst(2))                                  // Apple's ZLIB decoder takes raw DEFLATE
        var out: [UInt8] = []
        let chunk = 64 * 1024
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        var buffer = [UInt8](repeating: 0, count: chunk)
        return raw.withUnsafeBufferPointer { inBuf -> [UInt8]? in
            guard let base = inBuf.baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { outBuf -> compression_status in
                    stream.pointee.dst_ptr = outBuf.baseAddress!
                    stream.pointee.dst_size = chunk
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunk - stream.pointee.dst_size
                out += buffer[0..<produced]
                if out.count > maxInflated { return nil }
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK: if produced == 0 && stream.pointee.src_size == 0 { return out }
                default: return out.isEmpty ? nil : out
                }
            }
        }
    }

    // MARK: Interpretation

    static func interpret(_ f: Found, exifUserComment: String?) -> MediaProvenance? {
        var p = MediaProvenance(headline: "", facts: [], warnings: [], generator: nil, generation: nil, comfy: nil,
                                c2pa: nil, xmpDigitalSourceType: nil, xmpCreatorTool: nil,
                                textKeys: f.texts.prefix(100).map(\.0), isAIGenerated: false, truncated: f.truncated)
        let texts = Dictionary(f.texts.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

        if let params = texts["parameters"] {
            if let json = jsonObject(params) as? [String: Any] {
                p.generation = genericJSON(json)
                p.generator = "Fooocus"
            } else {
                p.generation = automatic1111(params)
                p.generator = "Automatic1111 / Forge"
            }
        }
        if let prompt = texts["prompt"], let graph = jsonObject(prompt) as? [String: Any], let comfy = comfyPrompt(graph) {
            p.comfy = comfy
            p.generator = p.generator ?? "ComfyUI"
        } else if let workflow = texts["workflow"], let graph = jsonObject(workflow) as? [String: Any], let comfy = comfyWorkflow(graph) {
            p.comfy = comfy
            p.generator = p.generator ?? "ComfyUI"
        }
        if p.generation == nil, let invoke = texts["invokeai_metadata"], let json = jsonObject(invoke) as? [String: Any] {
            p.generation = genericJSON(json)
            p.generator = "InvokeAI"
        }
        if p.generation == nil, texts["Software"] == "NovelAI" {
            var g = (texts["Comment"].flatMap(jsonObject) as? [String: Any]).map(genericJSON) ?? MediaGenerationParameters()
            if g.prompt == nil { g.prompt = MediaText.clean(texts["Description"], max: MediaLimits.maxPromptCharacters) }
            if g.model == nil { g.model = MediaText.clean(texts["Source"], max: 200) }
            p.generation = g
            p.generator = "NovelAI"
        }
        for candidate in [exifUserComment, f.comment] where p.generation == nil {
            if let text = candidate, text.contains("Steps: ") {
                p.generation = automatic1111(text)
                p.generator = "Automatic1111 / Forge"
            }
        }
        if let xmp = f.xmp {
            p.xmpDigitalSourceType = digitalSourceType(xmp)
            p.xmpCreatorTool = creatorTool(xmp)
            if p.generation == nil, xmp.contains("Steps: "), let text = xmpParameters(xmp) {
                p.generation = automatic1111(text)
                p.generator = "Automatic1111 / Forge"
            }
        }
        if let (bytes, container) = f.jumbf {
            p.c2pa = MediaC2PA.summarize(bytes, container: container)
            if p.c2pa == nil {
                p.warnings.append(MediaWarning(.caution, String(localized: "A Content Credentials (C2PA) block is present but could not be read.", bundle: .module, comment: "Provenance warning.")))
            }
        }

        let xmpAI = p.xmpDigitalSourceType.flatMap(MediaC2PA.aiSourceType) != nil
        p.isAIGenerated = p.generation != nil || p.comfy != nil || p.c2pa?.madeWithAI == true || xmpAI
        guard p.isAIGenerated || p.c2pa != nil || p.xmpDigitalSourceType != nil || !f.texts.isEmpty else { return nil }
        if p.generator == nil, let g = p.c2pa?.claimGenerator { p.generator = g }

        // Headline, facts, warnings.
        if let c = p.c2pa, c.madeWithAI {
            p.headline = String(localized: "Made with AI, per its Content Credentials (signature not verified)", bundle: .module, comment: "Provenance headline from a C2PA manifest.")
        } else if p.isAIGenerated, let g = p.generator {
            p.headline = String(localized: "Made with AI: \(g) settings are embedded", bundle: .module, comment: "Provenance headline. The argument is a tool name.")
        } else if p.isAIGenerated {
            p.headline = String(localized: "Made with AI, per its metadata", bundle: .module, comment: "Provenance headline.")
        } else if p.c2pa != nil {
            p.headline = String(localized: "Content Credentials (C2PA) present", bundle: .module, comment: "Provenance headline.")
        } else {
            p.headline = String(localized: "Embedded text metadata", bundle: .module, comment: "Provenance headline when only plain text chunks exist.")
        }
        var facts: [MediaFact] = []
        if let g = p.generator { facts.append(MediaFact(String(localized: "Generator", bundle: .module, comment: "Provenance fact label."), g)) }
        if let g = p.generation {
            if let v = g.model { facts.append(MediaFact(String(localized: "Model", bundle: .module, comment: "Provenance fact label: AI model name."), v)) }
            if let v = g.steps { facts.append(MediaFact(String(localized: "Steps", bundle: .module, comment: "Provenance fact label: sampling steps."), "\(v)")) }
            if let v = g.sampler { facts.append(MediaFact(String(localized: "Sampler", bundle: .module, comment: "Provenance fact label."), v)) }
            if let v = g.cfgScale { facts.append(MediaFact(String(localized: "CFG scale", bundle: .module, comment: "Provenance fact label."), MediaText.number(v, digits: 2))) }
            if let v = g.seed { facts.append(MediaFact(String(localized: "Seed", bundle: .module, comment: "Provenance fact label."), v)) }
            if let v = g.size { facts.append(MediaFact(String(localized: "Size", bundle: .module, comment: "Provenance fact label: generated image size."), v)) }
        }
        if let c = p.comfy {
            facts.append(MediaFact(String(localized: "Nodes", bundle: .module, comment: "Provenance fact label: ComfyUI node count."), "\(c.nodeCount)"))
            if !c.checkpoints.isEmpty { facts.append(MediaFact(String(localized: "Checkpoint", bundle: .module, comment: "Provenance fact label: ComfyUI model checkpoint."), c.checkpoints.joined(separator: ", "))) }
            if !c.loras.isEmpty { facts.append(MediaFact(String(localized: "LoRAs", bundle: .module, comment: "Provenance fact label."), c.loras.joined(separator: ", "))) }
        }
        if let c = p.c2pa {
            if let g = c.claimGenerator { facts.append(MediaFact(String(localized: "Claim generator", bundle: .module, comment: "Provenance fact label (C2PA)."), g)) }
            facts.append(MediaFact(String(localized: "Manifests", bundle: .module, comment: "Provenance fact label (C2PA)."), "\(c.manifestCount)"))
            facts.append(MediaFact(String(localized: "Signature", bundle: .module, comment: "Provenance fact label (C2PA)."),
                                   c.signaturePresent ? String(localized: "Present, not verified", bundle: .module, comment: "C2PA signature state.")
                                                      : String(localized: "Missing", bundle: .module, comment: "C2PA signature state.")))
        }
        if let d = p.xmpDigitalSourceType { facts.append(MediaFact(String(localized: "Source type (XMP)", bundle: .module, comment: "Provenance fact label: IPTC digital source type."), d)) }
        p.facts = facts

        if p.isAIGenerated {
            p.warnings.append(MediaWarning(.caution, String(localized: "This image's own metadata says it was made with AI.", bundle: .module, comment: "Provenance warning.")))
        }
        if let c = p.c2pa {
            p.warnings.append(MediaWarning(.caution, c.signaturePresent
                ? String(localized: "The Content Credentials are signed, but Vitrine does not verify the signature: treat them as a claim, not proof.", bundle: .module, comment: "Provenance warning.")
                : String(localized: "The Content Credentials carry no signature, so anyone could have written them.", bundle: .module, comment: "Provenance warning.")))
        }
        return p
    }

    static func jsonObject(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "NaN", with: "null")       // ComfyUI writes NaN for empty widgets
        return try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))
    }

    /// Automatic1111 / Forge `parameters`: the prompt, an optional "Negative prompt:" part, then a settings line
    /// ("Steps: 20, Sampler: Euler a, CFG scale: 7, Seed: 1, Size: 512x512, Model hash: …, Model: …").
    static func automatic1111(_ text: String) -> MediaGenerationParameters {
        var g = MediaGenerationParameters()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let settingsIndex = lines.lastIndex { $0.hasPrefix("Steps: ") } ?? lines.lastIndex { $0.contains("Steps: ") && $0.contains("Sampler: ") }
        let promptPart = lines[0..<(settingsIndex ?? lines.count)].joined(separator: "\n")
        if let range = promptPart.range(of: "Negative prompt:") {
            g.prompt = MediaText.clean(String(promptPart[..<range.lowerBound]), max: MediaLimits.maxPromptCharacters)
            g.negativePrompt = MediaText.clean(String(promptPart[range.upperBound...]), max: MediaLimits.maxPromptCharacters)
        } else {
            g.prompt = MediaText.clean(promptPart, max: MediaLimits.maxPromptCharacters)
        }
        guard let settingsIndex else { return g }
        let settings = lines[settingsIndex...].joined(separator: ", ")
        for (key, value) in settingPairs(settings) {
            switch key {
            case "Steps": g.steps = Int(value)
            case "Sampler": g.sampler = value
            case "Schedule type", "Scheduler": g.scheduler = value
            case "CFG scale": g.cfgScale = Double(value)
            case "Seed": g.seed = value
            case "Size": g.size = value
            case "Model": g.model = value
            case "Model hash": g.modelHash = value
            case "Lora hashes":
                g.loras = value.split(separator: ",").compactMap { $0.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
            default:
                if g.otherSettings.count < 64 { g.otherSettings.append(MediaFact(key, MediaText.cap(value, 500))) }
            }
        }
        if g.loras.isEmpty, let prompt = g.prompt {
            // <lora:name:weight> tags in the prompt.
            var rest = prompt[...]
            while let open = rest.range(of: "<lora:"), let close = rest[open.upperBound...].firstIndex(of: ">") {
                let inner = rest[open.upperBound..<close]
                if let name = inner.split(separator: ":").first, g.loras.count < 50 { g.loras.append(String(name)) }
                rest = rest[rest.index(after: close)...]
            }
        }
        return g
    }

    /// "Key: value" pairs separated by commas, where a quoted value may itself hold commas.
    static func settingPairs(_ s: String) -> [(String, String)] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); current.append(ch); continue }
            if ch == ",", !quoted { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        var out: [(String, String)] = []
        for part in parts.prefix(200) {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty { out.append((key, value)) }
        }
        return out
    }

    /// JSON settings with the key names InvokeAI, NovelAI and Fooocus use.
    static func genericJSON(_ j: [String: Any]) -> MediaGenerationParameters {
        var g = MediaGenerationParameters()
        func string(_ keys: String...) -> String? {
            for k in keys {
                if let s = j[k] as? String, let c = MediaText.clean(s, max: MediaLimits.maxPromptCharacters) { return c }
                if let n = j[k] as? NSNumber { return n.stringValue }
                if let d = j[k] as? [String: Any], let s = (d["name"] ?? d["model_name"]) as? String { return s }
            }
            return nil
        }
        g.prompt = string("positive_prompt", "prompt", "Prompt")
        g.negativePrompt = string("negative_prompt", "uc", "Negative Prompt", "negative")
        g.steps = string("steps", "Steps").flatMap { Int($0) }
        g.sampler = string("sampler", "sampler_name", "Sampler")
        g.scheduler = string("scheduler", "Scheduler")
        g.cfgScale = string("cfg_scale", "scale", "guidance_scale", "Guidance Scale", "cfg").flatMap { Double($0) }
        g.seed = string("seed", "Seed")
        if let w = string("width"), let h = string("height") { g.size = "\(w)x\(h)" } else { g.size = string("resolution", "Resolution") }
        g.model = string("model", "base_model", "Base Model", "model_name")
        g.modelHash = string("model_hash")
        return g
    }

    // MARK: ComfyUI

    static func comfyPrompt(_ graph: [String: Any]) -> MediaComfyWorkflow? {
        var nodes: [String: [String: Any]] = [:]
        for (id, value) in graph.prefix(20_000) {
            if let node = value as? [String: Any], node["class_type"] is String { nodes[id] = node }
        }
        guard !nodes.isEmpty else { return nil }
        var w = MediaComfyWorkflow(source: "prompt", nodeCount: nodes.count, nodeTypes: [], checkpoints: [], loras: [],
                                   seeds: [], steps: [], samplers: [], schedulers: [], cfgScales: [], positivePrompts: [],
                                   negativePrompts: [])
        var counts: [String: Int] = [:]
        for (_, node) in nodes { counts[node["class_type"] as? String ?? "?", default: 0] += 1 }
        w.nodeTypes = counts.map { MediaCount($0.key, $0.value) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }

        func inputs(_ node: [String: Any]) -> [String: Any] { node["inputs"] as? [String: Any] ?? [:] }
        func add<T: Equatable>(_ v: T?, _ list: inout [T]) { if let v, !list.contains(v), list.count < 20 { list.append(v) } }
        func texts(from link: Any?, depth: Int, seen: inout Set<String>) -> [String] {
            guard depth < 8, let pair = link as? [Any], let id = (pair.first as? String) ?? (pair.first as? NSNumber)?.stringValue,
                  !seen.contains(id), let node = nodes[id] else { return [] }
            seen.insert(id)
            let ins = inputs(node)
            if (node["class_type"] as? String ?? "").hasPrefix("CLIPTextEncode") {
                let parts = ["text", "text_g", "text_l", "prompt"].compactMap { ins[$0] as? String }
                if !parts.isEmpty { return [parts.joined(separator: "\n")] }
            }
            var out: [String] = []
            for key in ins.keys.sorted() { out += texts(from: ins[key], depth: depth + 1, seen: &seen) }
            return out
        }
        for id in nodes.keys.sorted(by: MediaSort.natural) {
            let node = nodes[id]!
            let ins = inputs(node)
            add((ins["ckpt_name"] ?? ins["unet_name"]) as? String, &w.checkpoints)
            add(ins["lora_name"] as? String, &w.loras)
            if let seed = (ins["seed"] ?? ins["noise_seed"]) as? NSNumber { add(seed.stringValue, &w.seeds) }
            if let steps = ins["steps"] as? NSNumber { add(steps.intValue, &w.steps) }
            if let cfg = ins["cfg"] as? NSNumber { add(cfg.doubleValue, &w.cfgScales) }
            add(ins["sampler_name"] as? String, &w.samplers)
            add(ins["scheduler"] as? String, &w.schedulers)
            var seen = Set<String>()
            for t in texts(from: ins["positive"], depth: 0, seen: &seen) { add(MediaText.clean(t, max: MediaLimits.maxPromptCharacters), &w.positivePrompts) }
            seen = []
            for t in texts(from: ins["negative"], depth: 0, seen: &seen) { add(MediaText.clean(t, max: MediaLimits.maxPromptCharacters), &w.negativePrompts) }
        }
        return w
    }

    static func comfyWorkflow(_ graph: [String: Any]) -> MediaComfyWorkflow? {
        guard let rawNodes = graph["nodes"] as? [Any] else { return nil }
        let nodes = rawNodes.prefix(20_000).compactMap { $0 as? [String: Any] }
        guard !nodes.isEmpty else { return nil }
        var w = MediaComfyWorkflow(source: "workflow", nodeCount: nodes.count, nodeTypes: [], checkpoints: [], loras: [],
                                   seeds: [], steps: [], samplers: [], schedulers: [], cfgScales: [], positivePrompts: [],
                                   negativePrompts: [])
        var counts: [String: Int] = [:]
        var byID: [Int: [String: Any]] = [:]
        for node in nodes {
            counts[node["type"] as? String ?? "?", default: 0] += 1
            if let id = (node["id"] as? NSNumber)?.intValue { byID[id] = node }
        }
        w.nodeTypes = counts.map { MediaCount($0.key, $0.value) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        var linkSource: [Int: Int] = [:]                                     // link id → source node id
        for link in (graph["links"] as? [Any])?.prefix(100_000) ?? [] {
            if let l = link as? [Any], l.count >= 2, let id = (l[0] as? NSNumber)?.intValue, let from = (l[1] as? NSNumber)?.intValue {
                linkSource[id] = from
            }
        }
        func add<T: Equatable>(_ v: T?, _ list: inout [T]) { if let v, !list.contains(v), list.count < 20 { list.append(v) } }
        func widgets(_ node: [String: Any]) -> [Any] { node["widgets_values"] as? [Any] ?? [] }
        func text(of node: [String: Any]?) -> String? {
            guard let node, (node["type"] as? String ?? "").hasPrefix("CLIPTextEncode") else { return nil }
            return widgets(node).first as? String
        }
        for node in nodes {
            let type = node["type"] as? String ?? ""
            let values = widgets(node)
            if type.hasPrefix("CheckpointLoader") || type == "UNETLoader" { add(values.first as? String, &w.checkpoints) }
            if type.hasPrefix("LoraLoader") { add(values.first as? String, &w.loras) }
            if type.hasPrefix("KSampler") {
                // KSampler: seed, control, steps, cfg, sampler, scheduler, denoise. KSamplerAdvanced: add_noise first.
                let v = type == "KSamplerAdvanced" ? Array(values.dropFirst()) : values
                if let seed = v.first as? NSNumber { add(seed.stringValue, &w.seeds) }
                if v.count > 2, let steps = v[2] as? NSNumber { add(steps.intValue, &w.steps) }
                if v.count > 3, let cfg = v[3] as? NSNumber { add(cfg.doubleValue, &w.cfgScales) }
                if v.count > 4 { add(v[4] as? String, &w.samplers) }
                if v.count > 5 { add(v[5] as? String, &w.schedulers) }
                for input in (node["inputs"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                    guard let name = input["name"] as? String, let link = (input["link"] as? NSNumber)?.intValue,
                          let source = linkSource[link], let t = text(of: byID[source]) else { continue }
                    if name == "positive" { add(MediaText.clean(t, max: MediaLimits.maxPromptCharacters), &w.positivePrompts) }
                    if name == "negative" { add(MediaText.clean(t, max: MediaLimits.maxPromptCharacters), &w.negativePrompts) }
                }
            }
        }
        return w
    }

    // MARK: XMP

    /// The IPTC digital source type's short name ("trainedAlgorithmicMedia").
    static func digitalSourceType(_ xmp: String) -> String? {
        guard let r = xmp.range(of: "digitalsourcetype/", options: .caseInsensitive) else { return nil }
        let name = xmp[r.upperBound...].prefix { $0.isLetter }
        return name.isEmpty ? nil : String(name)
    }

    static func creatorTool(_ xmp: String) -> String? {
        if let r = xmp.range(of: "CreatorTool=\"") {
            return MediaText.clean(String(xmp[r.upperBound...].prefix { $0 != "\"" }), max: 200)
        }
        if let r = xmp.range(of: "CreatorTool>"), let end = xmp[r.upperBound...].firstIndex(of: "<") {
            return MediaText.clean(String(xmp[r.upperBound..<end]), max: 200)
        }
        return nil
    }

    /// The text around "Steps: " in an XMP packet (exif:UserComment or dc:description written by A1111 exporters).
    static func xmpParameters(_ xmp: String) -> String? {
        guard let tree = MediaXMLElement.parse(Data(xmp.utf8)) else { return nil }
        var stack = [tree]
        while let el = stack.popLast() {
            if el.text.contains("Steps: ") { return MediaText.stripTags(el.text).isEmpty ? nil : el.text }
            for (_, v) in el.attributes where v.contains("Steps: ") { return v }
            stack.append(contentsOf: el.children)
        }
        return nil
    }
}
