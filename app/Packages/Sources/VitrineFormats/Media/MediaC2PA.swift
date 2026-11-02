import Foundation

/// One action a C2PA manifest records (`c2pa.created`, `c2pa.edited` …). roadmap: S-23
public struct MediaC2PAAction: Sendable, Equatable {
    public var action: String
    /// The IPTC digital source type URI, when the action states one.
    public var digitalSourceType: String?
    public var softwareAgent: String?
    public var when: String?
}

/// What a C2PA (Content Credentials) manifest store says. The signature's presence is reported; it is never
/// verified, so nothing here proves who made the image. roadmap: S-23
public struct MediaC2PASummary: Sendable, Equatable {
    /// Where the manifest store was found ("JPEG APP11", "PNG caBX", "ISO BMFF uuid box", "WebP C2PA chunk").
    public var container: String
    public var manifestCount: Int
    /// The active (last) manifest's label (`urn:uuid:…`).
    public var activeManifestLabel: String?
    public var claimGenerator: String?
    public var title: String?
    public var format: String?
    /// Assertion labels in the active manifest ("c2pa.actions", "c2pa.hash.data" …), at most 100.
    public var assertions: [String]
    public var actions: [MediaC2PAAction]
    public var ingredientCount: Int
    /// An action's digital source type is trainedAlgorithmicMedia or compositeWithTrainedAlgorithmicMedia.
    public var madeWithAI: Bool
    /// The short name of the AI source type, when there is one.
    public var aiSourceType: String?
    /// The active manifest has a signature box with content.
    public var signaturePresent: Bool
    /// Always false: Vitrine does not verify C2PA signatures.
    public var signatureVerified: Bool
    /// Why the store could be read only in part.
    public var note: String?
}

// MARK: - CBOR

/// A CBOR value (RFC 8949), decoded with bounded depth and item count. Byte strings keep their length and at most
/// their first 64 bytes, because nothing here needs their contents.
indirect enum MediaCBOR: Equatable {
    case unsigned(UInt64)
    case negative(UInt64)          // -1 - n
    case bytes(count: Int, prefix: [UInt8])
    case text(String)
    case array([MediaCBOR])
    case map([(MediaCBOR, MediaCBOR)])
    case tagged(UInt64, MediaCBOR)
    case bool(Bool)
    case null
    case float(Double)

    static func == (a: MediaCBOR, b: MediaCBOR) -> Bool {
        switch (a, b) {
        case (.unsigned(let x), .unsigned(let y)), (.negative(let x), .negative(let y)): x == y
        case (.bytes(let c1, let p1), .bytes(let c2, let p2)): c1 == c2 && p1 == p2
        case (.text(let x), .text(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.tagged(let t1, let v1), .tagged(let t2, let v2)): t1 == t2 && v1 == v2
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        case (.float(let x), .float(let y)): x == y
        default: false
        }
    }

    var untagged: MediaCBOR { if case .tagged(_, let v) = self { v.untagged } else { self } }
    var string: String? { if case .text(let s) = untagged { s } else { nil } }
    var arrayValue: [MediaCBOR]? { if case .array(let a) = untagged { a } else { nil } }

    subscript(key: String) -> MediaCBOR? {
        guard case .map(let pairs) = untagged else { return nil }
        return pairs.first { $0.0.string == key }?.1
    }

    static func decode(_ bytes: [UInt8]) -> MediaCBOR? {
        var reader = MediaCBORReader(bytes: bytes)
        return reader.value(depth: 0)
    }
}

struct MediaCBORReader {
    let bytes: [UInt8]
    var i = 0
    var items = 0
    static let maxDepth = 32
    static let maxItems = 200_000

    mutating func byte() -> UInt8? {
        guard i < bytes.count else { return nil }
        defer { i += 1 }
        return bytes[i]
    }

    mutating func argument(_ info: UInt8) -> UInt64? {
        switch info {
        case 0..<24: return UInt64(info)
        case 24: return byte().map(UInt64.init)
        case 25, 26, 27:
            let n = info == 25 ? 2 : info == 26 ? 4 : 8
            guard i + n <= bytes.count else { return nil }
            var v: UInt64 = 0
            for k in 0..<n { v = v << 8 | UInt64(bytes[i + k]) }
            i += n
            return v
        default: return nil
        }
    }

    mutating func value(depth: Int) -> MediaCBOR? {
        items += 1
        guard depth < Self.maxDepth, items < Self.maxItems, let initial = byte() else { return nil }
        let major = initial >> 5, info = initial & 0x1F
        if info == 31 {                                                       // indefinite length
            switch major {
            case 2, 3:
                var count = 0
                var text: [UInt8] = []
                while true {
                    guard i < bytes.count else { return nil }
                    if bytes[i] == 0xFF { i += 1; break }
                    guard let chunk = value(depth: depth + 1) else { return nil }
                    switch chunk {
                    case .bytes(let c, _): count += c
                    case .text(let t): text += Array(t.utf8)
                    default: return nil
                    }
                }
                return major == 2 ? .bytes(count: count, prefix: []) : .text(String(decoding: text, as: UTF8.self))
            case 4:
                var out: [MediaCBOR] = []
                while true {
                    guard i < bytes.count else { return nil }
                    if bytes[i] == 0xFF { i += 1; break }
                    guard let v = value(depth: depth + 1) else { return nil }
                    out.append(v)
                }
                return .array(out)
            case 5:
                var out: [(MediaCBOR, MediaCBOR)] = []
                while true {
                    guard i < bytes.count else { return nil }
                    if bytes[i] == 0xFF { i += 1; break }
                    guard let k = value(depth: depth + 1), let v = value(depth: depth + 1) else { return nil }
                    out.append((k, v))
                }
                return .map(out)
            default: return nil
            }
        }
        if major == 7 {
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null
            case 25:
                guard let h = argument(25) else { return nil }
                return .float(mediaHalfToDouble(UInt16(truncatingIfNeeded: h)))
            case 26:
                guard let f = argument(26) else { return nil }
                return .float(Double(Float(bitPattern: UInt32(f))))
            case 27:
                guard let d = argument(27) else { return nil }
                return .float(Double(bitPattern: d))
            default:
                return info < 24 ? .null : (argument(info) != nil ? .null : nil)
            }
        }
        guard let arg = argument(info) else { return nil }
        switch major {
        case 0: return .unsigned(arg)
        case 1: return .negative(arg)
        case 2, 3:
            guard arg <= UInt64(bytes.count - i) else { return nil }
            let n = Int(arg)
            defer { i += n }
            if major == 2 { return .bytes(count: n, prefix: Array(bytes[i..<(i + min(n, 64))])) }
            return .text(String(decoding: bytes[i..<(i + min(n, 64 * 1024))], as: UTF8.self))
        case 4:
            guard arg <= UInt64(bytes.count - i) else { return nil }               // each item is at least a byte
            var out: [MediaCBOR] = []
            for _ in 0..<Int(arg) {
                guard let v = value(depth: depth + 1) else { return nil }
                out.append(v)
            }
            return .array(out)
        case 5:
            guard arg <= UInt64(bytes.count - i) / 2 else { return nil }
            var out: [(MediaCBOR, MediaCBOR)] = []
            for _ in 0..<Int(arg) {
                guard let k = value(depth: depth + 1), let v = value(depth: depth + 1) else { return nil }
                out.append((k, v))
            }
            return .map(out)
        case 6:
            guard let v = value(depth: depth + 1) else { return nil }
            return .tagged(arg, v)
        default: return nil
        }
    }
}

