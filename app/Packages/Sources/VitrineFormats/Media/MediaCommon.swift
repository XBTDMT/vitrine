import Foundation
import VitrineArchive
import VitrineSupport

// Shared pieces of the media readers (S-23): the warning and fact types every summary carries, bounds-checked
// byte reads over untrusted `Data`, text decoding, a small capped XML element tree, and member reads through
// VitrineArchive. Internal names start with `Media` so they never collide with the other readers in this module.

/// A warning a media card shows: how serious it is and why, in plain English. roadmap: S-23
public struct MediaWarning: Sendable, Equatable, Hashable {
    /// `caution` is worth knowing (a protected book, a photo that records where it was taken); `danger` means the
    /// file is damaged or may not be what it claims.
    public enum Level: String, Sendable, Equatable, Hashable { case caution, danger }

    public var level: Level
    public var reason: String

    public init(_ level: Level, _ reason: String) {
        self.level = level
        self.reason = reason
    }
}

/// One labelled line of a card ("Pages", "312"). roadmap: S-23
public struct MediaFact: Sendable, Equatable, Hashable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A name and how often it occurs (geometry types, node classes), kept in a stable order. roadmap: S-23
public struct MediaCount: Sendable, Equatable, Hashable {
    public var name: String
    public var count: Int

    public init(_ name: String, _ count: Int) {
        self.name = name
        self.count = count
    }
}

// MARK: - Limits

enum MediaLimits {
    /// The most a 3D, map or book reader reads (the brief's 256 MB).
    static let maxInputBytes = 256 * 1024 * 1024
    /// Book and comic covers.
    static let maxCoverBytes = 4 * 1024 * 1024
    /// Audio cover art.
    static let maxAudioCoverBytes = 2 * 1024 * 1024
    /// A book's description, in characters.
    static let maxDescriptionCharacters = 2_000
    /// Strings shown on a card (a title, a prompt), in characters.
    static let maxTextCharacters = 4_000
    /// Long prompts.
    static let maxPromptCharacters = 8_000
    /// Small XML parts read whole (container.xml, an OPF, a nav document, ComicInfo.xml).
    static let maxXMLPartBytes = 8 * 1024 * 1024
}

// MARK: - Bytes

/// Bounds-checked reads over untrusted `Data` (which may be a slice with a non-zero start index). Every accessor
/// returns nil, or a clipped result, instead of trapping.
struct MediaBytes: Sendable {
    let data: Data
    let base: Int
    let count: Int

    init(_ data: Data) {
        self.data = data
        base = data.startIndex
        count = data.count
    }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return data[base + offset]
    }

    func be16(_ o: Int) -> UInt16? {
        guard o >= 0, count - o >= 2 else { return nil }
        return UInt16(data[base + o]) << 8 | UInt16(data[base + o + 1])
    }

    func be24(_ o: Int) -> UInt32? {
        guard o >= 0, count - o >= 3 else { return nil }
        return UInt32(data[base + o]) << 16 | UInt32(data[base + o + 1]) << 8 | UInt32(data[base + o + 2])
    }

    func be32(_ o: Int) -> UInt32? {
        guard o >= 0, count - o >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(data[base + o + i]) }
        return v
    }

    func be64(_ o: Int) -> UInt64? {
        guard o >= 0, count - o >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(data[base + o + i]) }
        return v
    }

    func le16(_ o: Int) -> UInt16? {
        guard o >= 0, count - o >= 2 else { return nil }
        return UInt16(data[base + o]) | UInt16(data[base + o + 1]) << 8
    }

    func le32(_ o: Int) -> UInt32? {
        guard o >= 0, count - o >= 4 else { return nil }
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = v << 8 | UInt32(data[base + o + i]) }
        return v
    }

    func le64(_ o: Int) -> UInt64? {
        guard o >= 0, count - o >= 8 else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(data[base + o + i]) }
        return v
    }

    /// Up to `length` bytes at `offset`, clipped to the end; empty when out of range.
    func bytes(_ offset: Int, _ length: Int) -> [UInt8] {
        guard offset >= 0, length > 0, offset < count else { return [] }
        let end = offset + min(length, count - offset)
        return [UInt8](data[(base + offset)..<(base + end)])
    }

    /// Up to `length` bytes at `offset` as `Data`, clipped to the end.
    func sub(_ offset: Int, _ length: Int) -> Data {
        guard offset >= 0, length > 0, offset < count else { return Data() }
        let end = offset + min(length, count - offset)
        return Data(data[(base + offset)..<(base + end)])
    }

    func matches(_ ascii: String, at offset: Int) -> Bool {
        let expected = Array(ascii.utf8)
        guard offset >= 0, count - offset >= expected.count else { return false }
        for (i, b) in expected.enumerated() where data[base + offset + i] != b { return false }
        return true
    }

    func fourCC(_ offset: Int) -> String? {
        let b = bytes(offset, 4)
        guard b.count == 4 else { return nil }
        return String(decoding: b, as: UTF8.self)
    }

    /// The first offset at or after `from` where `needle` occurs, searching at most up to `limit`.
    func find(_ needle: [UInt8], from: Int = 0, limit: Int? = nil) -> Int? {
        guard let first = needle.first, !needle.isEmpty else { return nil }
        let stop = min(count, limit ?? count) - needle.count
        guard stop >= from else { return nil }
        return data.withUnsafeBytes { raw -> Int? in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var i = max(0, from)
            while i <= stop {
                if p[i] == first {
                    var hit = true
                    for j in 1..<needle.count where p[i + j] != needle[j] { hit = false; break }
                    if hit { return i }
                }
                i += 1
            }
            return nil
        }
    }
}

