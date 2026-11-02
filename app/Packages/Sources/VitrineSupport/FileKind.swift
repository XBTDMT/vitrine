import Foundation
import UniformTypeIdentifiers

/// What Vitrine decided a file is, after looking at its type identifier, its extension and (when needed) its first
/// bytes. One value drives which renderer runs. Sniffing is deliberately separate from UTI registration: Finder only
/// tells us which extension it chose, and the Code extension in particular gets handed many things that are not code.
public enum FileKind: Sendable, Equatable {
    case markdown(MarkdownDialect)
    case code(language: String)
    case plainText
    case csv(delimiter: Character)
    case sqlite
    /// A column file read by VitrineData's own readers (B-4, G-20): Parquet, Arrow IPC / Feather, an xlsx workbook.
    case dataset(DatasetFormat)
    case svg
    case diff
    case archive(ArchiveFormat)
    case appBundle
    case installerPackage
    case diskImage
    case torrent
    case provisioningProfile
    /// A configuration profile (`.mobileconfig`): payloads that change a Mac's settings when installed. roadmap: S-8
    case configurationProfile
    /// Certificates and keys (T-10): PEM bundles, DER certificates, signing requests, SSH public keys,
    /// `authorized_keys` and `known_hosts`, and private keys, which are described and never shown. roadmap: S-22
    case keyMaterial
    /// A dependency lockfile (A-12): package-lock.json, yarn.lock, Cargo.lock, go.sum … read by VitrineEngineering's
    /// LockfileReader for its card; its text stays one view away. roadmap: S-22
    case lockfile
    /// A file one of the format readers summarises on a card (S-21, S-22, S-23): `family.format`, such as
    /// `infra.compose`, `infra.githubWorkflow` or `infra.terraformState`. roadmap: S-22
    case reader(String)
    /// A picture ImageIO reads: photos, screenshots, animations (GIF, WebP, APNG, HEIC sequences), RAW. roadmap: S-23
    case image
    /// A font file CoreText reads: TrueType, OpenType, collections, WOFF and WOFF 2. roadmap: S-23
    case font
    case folder
    case binary

    /// What the extension or the first bytes name; the reader decides from the bytes. roadmap: S-21
    public enum DatasetFormat: Sendable, Equatable { case parquet, arrow, arrowStream, feather, xlsx }

    public enum MarkdownDialect: Sendable, Equatable { case commonMark, mdx, mdc, quarto, rMarkdown, reStructuredText, asciiDoc, org }
    /// The archive the extension or the bytes name. The reader decides from the bytes alone (VitrineArchive); this is
    /// what the pill calls it before it opens. `jar` is a zip; `iso` is an ISO 9660 tree (a DMG stays a disk image).
    public enum ArchiveFormat: Sendable, Equatable {
        case zip, tar, gzip, bzip2, ipa, apk
        case jar, rar, sevenZip, xz, zstd, lz4, lzma, lzip, compress, iso, cpio, rpm, deb, xar, cab, lha
    }
}

public enum FileSniffer {
    /// Bytes that mark a file as binary when found in its first 8 KB (NUL) or that identify a known container.
    static let sampleLength = 8 * 1024

    /// What the file is. `readers: false` asks what it is as text, ignoring the format readers (S-21 … S-23) that
    /// own it by name or content: a HAR is JSON, a Compose file YAML, a JSON Lines file JSONL. Thumbnails draw that
    /// text and check it parses; previews use the reader.
    public static func kind(of url: URL, contentType: UTType? = nil, readers: Bool = true) -> FileKind {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)
        let ext = url.pathExtension.lowercased()

