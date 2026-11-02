import Foundation

/// A stable text form of `FileKind`, for the document model's JSON (`vitrine describe`, MCP) and for logs:
/// `markdown.commonMark`, `code.python`, `csv.tab`, `archive.zip`, `sqlite`. Ids are part of the public CLI and MCP
/// output, so a case is renamed only with a migration note; decoding an unknown id fails rather than guessing.
extension FileKind: Codable {
    public var identifier: String {
        switch self {
        case .markdown(let d): return "markdown.\(d.identifier)"
        case .code(let language): return "code.\(language)"
        case .plainText: return "plainText"
        case .csv(let delimiter): return "csv.\(Self.delimiterNames[delimiter] ?? "u\(delimiter.unicodeScalars.first!.value)")"
        case .sqlite: return "sqlite"
        case .dataset(let f): return "dataset.\(f.identifier)"
        case .svg: return "svg"
        case .diff: return "diff"
        case .archive(let f): return "archive.\(f.identifier)"
        case .appBundle: return "appBundle"
        case .installerPackage: return "installerPackage"
        case .diskImage: return "diskImage"
        case .torrent: return "torrent"
        case .provisioningProfile: return "provisioningProfile"
        case .configurationProfile: return "configurationProfile"
        case .keyMaterial: return "keyMaterial"
        case .lockfile: return "lockfile"
        case .reader(let id): return "reader.\(id)"
        case .image: return "image"
        case .font: return "font"
        case .folder: return "folder"
        case .binary: return "binary"
        }
    }

    public init?(identifier: String) {
        let (head, tail) = identifier.firstIndex(of: ".").map {
            (String(identifier[..<$0]), String(identifier[identifier.index(after: $0)...]))
        } ?? (identifier, "")
        switch (head, tail.isEmpty) {
        case ("markdown", false): guard let d = MarkdownDialect(identifier: tail) else { return nil }; self = .markdown(d)
        case ("code", false): self = .code(language: tail)
        case ("csv", false): guard let c = Self.delimiter(named: tail) else { return nil }; self = .csv(delimiter: c)
        case ("archive", false): guard let f = ArchiveFormat(identifier: tail) else { return nil }; self = .archive(f)
        case ("dataset", false): guard let f = DatasetFormat(identifier: tail) else { return nil }; self = .dataset(f)
        case ("plainText", true): self = .plainText
        case ("sqlite", true): self = .sqlite
        case ("svg", true): self = .svg
        case ("diff", true): self = .diff
        case ("appBundle", true): self = .appBundle
        case ("installerPackage", true): self = .installerPackage
        case ("diskImage", true): self = .diskImage
        case ("torrent", true): self = .torrent
        case ("provisioningProfile", true): self = .provisioningProfile
        case ("configurationProfile", true): self = .configurationProfile
        case ("keyMaterial", true): self = .keyMaterial
        case ("lockfile", true): self = .lockfile
        case ("reader", false): self = .reader(tail)
        case ("image", true): self = .image
        case ("font", true): self = .font
        case ("folder", true): self = .folder
        case ("binary", true): self = .binary
        default: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        guard let kind = FileKind(identifier: id) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown file kind \(id)"))
        }
        self = kind
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(identifier)
    }

    private static let delimiterNames: [Character: String] = [",": "comma", "\t": "tab", ";": "semicolon", "|": "pipe"]

    private static func delimiter(named name: String) -> Character? {
        if let c = delimiterNames.first(where: { $0.value == name })?.key { return c }
        guard name.hasPrefix("u"), let v = UInt32(name.dropFirst()), let s = Unicode.Scalar(v) else { return nil }
        return Character(s)
    }
}

extension FileKind.MarkdownDialect {
    private static let names: [(Self, String)] = [(.commonMark, "commonMark"), (.mdx, "mdx"), (.mdc, "mdc"), (.quarto, "quarto"),
        (.rMarkdown, "rMarkdown"), (.reStructuredText, "reStructuredText"), (.asciiDoc, "asciiDoc"), (.org, "org")]
    public var identifier: String { Self.names.first { $0.0 == self }!.1 }
    public init?(identifier: String) {
        guard let d = Self.names.first(where: { $0.1 == identifier })?.0 else { return nil }
        self = d
    }
}

extension FileKind.DatasetFormat {
    private static let names: [(Self, String)] = [(.parquet, "parquet"), (.arrow, "arrow"), (.arrowStream, "arrowStream"),
        (.feather, "feather"), (.xlsx, "xlsx")]
    public var identifier: String { Self.names.first { $0.0 == self }!.1 }
    public init?(identifier: String) {
        guard let f = Self.names.first(where: { $0.1 == identifier })?.0 else { return nil }
        self = f
    }
}