extension Array where Element == UInt8 {
    func mediaBE32(_ o: Int) -> UInt32? {
        guard o >= 0, count - o >= 4 else { return nil }
        return UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }

    func mediaLE32(_ o: Int) -> UInt32? {
        guard o >= 0, count - o >= 4 else { return nil }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
}

// MARK: - Text

enum MediaText {
    /// The reason given when nothing more precise is known.
    static var unknownReason: String {
        String(localized: "it could not be read", bundle: .module, comment: "Why a part inside a file cannot be read, when no precise reason is known.")
    }

    static func latin1(_ bytes: some Collection<UInt8>) -> String {
        String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    static func utf8(_ bytes: some Collection<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// UTF-16 with an optional byte-order mark; big-endian when there is none unless `littleEndian` is set.
    static func utf16(_ bytes: [UInt8], littleEndianDefault: Bool = false) -> String {
        var little = littleEndianDefault
        var start = 0
        if bytes.count >= 2 {
            if bytes[0] == 0xFF, bytes[1] == 0xFE { little = true; start = 2 }
            else if bytes[0] == 0xFE, bytes[1] == 0xFF { little = false; start = 2 }
        }
        var units: [UInt16] = []
        units.reserveCapacity((bytes.count - start) / 2)
        var i = start
        while i + 1 < bytes.count {
            units.append(little ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Trims, drops trailing NULs and caps the length; nil when nothing is left.
    static func clean(_ s: String?, max: Int = MediaLimits.maxTextCharacters) -> String? {
        guard let s else { return nil }
        let trimmed = s.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return cap(trimmed, max)
    }

    static func cap(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + "…"
    }

    /// Strips markup tags and collapses whitespace (a book's HTML description).
    static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; out.append(" "); continue }
            if !inTag { out.append(ch) }
        }
        let decoded = out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        return decoded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func meters(_ m: Double) -> String {
        m >= 1000 ? "\(number(m / 1000, digits: 2)) km" : "\(number(m, digits: 0)) m"
    }

    /// `h:mm:ss` (or `m:ss`); "—" when the file's duration is negative, not a number, or past what an Int holds.
    static func duration(_ seconds: Double) -> String {
        guard seconds >= 0, let total = FormatMath.int(rounding: seconds) else { return "—" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytesString(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - XML

/// A small element tree from Foundation's `XMLParser` for the XML parts read whole. External entities are never
/// resolved; depth, element count and text are capped, so a hostile part costs a bounded amount. Names are kept
/// both qualified (`dc:title`) and local (`title`).
struct MediaXMLElement: Sendable, Equatable {
    var name: String
    var localName: String
    var attributes: [String: String]
    var children: [MediaXMLElement]
    var text: String

    /// An attribute by qualified or local name.
    func attribute(_ key: String) -> String? {
        if let v = attributes[key] { return v }
        for (k, v) in attributes where MediaXMLElement.local(k) == key { return v }
        return nil
    }

    func child(_ local: String) -> MediaXMLElement? { children.first { $0.localName == local } }
    func children(_ local: String) -> [MediaXMLElement] { children.filter { $0.localName == local } }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Every descendant with the local name, depth first, at most `limit`.
    func descendants(_ local: String, limit: Int = 100_000) -> [MediaXMLElement] {
        var out: [MediaXMLElement] = []
        var stack = Array(children.reversed())
        while let next = stack.popLast(), out.count < limit {
            if next.localName == local { out.append(next) }
            stack.append(contentsOf: next.children.reversed())
        }
        return out
    }

    /// All text below this element, in order.
    var allText: String {
        var out = text
        for c in children { out += c.allText }
        return out
    }

    static func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    static let maxDepth = 96
    static let maxElements = 200_000
    static let maxText = 16 * 1024 * 1024

    static func parse(_ data: Data) -> MediaXMLElement? {
        let builder = MediaXMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = builder
        let ok = parser.parse()
        guard ok, !builder.limitHit, let root = builder.root else { return nil }
        return root
    }
}

private final class MediaXMLTreeBuilder: NSObject, XMLParserDelegate {
    var stack: [MediaXMLElement] = []
    var root: MediaXMLElement?
    var count = 0
    var textBytes = 0
    var limitHit = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        if count > MediaXMLElement.maxElements || stack.count >= MediaXMLElement.maxDepth {
            limitHit = true
            parser.abortParsing()
            return
        }
        stack.append(MediaXMLElement(name: elementName, localName: MediaXMLElement.local(elementName),
                                     attributes: attributeDict, children: [], text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        textBytes += string.utf8.count
        if textBytes > MediaXMLElement.maxText { limitHit = true; parser.abortParsing(); return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let done = stack.popLast() else { return }
        if stack.isEmpty { root = done } else { stack[stack.count - 1].children.append(done) }
    }
}

/// Runs a streaming delegate over XML; false when the document is not well formed (and nothing was aborted on
/// purpose by the delegate, which it reports through `stoppedOnPurpose`).
enum MediaXMLStream {
    static func run(_ data: Data, delegate: XMLParserDelegate) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        return parser.parse()
    }
}

// MARK: - Archives

/// `ByteSource` over `Data` without copying it into an array.
struct MediaDataSource: ByteSource {
    let data: Data
    var size: Int64 { Int64(data.count) }

    func read(at offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count > 0, offset < size else { return [] }
        let start = data.startIndex + Int(offset)
        let end = start + min(count, data.count - Int(offset))
        return [UInt8](data[start..<end])
    }
}

/// An archive listed through VitrineArchive, with member reads by path.
struct MediaArchive {
    let source: MediaDataSource
    let fileName: String
    let listing: ArchiveListing

    static func open(_ data: Data, fileName: String) -> MediaArchive? {
        let source = MediaDataSource(data: data)
        guard let listing = try? VitrineArchive.list(source: source, fileName: fileName) else { return nil }
        return MediaArchive(source: source, fileName: fileName, listing: listing)
    }

    var isZip: Bool { listing.format == .zip }

    /// Indices of regular files, in listing order.
    var fileIndices: [Int] {
        listing.entries.indices.filter { listing.entries[$0].type == .file || listing.entries[$0].type == .hardlink }
    }

    func path(_ index: Int) -> String { listing.entries[index].path }

    /// The member at `path` (exact normalized match first, then case-insensitive).
    func index(of path: String) -> Int? {
        let wanted = ArchivePath.normalized(path)
        let files = fileIndices
        if let i = files.last(where: { ArchivePath.normalized(listing.entries[$0].path) == wanted }) { return i }
        let lower = wanted.lowercased()
        return files.last { ArchivePath.normalized(listing.entries[$0].path).lowercased() == lower }
    }

    func contains(_ path: String) -> Bool { index(of: path) != nil }

    /// The member's bytes when it is at most `limit` long and reads whole; nil otherwise.
    func read(_ index: Int, limit: Int) -> Data? {
        let entry = listing.entries[index]
        if let size = entry.uncompressedSize, size > Int64(limit), !entry.uncompressedSizeIsModulo4GiB { return nil }
        guard let member = try? VitrineArchive.memberData(source: source, fileName: fileName, listing: listing,
                                                          entryIndex: index, limit: limit),
              member.isComplete else { return nil }
        return Data(member.bytes)
    }

    /// Why a member could not be read, for a card's note.
    func readFailure(_ index: Int, limit: Int) -> String? {
        let entry = listing.entries[index]
        if entry.isEncrypted { return String(localized: "the member is encrypted", bundle: .module, comment: "Why a part inside a book, comic or package cannot be read.") }
        if let size = entry.uncompressedSize, size > Int64(limit), !entry.uncompressedSizeIsModulo4GiB {
            return String(localized: "it is \(MediaText.bytesString(Int(size))), over the \(MediaText.bytesString(limit)) limit", bundle: .module, comment: "Why a part inside a file cannot be read. The arguments are sizes.")
        }
        do {
            let member = try VitrineArchive.memberData(source: source, fileName: fileName, listing: listing,
                                                       entryIndex: index, limit: limit)
            return member.isComplete ? nil : String(localized: "it is larger than \(MediaText.bytesString(limit))", bundle: .module, comment: "Why a part inside a file cannot be read. The argument is a size.")
        } catch let error as ArchiveError {
            return error.reason
        } catch {
            return MediaText.unknownReason
        }
    }

    func read(path: String, limit: Int) -> Data? {
        guard let i = index(of: path) else { return nil }
        return read(i, limit: limit)
    }
}

// MARK: - Paths and names

enum MediaPath {
    /// The extension of a file name, lowercased, without the dot.
    static func ext(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return "" }
        return fileName[fileName.index(after: dot)...].lowercased()
    }

    /// `href` resolved against the directory of `base` inside an archive (`OEBPS/content.opf` + `../img/a.jpg`),
    /// with any fragment or query removed and percent escapes decoded.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        var h = href
        if let hash = h.firstIndex(of: "#") { h = String(h[..<hash]) }
        if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
        h = h.removingPercentEncoding ?? h
        if h.hasPrefix("/") { return ArchivePath.normalized(h) }
        var parts = ArchivePath.components(base)
        if !parts.isEmpty { parts.removeLast() }
        for comp in ArchivePath.components(h) {
            if comp == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(comp) }
        }
        return parts.joined(separator: "/")
    }

    /// The last path component.
    static func base(_ path: String) -> String { ArchivePath.components(path).last ?? path }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "tif", "tiff", "heic", "jxl"]

    static func imageMime(_ path: String) -> String? {
        switch ext(path) {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "bmp": "image/bmp"
        case "tif", "tiff": "image/tiff"
        case "heic": "image/heic"
        case "jxl": "image/jxl"
        default: nil
        }
    }

    /// The MIME type a picture's first bytes say.
    static func sniffImageMime(_ data: Data) -> String? {
        let b = MediaBytes(data)
        if b.u8(0) == 0xFF, b.u8(1) == 0xD8 { return "image/jpeg" }
        if b.matches("\u{89}PNG", at: 0) || (b.u8(0) == 0x89 && b.matches("PNG", at: 1)) { return "image/png" }
        if b.matches("GIF8", at: 0) { return "image/gif" }
        if b.matches("RIFF", at: 0), b.matches("WEBP", at: 8) { return "image/webp" }
        if b.matches("BM", at: 0) { return "image/bmp" }
        if b.matches("ftyp", at: 4) {
            if b.matches("avif", at: 8) { return "image/avif" }
            return "image/heic"
        }
        return nil
    }
}

/// Natural ordering for page names ("page2" before "page10").
enum MediaSort {
    static func natural(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
