import Foundation
import VitrineArchive

/// A picture a file carries (a book or comic cover, an album's art), with the MIME type it declares or its bytes
/// show. roadmap: S-23
public struct MediaPicture: Sendable, Equatable {
    public var data: Data
    public var mimeType: String
    /// The ID3/FLAC picture type ("Front cover") when the file names one.
    public var pictureType: String?
    public var description: String?

    public init(data: Data, mimeType: String, pictureType: String? = nil, description: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.pictureType = pictureType
        self.description = description
    }
}

/// A book's author, translator or other contributor. roadmap: S-23
public struct MediaBookCreator: Sendable, Equatable {
    public var name: String
    /// The MARC relator code or role the book gives (`aut`, `trl`, `ill`), when it gives one.
    public var role: String?

    public init(name: String, role: String?) {
        self.name = name
        self.role = role
    }
}

/// One line of a book's table of contents. roadmap: S-23
public struct MediaTOCEntry: Sendable, Equatable {
    public var title: String
    /// 1 for top-level entries, at most 4.
    public var depth: Int
    /// The target inside the book, resolved against the archive's root.
    public var target: String?

    public init(title: String, depth: Int, target: String?) {
        self.title = title
        self.depth = depth
        self.target = target
    }
}

/// An EPUB 2 or 3 book (N-2): its metadata, cover, spine length and table of contents. roadmap: S-23
public struct MediaBookSummary: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// The package's `version` attribute ("2.0", "3.0").
    public var epubVersion: String?
    public var title: String?
    public var creators: [MediaBookCreator]
    public var language: String?
    public var publisher: String?
    public var date: String?
    public var identifiers: [String]
    /// Plain text, tags removed, at most 2,000 characters.
    public var description: String?
    /// Reading-order items (spine `itemref`s).
    public var spineLength: Int
    public var manifestItemCount: Int
    /// The cover image's bytes, when it is at most 4 MB.
    public var cover: MediaPicture?
    /// Why there is no cover, when one was named but not read.
    public var coverNote: String?
    public var tableOfContents: [MediaTOCEntry]
    /// `nav` (EPUB 3 navigation document) or `ncx` (EPUB 2 toc.ncx); nil when there is none.
    public var tableOfContentsSource: String?
    /// The book is encrypted with DRM (not only obfuscated fonts).
    public var isProtected: Bool
    /// A list was cut at its cap.
    public var truncated: Bool
}

/// A comic book archive (N-2): CBZ, CBR, CB7 or CBT. roadmap: S-23
public struct MediaComicSummary: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// The container the bytes are ("ZIP", "RAR", "7-Zip", "tar"), whatever the extension says.
    public var container: String
    public var pageCount: Int
    /// Page paths in reading order (natural sort), at most 2,000.
    public var pages: [String]
    /// The first page's bytes, when they could be read and are at most 4 MB.
    public var cover: MediaPicture?
    /// Why the cover could not be read.
    public var coverNote: String?
    public var series: String?
    public var number: String?
    public var title: String?
    public var writer: String?
    public var artist: String?
    public var publisher: String?
    public var year: String?
    public var summary: String?
    public var truncated: Bool
}

enum MediaBookReader {
    static let maxTOCEntries = 500
    static let maxTOCDepth = 4
    static let maxCreators = 50
    static let maxIdentifiers = 20
    static let maxPages = 2_000

    // MARK: EPUB