// MARK: - JUMBF

/// A JUMBF box (ISO/IEC 19566-5): superboxes (`jumb`) hold a description (`jumd`: type UUID and label) and
/// content boxes (`cbor`, `json`, `c2sh` …).
struct MediaJUMBFBox {
    var type: String
    var payload: ArraySlice<UInt8>
    var children: [MediaJUMBFBox]
    /// The first four bytes of the description's type UUID ("c2pa", "c2ma", "c2as", "c2cl", "c2cs", "cbor").
    var descriptionType: String?
    var label: String?

    static let maxBoxes = 10_000

    static func parse(_ bytes: ArraySlice<UInt8>, depth: Int = 0, budget: inout Int) -> [MediaJUMBFBox] {
        var out: [MediaJUMBFBox] = []
        var o = bytes.startIndex
        while o + 8 <= bytes.endIndex, budget > 0, depth < 16 {
            budget -= 1
            let lbox = UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
            let type = String(decoding: bytes[(o + 4)..<(o + 8)], as: UTF8.self)
            var header = 8
            var length = Int(lbox)
            if lbox == 1 {
                guard o + 16 <= bytes.endIndex else { break }
                var xl: UInt64 = 0
                for k in 0..<8 { xl = xl << 8 | UInt64(bytes[o + 8 + k]) }
                guard xl < UInt64(Int.max) else { break }
                length = Int(xl)
                header = 16
            } else if lbox == 0 {
                length = bytes.endIndex - o
            }
            guard length >= header else { break }
            // `length > endIndex - o`, never `o + length`: a 64-bit XLBox near Int.max would overflow the sum.
            let end = length > bytes.endIndex - o ? bytes.endIndex : o + length
            var box = MediaJUMBFBox(type: type, payload: bytes[(o + header)..<end], children: [], descriptionType: nil, label: nil)
            if type == "jumb" {
                box.children = parse(box.payload, depth: depth + 1, budget: &budget)
                if let d = box.children.first, d.type == "jumd", d.payload.count >= 17 {
                    let p = d.payload
                    box.descriptionType = String(decoding: p[p.startIndex..<(p.startIndex + 4)], as: UTF8.self)
                    let toggles = p[p.startIndex + 16]
                    if toggles & 0x02 != 0 {
                        let start = p.startIndex + 17
                        let stop = p[start...].firstIndex(of: 0) ?? p.endIndex
                        box.label = String(decoding: p[start..<stop], as: UTF8.self)
                    }
                }
            }
            out.append(box)
            if end >= bytes.endIndex { break }
            o = end
        }
        return out
    }

