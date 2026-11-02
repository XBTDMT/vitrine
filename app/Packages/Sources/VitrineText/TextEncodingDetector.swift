import Foundation

/// How a text file's bytes become text (code design state 3, I-16): a byte-order mark first, then UTF-8 when the bytes
/// are valid UTF-8 (a sequence cut at the end of a partial read does not count against it), then Foundation's
/// detector over the legacy encodings people actually meet. The result says whether it was detected, and which
/// non-ASCII characters it produced, so the page can say "“ë”, “í” are intact". roadmap: S-5
public enum TextEncodingDetector {
    public struct Decoded: Sendable, Equatable {
        public let text: String
        public let encoding: String.Encoding
        /// "UTF-8", "Windows-1252", "UTF-16LE" …
        public let name: String
        /// Not UTF-8 and not stated by a byte-order mark: chosen by looking at the bytes.
        public let detected: Bool
        /// A byte-order mark was present (and is not part of the text).
        public let hadBOM: Bool
        /// Up to four distinct non-ASCII characters, in order of appearance.
        public let samples: [Character]
        /// Some bytes could not be read in the chosen encoding and show as U+FFFD.
        public let lossy: Bool
    }

    /// The encodings "Reopen as…" offers, and the detector considers.
    public static let choices: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1, .macOSRoman, .isoLatin2, .windowsCP1250,
        .windowsCP1251, .shiftJIS, .japaneseEUC, String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
    ]

    public static func decode(_ data: Data, as forced: String.Encoding? = nil, partial: Bool = false) -> Decoded {
        if let forced { return make(data, forced, detected: false, bom: false) }
        // Byte-order marks.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return make(data.dropFirst(3), .utf8, detected: false, bom: true) }
        if data.starts(with: [0xFF, 0xFE]) { return make(data.dropFirst(2), .utf16LittleEndian, detected: false, bom: true) }
        if data.starts(with: [0xFE, 0xFF]) { return make(data.dropFirst(2), .utf16BigEndian, detected: false, bom: true) }
        // UTF-16 without a mark: every other byte zero in an ASCII-heavy file (zero bytes are valid UTF-8, so first).
        if let u16 = utf16WithoutMark(data) { return make(data, u16, detected: true, bom: false) }
        // UTF-8, allowing a sequence cut by a partial read.
        if isUTF8(data, allowCutEnd: partial) { return make(data, .utf8, detected: false, bom: false) }
        // Accented Latin text has its high bytes one at a time between ASCII letters; Windows-1252 is by far the
        // most common such encoding (Foundation's detector prefers 1250, which shares those letters but is rarer).
        if highByteRun(data) < 1.5, !hasUndefined1252(data) { return make(data, .windowsCP1252, detected: true, bom: false) }
        // Cyrillic, Central European words and the CJK encodings: Foundation's detector, over our list.
        var converted: NSString?
        var lossy: ObjCBool = false
        let raw = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: choices.dropFirst(3).map(\.rawValue),
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, converted != nil { return make(data, String.Encoding(rawValue: raw), detected: true, bom: false) }
        // Nothing fits cleanly: Windows-1252 reads every byte (five are undefined and show as U+FFFD).
        return make(data, .windowsCP1252, detected: true, bom: false)
    }

    public static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16LE"
        case .utf16BigEndian: return "UTF-16BE"
        case .windowsCP1252: return "Windows-1252"
        case .isoLatin1: return "ISO-8859-1"
        case .macOSRoman: return "Mac OS Roman"
        default:
            let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
            guard let iana = CFStringConvertEncodingToIANACharSetName(cf) as String? else { return String.localizedName(of: encoding) }
            return iana.uppercased().replacingOccurrences(of: "WINDOWS-", with: "Windows-")
        }
    }

    // MARK: Parts

    private static func make(_ bytes: Data, _ encoding: String.Encoding, detected: Bool, bom: Bool) -> Decoded {
        let data = Data(bytes)
        var text = encoding == .utf8 ? String(validating: data, as: UTF8.self) : String(data: data, encoding: encoding)
        var lossy = false
        if text == nil {
            lossy = true
            if encoding == .utf8 {
                text = String(decoding: data, as: UTF8.self)
            } else {
                // Byte by byte through the encoding, a replacement for what it cannot map.
                text = (NSString(data: data, encoding: encoding.rawValue) as String?) ?? String(decoding: data, as: UTF8.self)
            }
        }
        let s = text ?? ""
        var seen: [Character] = []
        for ch in s where !ch.isASCII && ch != "\u{FFFD}" {
            if !seen.contains(ch) { seen.append(ch); if seen.count == 4 { break } }
        }
        return Decoded(text: s, encoding: encoding, name: name(of: encoding), detected: detected, hadBOM: bom, samples: seen,
                       lossy: lossy || s.contains("\u{FFFD}") && encoding != .utf8)
    }

    /// Valid UTF-8; with `allowCutEnd`, up to three trailing bytes of an unfinished sequence are ignored.
    static func isUTF8(_ data: Data, allowCutEnd: Bool) -> Bool {
        var body = data
        if allowCutEnd {
            var cut = 0
            for b in data.suffix(3).reversed() {
                cut += 1
                if b & 0xC0 == 0xC0 { body = data.dropLast(cut); break }
                if b & 0x80 == 0 { break }
            }
        }
        return String(validating: body, as: UTF8.self) != nil
    }

    /// The average length of runs of bytes ≥ 0x80 (1 for isolated accented letters; longer for Cyrillic or CJK).
    static func highByteRun(_ data: Data) -> Double {
        var runs = 0, high = 0, inRun = false
        for b in data.prefix(1 << 20) {
            if b >= 0x80 { high += 1; if !inRun { runs += 1; inRun = true } } else { inRun = false }
        }
        return runs == 0 ? 0 : Double(high) / Double(runs)
    }

    /// Bytes Windows-1252 leaves undefined.
    static func hasUndefined1252(_ data: Data) -> Bool {
        data.prefix(1 << 20).contains { $0 == 0x81 || $0 == 0x8D || $0 == 0x8F || $0 == 0x90 || $0 == 0x9D }
    }

    private static func utf16WithoutMark(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 8, sample.count % 2 == 0 else { return nil }
        var evenZero = 0, oddZero = 0
        for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 0 { evenZero += 1 } else { oddZero += 1 } }
        let half = sample.count / 2
        if oddZero > half * 7 / 10, evenZero < half / 10 { return .utf16LittleEndian }
        if evenZero > half * 7 / 10, oddZero < half / 10 { return .utf16BigEndian }
        return nil
    }
}