    static func readEPUB(_ data: Data, fileName: String) -> MediaBookSummary? {
        guard let archive = MediaArchive.open(data, fileName: fileName) else { return nil }
        var s = MediaBookSummary(headline: MediaPath.base(fileName), facts: [], warnings: [], epubVersion: nil,
                                 title: nil, creators: [], language: nil, publisher: nil, date: nil, identifiers: [],
                                 description: nil, spineLength: 0, manifestItemCount: 0, cover: nil, coverNote: nil,
                                 tableOfContents: [], tableOfContentsSource: nil, isProtected: false, truncated: false)

        guard let containerData = archive.read(path: "META-INF/container.xml", limit: MediaLimits.maxXMLPartBytes),
              let container = MediaXMLElement.parse(containerData) else {
            s.warnings.append(MediaWarning(.danger, String(localized: "This is not a readable EPUB: META-INF/container.xml is missing or damaged.", bundle: .module, comment: "Book or comic card warning.")))
            s.facts = [MediaFact(String(localized: "Files", bundle: .module, comment: "Book or comic card fact label."), "\(archive.fileIndices.count)")]
            return s
        }
        let rootfiles = container.descendants("rootfile")
        let rootfile = rootfiles.first { $0.attribute("media-type") == "application/oebps-package+xml" } ?? rootfiles.first
        guard let opfPath = rootfile?.attribute("full-path").map({ ArchivePath.normalized($0) }),
              let opfData = archive.read(path: opfPath, limit: MediaLimits.maxXMLPartBytes),
              let opf = MediaXMLElement.parse(opfData) else {
            s.warnings.append(MediaWarning(.danger, String(localized: "This is not a readable EPUB: its package document (OPF) is missing or damaged.", bundle: .module, comment: "Book or comic card warning.")))
            s.facts = [MediaFact(String(localized: "Files", bundle: .module, comment: "Book or comic card fact label."), "\(archive.fileIndices.count)")]
            return s
        }

        s.epubVersion = opf.attribute("version")
        let metadata = opf.child("metadata") ?? opf.descendants("metadata").first
        var roles: [String: String] = [:]                                    // EPUB 3 `refines` roles by id
        for meta in metadata?.children("meta") ?? [] where meta.attribute("property") == "role" {
            if let ref = meta.attribute("refines"), ref.hasPrefix("#") { roles[String(ref.dropFirst())] = meta.trimmedText }
        }
        var coverID: String?
        for el in metadata?.children ?? [] {
            switch el.localName {
            case "title" where s.title == nil: s.title = MediaText.clean(el.allText)
            case "creator":
                if s.creators.count >= maxCreators { s.truncated = true; continue }
                if let name = MediaText.clean(el.allText, max: 300) {
                    s.creators.append(MediaBookCreator(name: name, role: el.attribute("role") ?? el.attribute("id").flatMap { roles[$0] }))
                }
            case "language" where s.language == nil: s.language = MediaText.clean(el.allText, max: 50)
            case "publisher" where s.publisher == nil: s.publisher = MediaText.clean(el.allText, max: 300)
            case "date" where s.date == nil: s.date = MediaText.clean(el.allText, max: 50)
            case "identifier":
                if s.identifiers.count >= maxIdentifiers { s.truncated = true; continue }
                if let id = MediaText.clean(el.allText, max: 300) { s.identifiers.append(id) }
            case "description" where s.description == nil:
                s.description = MediaText.clean(MediaText.stripTags(el.allText), max: MediaLimits.maxDescriptionCharacters)
            case "meta" where el.attribute("name") == "cover":
                coverID = el.attribute("content")
            default: break
            }
        }

        // Manifest and spine.
        struct Item { var id: String; var href: String; var mediaType: String; var properties: [String] }
        var items: [Item] = []
        for el in (opf.child("manifest") ?? opf.descendants("manifest").first)?.children("item") ?? [] {
            guard let href = el.attribute("href") else { continue }
            items.append(Item(id: el.attribute("id") ?? "", href: MediaPath.resolve(href, relativeTo: opfPath),
                              mediaType: el.attribute("media-type") ?? "",
                              properties: (el.attribute("properties") ?? "").split(separator: " ").map(String.init)))
        }
        s.manifestItemCount = items.count
        let spine = opf.child("spine") ?? opf.descendants("spine").first
        s.spineLength = spine?.children("itemref").count ?? 0

        // Cover: EPUB 3 `cover-image`, then EPUB 2 `<meta name="cover">`, then an image named like a cover.
        let coverItem = items.first { $0.properties.contains("cover-image") }
            ?? coverID.flatMap { id in items.first { $0.id == id } ?? items.first { $0.href.hasSuffix(id) } }
            ?? items.first { $0.mediaType.hasPrefix("image/") && ($0.id.lowercased().contains("cover") || MediaPath.base($0.href).lowercased().contains("cover")) }
        if let coverItem {
            if let index = archive.index(of: coverItem.href) {
                if let bytes = archive.read(index, limit: MediaLimits.maxCoverBytes) {
                    let mime = coverItem.mediaType.hasPrefix("image/") ? coverItem.mediaType
                        : (MediaPath.sniffImageMime(bytes) ?? MediaPath.imageMime(coverItem.href) ?? "application/octet-stream")
                    s.cover = MediaPicture(data: bytes, mimeType: mime)
                } else {
                    let why = archive.readFailure(index, limit: MediaLimits.maxCoverBytes) ?? MediaText.unknownReason
                    s.coverNote = String(localized: "The cover could not be read: \(why).", bundle: .module, comment: "Book card note. The argument is a technical reason.")
                }
            } else {
                s.coverNote = String(localized: "The cover the book names (\(coverItem.href)) is not in the file.", bundle: .module, comment: "Book card note. The argument is a path inside the book.")
            }
        }

        // Table of contents: the EPUB 3 navigation document, then toc.ncx.
        if let nav = items.first(where: { $0.properties.contains("nav") }),
           let navData = archive.read(path: nav.href, limit: MediaLimits.maxXMLPartBytes),
           let tree = MediaXMLElement.parse(htmlEntitiesToNumeric(navData)) {
            var truncated = false
            s.tableOfContents = navTOC(tree, base: nav.href, truncated: &truncated)
            s.truncated = s.truncated || truncated
            if !s.tableOfContents.isEmpty { s.tableOfContentsSource = "nav" }
        }
        if s.tableOfContents.isEmpty {
            let ncxID = spine?.attribute("toc")
            let ncx = ncxID.flatMap { id in items.first { $0.id == id } }
                ?? items.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx, let ncxData = archive.read(path: ncx.href, limit: MediaLimits.maxXMLPartBytes),
               let tree = MediaXMLElement.parse(htmlEntitiesToNumeric(ncxData)) {
                var truncated = false
                s.tableOfContents = ncxTOC(tree, base: ncx.href, truncated: &truncated)
                s.truncated = s.truncated || truncated
                if !s.tableOfContents.isEmpty { s.tableOfContentsSource = "ncx" }
            }
        }

        // Protection and scripts.
        if let enc = archive.read(path: "META-INF/encryption.xml", limit: MediaLimits.maxXMLPartBytes) {
            let algorithms = MediaXMLElement.parse(enc)?.descendants("EncryptionMethod").compactMap { $0.attribute("Algorithm") } ?? []
            let fontOnly = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
            if algorithms.isEmpty || algorithms.contains(where: { !fontOnly.contains($0) }) {
                s.isProtected = true
            } else {
                s.facts.append(MediaFact(String(localized: "Fonts", bundle: .module, comment: "Book card fact label."), String(localized: "Obfuscated (not DRM)", bundle: .module, comment: "Book card fact: the fonts are scrambled, not protected.")))
            }
        }
        if archive.contains("META-INF/rights.xml") { s.isProtected = true }
        if s.isProtected {
            s.warnings.append(MediaWarning(.caution, String(localized: "This book is protected by DRM: its pages open only in the reader app of the store that sold it.", bundle: .module, comment: "Book or comic card warning.")))
        }
        if items.contains(where: { $0.properties.contains("scripted") }) {
            s.warnings.append(MediaWarning(.caution, String(localized: "This book contains scripts (EPUB 3 scripting). Vitrine never runs them.", bundle: .module, comment: "Book or comic card warning.")))
        }
        if s.spineLength == 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "The book's reading order (spine) is empty.", bundle: .module, comment: "Book or comic card warning.")))
        }

        s.headline = s.title ?? MediaPath.base(fileName)
        var facts: [MediaFact] = []
        if !s.creators.isEmpty { facts.append(MediaFact(s.creators.count == 1 ? String(localized: "Author", bundle: .module, comment: "Book card fact label, one author.") : String(localized: "Authors", bundle: .module, comment: "Book card fact label, several authors."), s.creators.prefix(5).map(\.name).joined(separator: ", "))) }
        if let v = s.publisher { facts.append(MediaFact(String(localized: "Publisher", bundle: .module, comment: "Book or comic card fact label."), v)) }
        if let v = s.date { facts.append(MediaFact(String(localized: "Published", bundle: .module, comment: "Book or comic card fact label."), v)) }
        if let v = s.language { facts.append(MediaFact(String(localized: "Language", bundle: .module, comment: "Book or comic card fact label."), v)) }
        if let v = s.epubVersion { facts.append(MediaFact(String(localized: "EPUB", bundle: .module, comment: "Book or comic card fact label."), v)) }
        facts.append(MediaFact(String(localized: "Chapters (spine)", bundle: .module, comment: "Book or comic card fact label."), "\(s.spineLength)"))
        if !s.tableOfContents.isEmpty { facts.append(MediaFact(String(localized: "Contents entries", bundle: .module, comment: "Book or comic card fact label."), "\(s.tableOfContents.count)")) }
        if let id = s.identifiers.first { facts.append(MediaFact(String(localized: "Identifier", bundle: .module, comment: "Book or comic card fact label."), id)) }
        s.facts = facts + s.facts
        return s
    }

    /// The XHTML navigation document's `toc` list.
    static func navTOC(_ root: MediaXMLElement, base: String, truncated: inout Bool) -> [MediaTOCEntry] {
        let navs = root.descendants("nav")
        guard let nav = navs.first(where: { ($0.attribute("epub:type") ?? $0.attribute("type") ?? "").split(separator: " ").contains("toc") })
                ?? navs.first,
              let list = nav.descendants("ol", limit: 1).first else { return [] }
        var out: [MediaTOCEntry] = []
        func walk(_ ol: MediaXMLElement, depth: Int) {
            for li in ol.children("li") {
                if out.count >= maxTOCEntries { truncated = true; return }
                let label = li.child("a") ?? li.child("span")
                if let label, let title = MediaText.clean(label.allText.split(whereSeparator: \.isWhitespace).joined(separator: " "), max: 300) {
                    out.append(MediaTOCEntry(title: title, depth: depth, target: label.attribute("href").map { MediaPath.resolve($0, relativeTo: base) }))
                }
                if let sub = li.child("ol") {
                    if depth < maxTOCDepth { walk(sub, depth: depth + 1) } else if !sub.children("li").isEmpty { truncated = true }
                }
            }
        }
        walk(list, depth: 1)
        return out
    }

    /// toc.ncx's `navMap`.
    static func ncxTOC(_ root: MediaXMLElement, base: String, truncated: inout Bool) -> [MediaTOCEntry] {
        guard let map = root.descendants("navMap", limit: 1).first else { return [] }
        var out: [MediaTOCEntry] = []
        func walk(_ parent: MediaXMLElement, depth: Int) {
            for point in parent.children("navPoint") {
                if out.count >= maxTOCEntries { truncated = true; return }
                let label = point.child("navLabel")?.child("text")?.allText ?? point.child("navLabel")?.allText
                if let title = MediaText.clean(label?.split(whereSeparator: \.isWhitespace).joined(separator: " "), max: 300) {
                    out.append(MediaTOCEntry(title: title, depth: depth,
                                             target: point.child("content")?.attribute("src").map { MediaPath.resolve($0, relativeTo: base) }))
                }
                if !point.children("navPoint").isEmpty {
                    if depth < maxTOCDepth { walk(point, depth: depth + 1) } else { truncated = true }
                }
            }
        }
        walk(map, depth: 1)
        return out
    }

    /// XHTML written by hand often uses HTML's named entities, which XML does not define; the common ones become
    /// numeric references so the parser accepts the document.
    static func htmlEntitiesToNumeric(_ data: Data) -> Data {
        guard data.firstIndex(of: UInt8(ascii: "&")) != nil else { return data }
        var s = String(decoding: data, as: UTF8.self)
        let table = ["&nbsp;": "&#160;", "&mdash;": "&#8212;", "&ndash;": "&#8211;", "&hellip;": "&#8230;",
                     "&rsquo;": "&#8217;", "&lsquo;": "&#8216;", "&rdquo;": "&#8221;", "&ldquo;": "&#8220;",
                     "&copy;": "&#169;", "&eacute;": "&#233;", "&egrave;": "&#232;", "&middot;": "&#183;"]
        for (k, v) in table { s = s.replacingOccurrences(of: k, with: v) }
        return Data(s.utf8)
    }

    // MARK: Comics

    static func readComic(_ data: Data, fileName: String) -> MediaComicSummary? {
        guard let archive = MediaArchive.open(data, fileName: fileName) else { return nil }
        let container: String
        switch archive.listing.format {
        case .zip: container = "ZIP"
        case .tar, .tarGzip: container = "tar"
        default: container = archive.listing.format.name
        }
        var s = MediaComicSummary(headline: MediaPath.base(fileName), facts: [], warnings: [], container: container,
                                  pageCount: 0, pages: [], cover: nil, coverNote: nil, series: nil, number: nil,
                                  title: nil, writer: nil, artist: nil, publisher: nil, year: nil, summary: nil,
                                  truncated: !archive.listing.coverage.isComplete)
        let files = archive.fileIndices
        let pageIndices = files.filter { i in
            let path = archive.path(i)
            let comps = ArchivePath.components(path)
            guard !comps.contains("__MACOSX"), !(comps.last ?? "").hasPrefix(".") else { return false }
            return MediaPath.imageExtensions.contains(MediaPath.ext(path))
        }.sorted { MediaSort.natural(archive.path($0), archive.path($1)) }
        s.pageCount = pageIndices.count
        s.pages = pageIndices.prefix(maxPages).map { archive.path($0) }
        if pageIndices.count > maxPages { s.truncated = true }

        if let first = pageIndices.first {
            if let bytes = archive.read(first, limit: MediaLimits.maxCoverBytes) {
                s.cover = MediaPicture(data: bytes, mimeType: MediaPath.sniffImageMime(bytes) ?? MediaPath.imageMime(archive.path(first)) ?? "application/octet-stream")
            } else {
                let why = archive.readFailure(first, limit: MediaLimits.maxCoverBytes) ?? MediaText.unknownReason
                s.coverNote = String(localized: "The cover cannot be read: \(why).", bundle: .module, comment: "Comic card note. The argument is a technical reason.")
            }
        } else {
            s.warnings.append(MediaWarning(.danger, String(localized: "This comic archive holds no pages (no images were found).", bundle: .module, comment: "Book or comic card warning.")))
        }

        if let infoIndex = files.first(where: { MediaPath.base(archive.path($0)).lowercased() == "comicinfo.xml" }),
           let infoData = archive.read(infoIndex, limit: MediaLimits.maxXMLPartBytes),
           let info = MediaXMLElement.parse(infoData) {
            func value(_ name: String) -> String? { MediaText.clean(info.child(name)?.allText, max: 500) }
            s.series = value("Series")
            s.number = value("Number")
            s.title = value("Title")
            s.writer = value("Writer")
            s.artist = value("Penciller") ?? value("Artist")
            s.publisher = value("Publisher")
            s.year = value("Year")
            s.summary = MediaText.clean(info.child("Summary")?.allText, max: MediaLimits.maxDescriptionCharacters)
        }
        if files.contains(where: { archive.listing.entries[$0].isEncrypted }) {
            s.warnings.append(MediaWarning(.caution, String(localized: "Some pages are encrypted; they cannot be shown without the password.", bundle: .module, comment: "Book or comic card warning.")))
        }

        if let series = s.series {
            s.headline = s.number.map { "\(series) #\($0)" } ?? series
            if let title = s.title { s.headline += " — \(title)" }
        } else if let title = s.title {
            s.headline = title
        }
        var facts = [MediaFact(String(localized: "Pages", bundle: .module, comment: "Book or comic card fact label."), "\(s.pageCount)"), MediaFact(String(localized: "Container", bundle: .module, comment: "Book or comic card fact label."), container)]
        if let v = s.writer { facts.append(MediaFact(String(localized: "Writer", bundle: .module, comment: "Book or comic card fact label."), v)) }
        if let v = s.artist { facts.append(MediaFact(String(localized: "Artist", bundle: .module, comment: "Book or comic card fact label."), v)) }
        if let v = s.publisher { facts.append(MediaFact(String(localized: "Publisher", bundle: .module, comment: "Book or comic card fact label."), v)) }
        if let v = s.year { facts.append(MediaFact(String(localized: "Year", bundle: .module, comment: "Book or comic card fact label."), v)) }
        s.facts = facts
        return s
    }
}