extension FileKind.ArchiveFormat {
    private static let names: [(Self, String)] = [(.zip, "zip"), (.tar, "tar"), (.gzip, "gzip"), (.bzip2, "bzip2"),
        (.ipa, "ipa"), (.apk, "apk"), (.jar, "jar"), (.rar, "rar"), (.sevenZip, "7z"), (.xz, "xz"), (.zstd, "zstd"),
        (.lz4, "lz4"), (.lzma, "lzma"), (.lzip, "lzip"), (.compress, "compress"), (.iso, "iso"), (.cpio, "cpio"),
        (.rpm, "rpm"), (.deb, "deb"), (.xar, "xar"), (.cab, "cab"), (.lha, "lha")]
    public var identifier: String { Self.names.first { $0.0 == self }!.1 }
    public init?(identifier: String) {
        guard let f = Self.names.first(where: { $0.1 == identifier })?.0 else { return nil }
        self = f
    }
}

extension FileKind {
    /// The kind as people name it, for the capsule's pill and the CLI: "Markdown", "Swift", "CSV".
    public var displayName: String {
        switch self {
        case .markdown(let d):
            switch d {
            case .commonMark: return "Markdown"
            case .mdx: return "MDX"
            case .mdc: return "MDC"
            case .quarto: return "Quarto"
            case .rMarkdown: return "R Markdown"
            case .reStructuredText: return "reStructuredText"
            case .asciiDoc: return "AsciiDoc"
            case .org: return "Org"
            }
        case .code(let language): return LanguageMap.displayName(for: language)
        case .plainText: return String(localized: "Text", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: plain text file.")
        case .csv(let delimiter): return delimiter == "\t" ? "TSV" : "CSV"
        case .sqlite: return "SQLite"
        case .dataset(let f):
            switch f {
            case .parquet: return "Parquet"
            case .arrow: return "Arrow"
            case .arrowStream: return String(localized: "Arrow stream", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: Apache Arrow IPC stream file.")
            case .feather: return "Feather"
            case .xlsx: return String(localized: "Excel workbook", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: Microsoft Excel .xlsx file.")
            }
        case .svg: return "SVG"
        case .diff: return String(localized: "Diff", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a diff or patch file.")
        case .archive(let f):
            switch f {
            case .zip: return String(localized: "Zip archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .tar: return String(localized: "Tar archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .gzip: return "Gzip"
            case .bzip2: return "Bzip2"
            case .ipa: return String(localized: "iOS app", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: an .ipa file.")
            case .apk: return String(localized: "Android app", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: an .apk file.")
            case .jar: return String(localized: "Java archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a .jar file.")
            case .rar: return String(localized: "RAR archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .sevenZip: return String(localized: "7-Zip archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .xz: return String(localized: "xz archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .zstd: return String(localized: "Zstandard archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .lz4: return String(localized: "LZ4 archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .lzma: return String(localized: "LZMA archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .lzip: return String(localized: "lzip archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .compress: return String(localized: "Compressed archive (.Z)", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: Unix compress format.")
            case .iso: return String(localized: "Disc image (ISO)", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: an ISO 9660 disc image.")
            case .cpio: return String(localized: "cpio archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .rpm: return String(localized: "RPM package", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .deb: return String(localized: "Debian package", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a .deb file.")
            case .xar: return String(localized: "XAR archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            case .cab: return String(localized: "Cabinet archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: Microsoft .cab file.")
            case .lha: return String(localized: "LHA archive", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
            }
        case .appBundle: return String(localized: "App", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a macOS .app bundle.")
        case .installerPackage: return String(localized: "Installer", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a macOS .pkg installer package.")
        case .diskImage: return String(localized: "Disk image", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a macOS .dmg disk image.")
        case .torrent: return String(localized: "Torrent", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a .torrent file.")
        case .provisioningProfile: return String(localized: "Provisioning profile", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: an Apple provisioning profile.")
        case .configurationProfile: return String(localized: "Configuration profile", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: an Apple configuration profile (.mobileconfig).")
        case .reader: return String(localized: "Structured file", bundle: .module, comment: "Kind name shown in the pill and the CLI for a file a format reader summarises (a Compose file, a workflow, a Terraform state …); the card names the exact format.")
        case .lockfile: return String(localized: "Lockfile", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a dependency lockfile such as package-lock.json or Cargo.lock.")
        case .keyMaterial: return String(localized: "Certificate or key", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: a certificate, a key or a list of SSH keys.")
        case .image: return String(localized: "Image", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
        case .font: return String(localized: "Font", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
        case .folder: return String(localized: "Folder", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI.")
        case .binary: return String(localized: "Binary", bundle: .module, comment: "Kind name shown in the preview's pill and the CLI: an unrecognised binary file.")
        }
    }
}
