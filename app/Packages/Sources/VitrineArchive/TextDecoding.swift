import Foundation

/// Name decoding shared by the readers. Archive names are bytes; which characters they mean depends on the writer,
/// so each reader picks a rule and records it in `PathEncoding`. Control bytes are kept, never dropped, so the
/// safety report can see them.
enum TextDecoding {
    /// IBM code page 437, the zip default when bit 11 is clear. 0x00–0x7F are ASCII (control codes stay control
    /// codes: they are names, not screen glyphs); 0x80–0xFF follow the code page.
    static let cp437High: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
        + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}")

    static func cp437(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for b in bytes {
            if b < 0x80 {
                scalars.append(Unicode.Scalar(b))
            } else {
                scalars.append(contentsOf: cp437High[Int(b - 0x80)].unicodeScalars)
            }
        }
        return String(scalars)
    }

    /// Strict UTF-8: nil when any sequence is invalid.
    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        String(validating: bytes, as: UTF8.self)
    }

    /// ISO Latin-1: every byte is the code point of the same value.
    static func latin1(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    }

    static func isASCII(_ bytes: [UInt8]) -> Bool { bytes.allSatisfy { $0 < 0x80 } }

    /// UTF-8 when valid, else Latin-1 (tar names and pax values).
    static func utf8OrLatin1(_ bytes: [UInt8]) -> (String, PathEncoding) {
        if let s = strictUTF8(bytes) { return (s, .utf8) }
        return (latin1(bytes), .latin1)
    }
}

/// CRC-32 (IEEE 802.3, the zip and gzip polynomial), used to check Info-ZIP Unicode path fields against the stored
/// name and gzip header CRCs.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var c = ~seed
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}