    func superbox(_ descriptionType: String) -> [MediaJUMBFBox] {
        children.filter { $0.type == "jumb" && $0.descriptionType == descriptionType }
    }

    func content(_ type: String) -> MediaJUMBFBox? { children.first { $0.type == type } }
}

enum MediaC2PA {
    /// Reads a manifest store's JUMBF bytes.
    static func summarize(_ jumbf: [UInt8], container: String) -> MediaC2PASummary? {
        var budget = MediaJUMBFBox.maxBoxes
        let top = MediaJUMBFBox.parse(jumbf[...], budget: &budget)
        guard let store = top.first(where: { $0.type == "jumb" && ($0.descriptionType == "c2pa" || $0.label == "c2pa") }) else { return nil }
        var s = MediaC2PASummary(container: container, manifestCount: 0, activeManifestLabel: nil, claimGenerator: nil,
                                 title: nil, format: nil, assertions: [], actions: [], ingredientCount: 0, madeWithAI: false,
                                 aiSourceType: nil, signaturePresent: false, signatureVerified: false, note: nil)
        let manifests = store.children.filter { $0.type == "jumb" && ($0.descriptionType == "c2ma" || $0.descriptionType == "c2um") }
        s.manifestCount = manifests.count
        guard let active = manifests.last else {
            s.note = String(localized: "The manifest store holds no manifest.", bundle: .module, comment: "C2PA reading note.")
            return s
        }
        s.activeManifestLabel = active.label

        // Claim.
        let claimBox = active.superbox("c2cl").first ?? active.children.first { $0.type == "jumb" && ($0.label ?? "").hasPrefix("c2pa.claim") }
        if let cbor = claimBox?.content("cbor"), let claim = MediaCBOR.decode(Array(cbor.payload)) {
            if let g = claim["claim_generator"]?.string { s.claimGenerator = MediaText.clean(g, max: 200) }
            if s.claimGenerator == nil, let info = claim["claim_generator_info"] {
                let entry = info.arrayValue?.first ?? info
                let name = entry["name"]?.string
                let version = entry["version"]?.string
                s.claimGenerator = MediaText.clean([name, version].compactMap { $0 }.joined(separator: " "), max: 200)
            }
            s.title = MediaText.clean(claim["dc:title"]?.string, max: 300)
            s.format = claim["dc:format"]?.string
        } else {
            s.note = String(localized: "The claim could not be decoded.", bundle: .module, comment: "C2PA reading note.")
        }

        // Signature: present when its box has content. Never verified.
        if let sig = active.superbox("c2cs").first ?? active.children.first(where: { $0.type == "jumb" && ($0.label ?? "").hasPrefix("c2pa.signature") }) {
            s.signaturePresent = sig.children.dropFirst().contains { !$0.payload.isEmpty }
        }

        // Assertions.
        if let store = active.superbox("c2as").first ?? active.children.first(where: { $0.type == "jumb" && $0.label == "c2pa.assertions" }) {
            for assertion in store.children where assertion.type == "jumb" {
                let label = assertion.label ?? "?"
                if s.assertions.count < 100 { s.assertions.append(label) }
                if label.hasPrefix("c2pa.ingredient") { s.ingredientCount += 1 }
                guard label.hasPrefix("c2pa.actions"), let cbor = assertion.content("cbor"),
                      let value = MediaCBOR.decode(Array(cbor.payload)) else { continue }
                for item in value["actions"]?.arrayValue?.prefix(100) ?? [] {
                    guard let action = item["action"]?.string else { continue }
                    let agent = item["softwareAgent"]?.string ?? item["softwareAgent"]?["name"]?.string
                    let source = item["digitalSourceType"]?.string
                    s.actions.append(MediaC2PAAction(action: action, digitalSourceType: source,
                                                     softwareAgent: MediaText.clean(agent, max: 200), when: item["when"]?.string))
                    if let source, let short = aiSourceType(source) {
                        s.madeWithAI = true
                        s.aiSourceType = short
                    }
                }
            }
        }
        return s
    }

    /// "trainedAlgorithmicMedia" or "compositeWithTrainedAlgorithmicMedia" for the IPTC URIs that mean AI.
    static func aiSourceType(_ uri: String) -> String? {
        let short = uri.split(separator: "/").last.map(String.init) ?? uri
        return ["trainedalgorithmicmedia", "compositewithtrainedalgorithmicmedia"].contains(short.lowercased()) ? short : nil
    }

    static let isobmffUUID: [UInt8] = [0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C, 0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81]
}


/// IEEE 754 half precision → Double, by hand: `Float16` does not exist on Intel Macs. roadmap: S-23
func mediaHalfToDouble(_ bits: UInt16) -> Double {
    let sign: Double = bits & 0x8000 == 0 ? 1 : -1
    let exponent = Int((bits >> 10) & 0x1F), fraction = Double(bits & 0x3FF)
    switch exponent {
    case 0: return sign * fraction * pow(2, -24)
    case 31: return fraction == 0 ? sign * .infinity : .nan
    default: return sign * (1 + fraction / 1024) * pow(2, Double(exponent - 15))
    }
}
