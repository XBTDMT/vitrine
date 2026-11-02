import Foundation

/// The media readers' entry point (S-23: N-2 EPUB and comics, N-6 maps, N-7 3D, N-8 audio tags, N-9 image details,
/// T-11 AI-image provenance). The format comes from the file name's extension, and from the first bytes when the
/// extension says nothing. Pure parsers over the bytes given: no network, no process, no other file. Every input is
/// untrusted: lists are capped (each summary says `truncated`), recursion is bounded, and a damaged file gives a
/// summary with a warning, or nil when it is not the format at all. roadmap: S-23
public enum MediaReader {
    /// The summary of `data`, named `fileName`; nil when it is not a format these readers know.
    public static func read(data: Data, fileName: String) -> MediaDocument? {
        let ext = MediaPath.ext(fileName)
        if let format = MediaFormat(extension: ext) ?? MediaFormat.sniff(data) {
            return read(data: data, fileName: fileName, as: format)
        }
        return nil
    }

    /// The summary of the file at `url`. The file is mapped, not copied, and only the parts a reader needs are
    /// touched; images go through ImageIO with the URL itself.
    public static func read(url: URL) -> MediaDocument? {
        let fileName = url.lastPathComponent
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        if case .image = MediaFormat(extension: MediaPath.ext(fileName)) ?? MediaFormat.sniff(data) {
            return MediaImageReader.read(url: url, data: data, fileName: fileName).map(MediaDocument.image)
        }
        return read(data: data, fileName: fileName)
    }

    /// The AI-image provenance of an image's bytes alone (PNG text chunks, XMP, EXIF UserComment, C2PA); nil when
    /// the image carries none.
    public static func provenance(data: Data) -> MediaProvenance? {
        MediaProvenanceReader.read(data: data, exifUserComment: nil)
    }

    static func read(data: Data, fileName: String, as format: MediaFormat) -> MediaDocument? {
        // Books, maps and models read at most 256 MB; a larger file is read as far as that.
        let capped = format.isCapped && data.count > MediaLimits.maxInputBytes
            ? data.prefix(MediaLimits.maxInputBytes) : data
        let wasCapped = capped.count < data.count
        switch format {
        case .epub:
            return MediaBookReader.readEPUB(capped, fileName: fileName).map(MediaDocument.book)
        case .comic:
            return MediaBookReader.readComic(capped, fileName: fileName).map(MediaDocument.comic)
        case .geoJSON, .gpx, .kml, .kmz:
            return MediaMapReader.read(capped, fileName: fileName, format: format, inputCapped: wasCapped).map(MediaDocument.map)
        case .stl, .obj, .threeMF, .gltf, .glb:
            return MediaModelReader.read(capped, fileName: fileName, format: format, inputCapped: wasCapped).map(MediaDocument.model)
        case .mp3, .mp4Audio, .flac, .ogg, .wav:
            return MediaAudioReader.read(data, fileName: fileName, format: format).map(MediaDocument.audio)
        case .image:
            return MediaImageReader.read(url: nil, data: data, fileName: fileName).map(MediaDocument.image)
        }
    }
}

/// What a media file turned out to be, with the summary its card and renderer need. roadmap: S-23
public enum MediaDocument: Sendable, Equatable {
    case book(MediaBookSummary)
    case comic(MediaComicSummary)
    case map(MediaMapSummary)
    case model(MediaModelSummary)
    case audio(MediaAudioSummary)
    case image(MediaImageSummary)

    /// The card's headline.
    public var headline: String {
        switch self {
        case .book(let s): s.headline
        case .comic(let s): s.headline
        case .map(let s): s.headline
        case .model(let s): s.headline
        case .audio(let s): s.headline
        case .image(let s): s.headline
        }
    }

    /// The card's labelled lines.
    public var facts: [MediaFact] {
        switch self {
        case .book(let s): s.facts
        case .comic(let s): s.facts
        case .map(let s): s.facts
        case .model(let s): s.facts
        case .audio(let s): s.facts
        case .image(let s): s.facts
        }
    }

    /// Warnings, most serious first.
    public var warnings: [MediaWarning] {
        let list: [MediaWarning]
        switch self {
        case .book(let s): list = s.warnings
        case .comic(let s): list = s.warnings
        case .map(let s): list = s.warnings
        case .model(let s): list = s.warnings
        case .audio(let s): list = s.warnings
        case .image(let s): list = s.warnings
        }
        return list.filter { $0.level == .danger } + list.filter { $0.level == .caution }
    }
}

/// The formats the media readers know. roadmap: S-23
enum MediaFormat: Sendable, Equatable {
    case epub, comic
    case geoJSON, gpx, kml, kmz
    case stl, obj, threeMF, gltf, glb
    case mp3, mp4Audio, flac, ogg, wav
    case image

    var isCapped: Bool {
        switch self {
        case .epub, .comic, .geoJSON, .gpx, .kml, .kmz, .stl, .obj, .threeMF, .gltf, .glb: true
        default: false
        }
    }

    init?(extension ext: String) {
        switch ext {
        case "epub": self = .epub
        case "cbz", "cbr", "cb7", "cbt": self = .comic
        case "geojson": self = .geoJSON
        case "gpx": self = .gpx
        case "kml": self = .kml
        case "kmz": self = .kmz
        case "stl": self = .stl
        case "obj": self = .obj
        case "3mf": self = .threeMF
        case "gltf": self = .gltf
        case "glb": self = .glb
        case "mp3", "mp2": self = .mp3
        case "m4a", "m4b", "m4r", "m4p", "mp4", "aac": self = .mp4Audio
        case "flac": self = .flac
        case "ogg", "oga", "opus": self = .ogg
        case "wav", "wave": self = .wav
        case "png", "apng", "jpg", "jpeg", "jpe", "gif", "webp", "heic", "heif", "heics", "avif", "tif", "tiff", "bmp",
             "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "jxl":
            self = .image
        default: return nil
        }
    }

    /// The format the first bytes name, for files whose extension says nothing.
    static func sniff(_ data: Data) -> MediaFormat? {
        let b = MediaBytes(data)
        if b.matches("ID3", at: 0) { return .mp3 }
        if b.matches("fLaC", at: 0) { return .flac }
        if b.matches("OggS", at: 0) { return .ogg }
        if b.matches("RIFF", at: 0) || b.matches("RF64", at: 0) {
            if b.matches("WAVE", at: 8) { return .wav }
            if b.matches("WEBP", at: 8) { return .image }
        }
        if b.matches("glTF", at: 0) { return .glb }
        if b.u8(0) == 0x89, b.matches("PNG", at: 1) { return .image }
        if b.u8(0) == 0xFF, b.u8(1) == 0xD8 { return .image }
        if b.matches("GIF8", at: 0) { return .image }
        if b.matches("ftyp", at: 4) {
            if b.matches("M4A ", at: 8) || b.matches("M4B ", at: 8) { return .mp4Audio }
            if ["heic", "heix", "mif1", "msf1", "avif", "avis", "hevc"].contains(where: { b.matches($0, at: 8) }) { return .image }
        }
        let head = String(decoding: b.bytes(0, 512), as: UTF8.self)
        if head.contains("<gpx") { return .gpx }
        if head.contains("<kml") { return .kml }
        if b.matches("PK\u{03}\u{04}", at: 0), b.matches("mimetype", at: 30), b.matches("application/epub+zip", at: 38) {
            return .epub
        }
        return nil
    }
}
