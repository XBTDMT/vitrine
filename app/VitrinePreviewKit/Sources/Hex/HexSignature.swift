import Foundation

/// What a file's first bytes say it is ("Mach-O 64-bit", "PNG image"), and the bytes that say so: the evidence the
/// hex view tints and the pill and inspector name. Only published, well-known signatures; a match is a hint about the
/// format, never a verdict on the file. roadmap: S-5
public struct HexSignature: Sendable, Equatable {
    /// "Mach-O 64-bit", "ZIP archive".
    public var name: String
    /// The byte ranges the identification rests on (offset 0 for most; a PE header's "PE\0\0" further in).
    public var evidence: [Range<Int64>]

    public init(name: String, evidence: [Range<Int64>]) { self.name = name; self.evidence = evidence }

    /// How many leading bytes `identify` looks at.
    public static let sampleLength = 4096

    /// The signature at the start of `head` (the file's first bytes, up to `sampleLength`), or nil.
    public static func identify(_ head: [UInt8]) -> HexSignature? {
        func at(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            offset + bytes.count <= head.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
        func found(_ name: String, _ ranges: Range<Int64>...) -> HexSignature { HexSignature(name: name, evidence: ranges) }

        // Mach-O, thin, both byte orders.
        if at(0, [0xCF, 0xFA, 0xED, 0xFE]) || at(0, [0xFE, 0xED, 0xFA, 0xCF]) { return found(String(localized: "Mach-O 64-bit", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0xCE, 0xFA, 0xED, 0xFE]) || at(0, [0xFE, 0xED, 0xFA, 0xCE]) { return found(String(localized: "Mach-O 32-bit", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        // CA FE BA BE is both a universal binary and a Java class; a universal binary's next word is a small
        // architecture count, a class file's is its version (45 and up).
        if at(0, [0xCA, 0xFE, 0xBA, 0xBE]), head.count >= 8 {
            let next = UInt32(head[4]) << 24 | UInt32(head[5]) << 16 | UInt32(head[6]) << 8 | UInt32(head[7])
            return next > 0 && next < 30 ? found(String(localized: "Mach-O universal", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<8) : found(String(localized: "Java class", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4)
        }
        if at(0, [0xCA, 0xFE, 0xBA, 0xBF]) { return found(String(localized: "Mach-O universal 64-bit", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x7F, 0x45, 0x4C, 0x46]) {
            let width = head.count > 4 ? head[4] : 0
            let name = width == 2 ? String(localized: "ELF 64-bit", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are.")
                : width == 1 ? String(localized: "ELF 32-bit", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are.")
                : String(localized: "ELF", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are.")
            return found(name, 0..<(head.count > 4 ? 5 : 4))
        }
        if at(0, ascii("MZ")) {
            // The PE header's offset is the 32-bit little-endian word at 0x3C.
            if head.count >= 0x40 {
                let pe = Int(head[0x3C]) | Int(head[0x3D]) << 8 | Int(head[0x3E]) << 16 | Int(head[0x3F]) << 24
                if pe >= 0x40, at(pe, [0x50, 0x45, 0, 0]) {
                    return found(String(localized: "PE executable (Windows)", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<2, Int64(pe)..<Int64(pe + 4))
                }
            }
            return found(String(localized: "DOS executable", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<2)
        }
        if at(0, [0x00, 0x61, 0x73, 0x6D]) { return found(String(localized: "WebAssembly module", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, ascii("dex\n")) { return found(String(localized: "Android Dalvik executable", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return found(String(localized: "PNG image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<8) }
        if at(0, [0xFF, 0xD8, 0xFF]) { return found(String(localized: "JPEG image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<3) }
        if at(0, ascii("GIF87a")) || at(0, ascii("GIF89a")) { return found(String(localized: "GIF image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<6) }
        if at(0, ascii("II*\0")) || at(0, ascii("MM\0*")) { return found(String(localized: "TIFF image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, ascii("icns")) { return found(String(localized: "Apple icon image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, ascii("RIFF")), head.count >= 12 {
            if at(8, ascii("WEBP")) { return found(String(localized: "WebP image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4, 8..<12) }
            if at(8, ascii("WAVE")) { return found(String(localized: "WAV audio", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4, 8..<12) }
            if at(8, ascii("AVI ")) { return found(String(localized: "AVI video", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4, 8..<12) }
            return found(String(localized: "RIFF container", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4)
        }
        if at(4, ascii("ftyp")) {
            let brand = head.count >= 12 ? String(decoding: head[8..<12], as: UTF8.self) : ""
            let name = ["heic", "heix", "mif1"].contains(brand) ? String(localized: "HEIF image", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are.")
                : ["qt  "].contains(brand) ? String(localized: "QuickTime movie", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are.")
                : String(localized: "MPEG-4 media", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are.")
            return found(name, 4..<8)
        }
        if at(0, ascii("OggS")) { return found(String(localized: "Ogg media", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, ascii("fLaC")) { return found(String(localized: "FLAC audio", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, ascii("ID3")) { return found(String(localized: "MP3 audio (ID3)", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<3) }
        if at(0, ascii("%PDF-")) { return found(String(localized: "PDF document", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<5) }
        if at(0, ascii("SQLite format 3\0")) { return found(String(localized: "SQLite database", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<16) }
        if at(0, ascii("bplist00")) { return found(String(localized: "Binary property list", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<8) }
        if at(0, [0x50, 0x4B, 0x03, 0x04]) { return found(String(localized: "ZIP archive", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x50, 0x4B, 0x05, 0x06]) { return found(String(localized: "ZIP archive (empty)", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x1F, 0x8B]) { return found(String(localized: "gzip compressed", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<2) }
        if at(0, ascii("BZh")) { return found(String(localized: "bzip2 compressed", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<3) }
        if at(0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return found(String(localized: "xz compressed", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<6) }
        if at(0, [0x28, 0xB5, 0x2F, 0xFD]) { return found(String(localized: "Zstandard compressed", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x04, 0x22, 0x4D, 0x18]) { return found(String(localized: "LZ4 compressed", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return found(String(localized: "7-Zip archive", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<6) }
        if at(0, ascii("Rar!\u{1A}\u{07}")) { return found(String(localized: "RAR archive", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<6) }
        if at(257, ascii("ustar")) { return found(String(localized: "tar archive", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 257..<262) }
        if at(0, ascii("xar!")) { return found(String(localized: "XAR archive", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<4) }
        if at(0, [0x30, 0x82]) { return found(String(localized: "DER-encoded data (certificate or key)", bundle: .previewKit, comment: "A file format named from its first bytes, shown in the hex view and its summary. Keep format names as they are."), 0..<2) }
        return nil
    }
}