        if isDirectory.boolValue {
            if ext == "app" || type?.conforms(to: .applicationBundle) == true { return .appBundle }
            if ext == "textbundle" { return .markdown(.commonMark) }
            // Xcode's asset catalogs and archives (E-5) are folders the Apple development reader summarises.
            if ext == "xcassets" || ext == "xcarchive" { return .reader("apple.folder") }
            if ext == "mlpackage" { return .reader("ai.folder") }
            return .folder
        }
        // SSH's own files carry no extension (T-10).
        if Self.sshFileNames.contains(url.lastPathComponent.lowercased()) { return .keyMaterial }
        // Files a format reader owns by name, path or a strong content marker (S-22), before languages claim them.
        if readers, let reader = Self.readerKind(url) { return .reader(reader) }
        // Lockfiles by name (A-12), before their JSON, TOML or YAML language claims them.
        if Self.lockfileNames.contains(url.lastPathComponent.lowercased()) { return .lockfile }
        if let named = LanguageMap.language(forFileName: url.lastPathComponent) { return .code(language: named) }
        switch ext {
        case "pem", "crt", "cer", "der", "csr": return .keyMaterial
        // `.pub` is also Publisher's and `.key` Keynote's: only their text says they are keys.
        case "pub" where (try? readSample(url)).map(Self.looksLikeSSHPublicKey) == true: return .keyMaterial
        case "key" where (try? readSample(url))?.starts(with: Array("-----BEGIN ".utf8)) == true: return .keyMaterial
        // A marimo notebook is a Python file marimo wrote (A-8): its first 8 KB import marimo and make the app. It is
        // drawn as a notebook (NotebookRenderer, S-21); every other Python file stays Python.
        case "py" where (try? readSample(url)).map(Self.looksLikeMarimo) == true: return .code(language: "marimo")
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext": return .markdown(.commonMark)
        case "mdc": return .markdown(.mdc)
        // JSON Lines: agent sessions open as their conversation (S-11); any other JSON Lines file as the tree.
        case "jsonl", "ndjson": return .code(language: "jsonl")
        case "mdx": return .markdown(.mdx)
        case "qmd": return .markdown(.quarto)
        case "rmd": return .markdown(.rMarkdown)
        case "rst": return .markdown(.reStructuredText)
        case "adoc", "asciidoc": return .markdown(.asciiDoc)
        case "org": return .markdown(.org)
        case "csv": return .csv(delimiter: ",")
        case "tsv", "tab": return .csv(delimiter: "\t")
        case "sqlite", "sqlite3", "db", "db3": return .sqlite
        case "parquet", "parq": return .dataset(.parquet)
        case "arrow", "ipc": return .dataset(.arrow)
        case "arrows": return .dataset(.arrowStream)
        case "feather": return .dataset(.feather)
        case "xlsx": return .dataset(.xlsx)
        case "svg": return .svg
        case "patch", "diff": return .diff
        case "zip": return .archive(.zip)
        case "jar", "war", "ear": return .archive(.jar)
        case "tar": return .archive(.tar)
        case "gz", "tgz": return .archive(.gzip)
        case "bz2", "tbz", "tbz2": return .archive(.bzip2)
        case "xz", "txz": return .archive(.xz)
        case "zst", "zstd", "tzst": return .archive(.zstd)
        case "lz4": return .archive(.lz4)
        case "lzma", "tlz": return .archive(.lzma)
        case "lz": return .archive(.lzip)
        case "z", "taz": return .archive(.compress)
        case "rar": return .archive(.rar)
        case "7z": return .archive(.sevenZip)
        case "iso": return .archive(.iso)
        case "cpio": return .archive(.cpio)
        case "rpm": return .archive(.rpm)
        case "deb", "udeb": return .archive(.deb)
        case "xar": return .archive(.xar)
        case "cab": return .archive(.cab)
        case "lha", "lzh": return .archive(.lha)
        case "ipa": return .archive(.ipa)
        case "apk": return .archive(.apk)
        case "pkg", "mpkg": return .installerPackage
        case "dmg": return .diskImage
        case "torrent": return .torrent
        case "mobileprovision", "provisionprofile": return .provisioningProfile
        case "mobileconfig": return .configurationProfile
        // Fonts and pictures without a system type (S-23): WOFF and WOFF 2 are web fonts macOS never declared, and
        // `.apng` is an animated PNG under its own extension. The rest are found by their system type below.
        case "woff", "woff2": return .font
        case "apng": return .image
        default: break
        }
        if let type, type.conforms(to: .font) { return .font }
        if let type, type.conforms(to: .image), type != .pdf { return .image }
        if let type, type.conforms(to: .sourceCode) || type.conforms(to: .script) {
            return .code(language: LanguageMap.language(for: ext, type: type))
        }
        // Unknown extension: look at the bytes.
        guard let sample = try? readSample(url) else { return .binary }
        // A binary property list has NUL bytes but is structured data, read by the structured renderer (S-5).
        if sample.starts(with: Array("bplist00".utf8)) { return .code(language: "plist") }
        if let format = archiveFormat(sniffing: sample, isoMarker: { try? readISOMarker(url) }) { return .archive(format) }
        if sample.starts(with: Array("PAR1".utf8)) { return .dataset(.parquet) }
        if sample.starts(with: Array("ARROW1".utf8)) { return .dataset(.arrow) }
        if sample.contains(0) { return hasSQLiteHeader(sample) ? .sqlite : .binary }
        if let shebang = shebangLanguage(sample) { return .code(language: shebang) }
        return LanguageMap.language(for: ext, type: type).map { .code(language: $0) } ?? .plainText
    }

    /// The reader that owns a file (S-22): infrastructure files by name or path (InfraReader.kind's rules, which
    /// VitrineEngineeringTests holds equal), Kubernetes manifests and workflows by a strong YAML marker.
    public static func readerKind(_ url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if name.hasSuffix(".tfstate") || name.hasSuffix(".tfstate.backup") { return "infra.terraformState" }
        if ext == "har" { return "infra.har" }
        if ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"].contains(name) { return "infra.compose" }
        if ext == "yml" || ext == "yaml" {
            if name.hasPrefix("docker-compose.") || name.hasPrefix("compose.") { return "infra.compose" }
            if url.path.contains("/.github/workflows/") { return "infra.githubWorkflow" }
            // A Kubernetes manifest says so in its first lines.
            if let sample = try? readSample(url), let head = String(data: sample, encoding: .utf8) {
                let lines = head.split(whereSeparator: \.isNewline)
                if lines.contains(where: { $0.hasPrefix("apiVersion:") }) && lines.contains(where: { $0.hasPrefix("kind:") }) { return "infra.kubernetes" }
            }
        }
        // Model files, pickles and MCP configs (S-21): the AI formats reader.
        if Self.aiModelExtensions.contains(ext) || name == "tokenizer.json" || ["mcp.json", ".mcp.json", "claude_desktop_config.json"].contains(name) {
            return "ai.file"
        }
        // Arrays and eval logs by extension, chat exports by name, JSON Lines unless it is an agent session (S-21).
        if ["npy", "npz", "h5", "hdf5", "he5", "eval"].contains(ext) || name == "conversations.json" { return "aidata.file" }
        if ext == "jsonl" || ext == "ndjson" {
            let head = (try? readSample(url)).flatMap { String(data: $0.prefix(4096), encoding: .utf8) } ?? ""
            if !head.contains("\"sessionId\"") && !head.contains("\"session_meta\"") { return "aidata.file" }
        }
        // Subtitles, calendar invites, contacts, email and LaTeX/BibTeX (S-23).
        if Self.everydayExtensions.contains(ext) { return "everyday.file" }
        // Books, comics, maps, 3D models and audio (S-23): the media reader.
        if Self.mediaExtensions.contains(ext) { return "media.file" }
        // Apple development files (E-5): String Catalogs, crash reports, entitlements and an app's Info.plist.
        if ["xcstrings", "ips", "crash", "entitlements"].contains(ext) || name == "info.plist" { return "apple.file" }
        // API and schema files (E-3): their own extensions; JSON and YAML only when they say they are a spec.
        if ["graphql", "gql", "graphqls", "proto", "avsc", "avpr", "avdl"].contains(ext) { return "api.spec" }
        if ["json", "yaml", "yml"].contains(ext) {
            if name.hasSuffix(".schema.json") || name.hasSuffix(".schema.yaml") || name.hasSuffix(".schema.yml") { return "api.spec" }
            if let sample = try? readSample(url), let head = String(data: sample.prefix(4096), encoding: .utf8) {
                let lines = head.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                let spec = lines.contains { $0.hasPrefix("openapi:") || $0.hasPrefix("swagger:") || $0.hasPrefix("\"openapi\"") || $0.hasPrefix("\"swagger\"") }
                if spec || head.contains("json-schema.org") { return "api.spec" }
            }
        }
        if name == "dockerfile" || name == "containerfile" || ext == "dockerfile" || ext == "containerfile" { return "infra.dockerfile" }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") {
            let notDockerfile = ["md", "txt", "json", "yml", "yaml", "toml", "sh", "swift", "rtf", "html", "pdf"]
            if !notDockerfile.contains(ext) { return "infra.dockerfile" }
        }
        return nil
    }

    /// The AI formats reader's model and pickle files (S-21).
    public static let aiModelExtensions: Set<String> = ["gguf", "safetensors", "onnx", "mlmodel", "pkl", "pickle", "joblib", "pt", "pth"]
    /// The everyday reader's formats (S-23); VitrineFormatsTests holds the list equal to EverydayReader.knownExtensions.
    public static let everydayExtensions: Set<String> = ["srt", "vtt", "webvtt", "ass", "ssa", "ttml", "dfxp", "lrc", "ics", "ical", "icalendar",
                                                         "ifb", "vcf", "vcard", "eml", "msg", "bib", "tex", "ltx", "latex"]

    /// The media reader's formats by extension (S-23); images stay the image card's.
    public static let mediaExtensions: Set<String> = ["epub", "cbz", "cbr", "cb7", "cbt", "geojson", "gpx", "kml", "kmz", "stl", "obj", "3mf",
                                                      "gltf", "glb", "mp3", "m4a", "flac", "ogg", "oga", "opus", "wav"]

    /// The lockfiles LockfileReader knows, by name (A-12); VitrineEngineeringTests holds the two lists equal.
    public static let lockfileNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", ".package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock",
        "cargo.lock", "gemfile.lock", "gems.locked", "poetry.lock", "uv.lock", "pipfile.lock", "go.sum", "go.work.sum",
        "package.resolved", "composer.lock", "podfile.lock",
    ]

    /// SSH's key files by name (T-10).
    static let sshFileNames: Set<String> = ["authorized_keys", "authorized_keys2", "known_hosts", "id_rsa", "id_ed25519", "id_ecdsa",
                                            "id_dsa", "id_ed25519_sk", "id_ecdsa_sk"]

    /// A marimo notebook says so in its first lines, at the left margin and outside any triple-quoted string:
    /// `import marimo` and `app = marimo.App(…)` (any name for the app). `__generated_with` may stand between them, or
    /// be missing. Only the text is read; nothing in the file runs. roadmap: S-21
    public static func looksLikeMarimo(_ sample: Data) -> Bool {
        let text = String(decoding: sample.prefix(sampleLength), as: UTF8.self)
        guard text.contains("import marimo"), text.contains("marimo.App(") else { return false }
        var imports = false, app = false
        var open: String?   // the triple quote a string opened on an earlier line still waits for
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = raw.hasPrefix("\u{FEFF}") ? raw.dropFirst() : raw
            let startsInString = open != nil
            // Triple-quoted strings across lines; one that opens and closes on the same line leaves nothing open.
            var rest = line
            while !rest.isEmpty {
                if let quote = open {
                    guard let end = rest.range(of: quote) else { break }
                    rest = rest[end.upperBound...]
                    open = nil
                } else {
                    let first = [rest.range(of: "\"\"\""), rest.range(of: "'''")].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
                    guard let first else { break }
                    open = String(rest[first])
                    rest = rest[first.upperBound...]
                }
            }
            guard !startsInString else { continue }
            if line.hasPrefix("import marimo"), line.dropFirst(13).first.map({ $0 == " " || $0 == "," || $0 == "\t" }) ?? true { imports = true }
            if line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*=\s*marimo\.App\("#, options: .regularExpression) != nil { app = true }
            if imports && app { return true }
        }
        return false
    }

    static func looksLikeSSHPublicKey(_ sample: Data) -> Bool {
        ["ssh-", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-"].contains { sample.starts(with: Array($0.utf8)) }
    }

    static func readSample(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: sampleLength) ?? Data()
    }

    /// An archive named by its first bytes, for a file whose extension says nothing: the signatures VitrineArchive's
    /// readers recognise. `isoMarker` reads the five bytes at 32,769, where ISO 9660 puts `CD001`, only if asked.
    /// roadmap: S-8
    public static func archiveFormat(sniffing sample: Data, isoMarker: () -> Data? = { nil }) -> FileKind.ArchiveFormat? {
        let s = [UInt8](sample.prefix(512))
        func starts(_ magic: [UInt8]) -> Bool { s.count >= magic.count && Array(s.prefix(magic.count)) == magic }
        // Zip and gzip are left out on purpose: Office documents, Pages files and many others are zips under their
        // own extensions, and they stay what their type says.
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if starts([0x04, 0x22, 0x4D, 0x18]) { return .lz4 }
        if starts(Array("LZIP".utf8)) { return .lzip }
        if starts(Array("BZh".utf8)), s.count > 3, (0x31...0x39).contains(s[3]) { return .bzip2 }
        if starts([0x1F, 0x9D]) { return .compress }
        if starts([0xED, 0xAB, 0xEE, 0xDB]) { return .rpm }
        if starts(Array("xar!".utf8)) { return .xar }
        if starts([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0]) { return .cab }
        if starts(Array("!<arch>\ndebian-binary".utf8)) { return .deb }
        if s.count >= 263, Array(s[257..<262]) == Array("ustar".utf8) { return .tar }
        if starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8)) { return .cpio }
        if s.count >= 7, s[2] == 0x2D, s[3] == 0x6C, [0x68, 0x7A].contains(s[4]), s[6] == 0x2D { return .lha }
        if sample.count >= 8 * 1024, isoMarker() == Data("CD001".utf8) { return .iso }
        return nil
    }

    static func readISOMarker(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0x8001)
        return try handle.read(upToCount: 5)
    }

    static func hasSQLiteHeader(_ data: Data) -> Bool {
        data.starts(with: Array("SQLite format 3\0".utf8))
    }

    /// `#!/usr/bin/env python3` → "python"; `#!/bin/bash` → "shell".
    static func shebangLanguage(_ data: Data) -> String? {
        guard data.starts(with: [0x23, 0x21]) else { return nil }
        let firstLine = data.prefix { $0 != 0x0A }
        guard let line = String(data: firstLine, encoding: .utf8) else { return nil }
        let parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" })
        let interpreter = (parts.last == "env" ? nil : parts.last) ?? parts.first
        guard var name = interpreter.map(String.init) else { return nil }
        if parts.contains("env"), let i = parts.firstIndex(of: "env"), parts.count > i + 1 { name = String(parts[i + 1]) }
        name = name.trimmingCharacters(in: .whitespaces)
        let cleaned = name.replacingOccurrences(of: #"\d+(\.\d+)*$"#, with: "", options: .regularExpression)
        switch cleaned {
        case "python": return "python"
        case "bash", "sh", "zsh", "fish", "ksh": return "shell"
        case "node", "deno", "bun": return "javascript"
        case "ruby": return "ruby"
        case "perl": return "perl"
        case "php": return "php"
        case "swift": return "swift"
        default: return cleaned.isEmpty ? nil : cleaned
        }
    }
}
