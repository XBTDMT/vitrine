import AppKit
import VitrineBinary
import VitrineDocument
import VitrineSupport
import VitrineText
import VitrineTrust
import VitrineUI

/// The fallback for anything textual that has no richer renderer yet: a monospaced, read-only NSTextView that
/// streams the first window of a large file instead of loading all of it. Also what the Code family uses until the
/// web code renderer (S-5) lands, so no supported type ever shows Finder's grey icon. Structured files (JSON, YAML,
/// TOML, XML, property lists) go to StructuredRenderer first, which falls back here above the parse cap.
@MainActor
public final class PlainTextRenderer: Renderer {
    /// Above this size we show the first chunk, and the frame says so, instead of reading everything.
    public nonisolated static let streamingThreshold: Int64 = 4 * 1024 * 1024
    public nonisolated static let firstChunk = 1024 * 1024

    public static func canRender(_ kind: FileKind) -> Bool {
        switch kind {
        case .plainText, .code, .diff, .markdown, .csv, .archive, .appBundle, .installerPackage, .diskImage, .provisioningProfile: return true
        default: return false
        }
    }

    public init() {}

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        // A code signature's full check can take seconds (G-34); run it off the main actor, then build the facts.
        let document: PreviewDocument
        if Self.showsFacts(kind), BinaryFacts.assessesSignature(kind) {
            let signature = await Task.detached(priority: .userInitiated) { BinaryFacts.previewSignature(url) }.value
            document = try Self.document(url: url, kind: kind, assessSignature: { _ in signature })
        } else {
            document = try Self.document(url: url, kind: kind)
        }
        let (scroll, textView) = TextPreviewView.make(text: Self.shownText(document), context: context)
        // How much of a large file is shown is said in the frame's gutter (coverage), not in a banner here.
        return Self.wrap(scroll, textView: textView, scroll: scroll, document: document)
    }

    private static func wrap(_ root: NSView, textView: NSTextView, scroll: NSScrollView, document: PreviewDocument) -> RenderedPreview {
        let finder = TextFinder(textView)
        return RenderedPreview(view: root, document: document,
            reload: { url in
                let fresh = try Self.document(url: url, kind: document.kind)
                let y = scroll.contentView.bounds.origin.y
                finder.clear()
                textView.string = Self.shownText(fresh)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                return fresh
            },
            scrollOffset: { Double(scroll.contentView.bounds.origin.y) },
            restoreScroll: { y in scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) },
            find: { query, forward in finder.find(query, forward: forward) },
            clearFind: { finder.clear() })
    }

    /// The document for a textual file: one code or text view, the size and line facts, and partial coverage with
    /// the reason when only the first chunk was read.
    /// Apps, installers, disk images, profiles and torrents show their facts, never their bytes (S-8, S-22).
    static func showsFacts(_ kind: FileKind) -> Bool {
        if case .reader = kind { return true }
        return [.appBundle, .installerPackage, .diskImage, .provisioningProfile, .configurationProfile, .torrent, .keyMaterial, .lockfile,
                .archive(.ipa), .archive(.apk)].contains(kind)
    }

    static func document(url: URL, kind: FileKind,
                         assessSignature: (URL) -> SignatureAssessment = BinaryFacts.previewSignature) throws -> PreviewDocument {
        if showsFacts(kind) { return try BinaryFacts.document(url: url, kind: kind, assessSignature: assessSignature) }
        // Archives show their listing, never their bytes (S-8).
        if case .archive = kind { return try FamilyFacts.archive(url: url, kind: kind) }
        return FamilyFacts.enrich(try textDocument(url: url, kind: kind), url: url)
    }

    /// The text of the document's first view: a minified file opens formatted, the original one switch away.
    static func shownText(_ document: PreviewDocument) -> String {
        switch document.primaryView {
        case .text(let s), .code(let s, _), .formatted(let s, _): return s
        case .markdown: return document.searchText
        }
    }

    /// Nonisolated so the structured renderer can build its document off the main thread (S-5).
    nonisolated static func textDocument(url: URL, kind: FileKind, encoding: String.Encoding? = nil) throws -> PreviewDocument {
        // .nfo and .diz files are DOS art: code page 437, whatever the bytes would otherwise suggest (state 16).
        let dos = ["nfo", "diz"].contains(url.pathExtension.lowercased())
            ? String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))) : nil
        let (decoded, truncated) = try load(url, encoding: encoding ?? dos)
        // Secret values masked before the view, copy or find see them (T-4, G-23).
        let text = LensPolicy.masked(decoded.text, kind: kind).text
        let total = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        let view: DocumentView
        if case .code(let language) = kind { view = .code(text, language: language) } else { view = .text(text) }
        let coverage: Coverage = truncated
            ? .partial(shown: Int64(firstChunk), total: total, unit: .bytes,
                       reason: String(localized: "Large file: showing the first \(ByteCountFormatter.string(fromByteCount: Int64(firstChunk), countStyle: .memory))",
                                      bundle: .previewKit, comment: "Why a text preview is cut; the argument is a size such as '8 MB'."))
            : .complete
        let encodingName = decoded.hadBOM ? withBOM(decoded.name) : decoded.name
        var facts = [DocumentFacts.size(total ?? Int64(text.utf8.count)), DocumentFacts.lines(in: text),
                     Fact(key: "encoding", label: String(localized: "Encoding", bundle: .previewKit, comment: "Fact label: the text encoding."),
                          value: encodingName)]
        // What the page's notice says (code state 3): how it was read, and which characters prove it.
        if decoded.detected {
            let quoted = decoded.samples.map {
                String(localized: "“\(String($0))”", bundle: .previewKit, comment: "A sample of characters from the file, in quotation marks.")
            }
            let note: String
            switch quoted.count {
            case 0:
                note = String(localized: "Read as \(decoded.name), detected.", bundle: .previewKit,
                              comment: "Encoding notice: the encoding Vitrine detected and read the file in.")
            case 1:
                note = String(localized: "Read as \(decoded.name), detected. \(quoted[0]) is intact.", bundle: .previewKit,
                              comment: "Encoding notice: the detected encoding, then one quoted sample that reads correctly in it.")
            default:
                note = String(localized: "Read as \(decoded.name), detected. \(quoted.formatted(.list(type: .and, width: .narrow))) are intact.",
                              bundle: .previewKit,
                              comment: "Encoding notice: the detected encoding, then a list of quoted samples that read correctly in it.")
            }
            facts.append(Fact(key: "encodingNote", label: String(localized: "Read as", bundle: .previewKit,
                                                                 comment: "Fact label: the encoding notice."), value: note))
        }
        if decoded.lossy {
            facts.append(Fact(key: "encodingLossy", label: String(localized: "Unreadable bytes", bundle: .previewKit,
                                                                  comment: "Fact label: some bytes do not decode."),
                              value: String(localized: "Some bytes are not \(decoded.name)", bundle: .previewKit,
                                            comment: "Fact value: some bytes do not decode in the named encoding.")))
        }
        var document = PreviewDocument(kind: kind, facts: facts, views: [view], coverage: coverage)
        // A-4: every text preview built here (plain text, code, structured files, CSV) carries a token count, from the
        // whole file's size so a file read in part is still counted whole.
        document.setTokens(TokenCounting.count(.byteCount(Int(total ?? Int64(text.utf8.count)))))
        return document
    }

    /// "UTF-8 with BOM": the encoding fact when the file starts with a byte-order mark.
    nonisolated static func withBOM(_ name: String) -> String {
        String(localized: "\(name) with BOM", bundle: .previewKit,
               comment: "Encoding fact: the encoding's name (UTF-8), then that the file starts with a byte-order mark.")
    }

    /// Reads the whole file when small, the first chunk when large, and decodes it: a byte-order mark, then UTF-8,
    /// then the detected legacy encoding (TextEncodingDetector), or `encoding` when the reader picked one.
    nonisolated static func load(_ url: URL, encoding: String.Encoding? = nil) throws -> (TextEncodingDetector.Decoded, truncated: Bool) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let data: Data
        let truncated: Bool
        if size > streamingThreshold {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: firstChunk) ?? Data()
            truncated = true
        } else {
            data = try Data(contentsOf: url)
            truncated = false
        }
        return (TextEncodingDetector.decode(data, as: encoding, partial: truncated), truncated)
    }
}
