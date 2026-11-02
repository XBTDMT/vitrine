import Darwin
import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the web renderers' resources over a private `vitrine:` scheme, because a page loaded with
/// `loadHTMLString` has no right to read `file:` subresources and `loadFileURL` grants only one directory.
/// Three hosts: `vitrine://vendor/<path>` is the framework's bundled third-party web assets (KaTeX, mermaid, later
/// Monaco and Shiki); `vitrine://app/<path>` is Vitrine's own page scripts beside the templates; `vitrine://doc/<path>`
/// is a file relative to the previewed document's folder, which is exactly what a relative image link means;
/// `vitrine://remote/<key>` is a web image the user chose to load once (G-10), held in memory.
/// Nothing outside those roots is ever served: a path is resolved with every symbolic link in every component
/// followed (realpath), and only a regular file whose real path lies inside the root's own real path is read, so
/// neither `..` nor a link planted beside the document (`secret.png -> ~/.ssh/id_rsa`, `assets -> ../..`) can reach
/// out, and a device, FIFO or folder is never opened as a resource (S-16 F14). Export reads through the same check
/// (MarkdownRenderer.embeddingImages, F10).
/// roadmap: S-4, S-16
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "vitrine"
    let documentRoot: URL
    let vendorRoot: URL?
    let appRoot: URL?
    let remote = RemoteImageStore()
    /// The roots' real paths (no link left in them), found once; nil when a root is not a folder.
    private let realDocumentRoot: String?
    private let realVendorRoot: String?
    private let realAppRoot: String?

    init(documentRoot: URL) {
        self.documentRoot = documentRoot.standardizedFileURL
        let bundle = Bundle(for: PreviewSchemeHandler.self)
        self.vendorRoot = bundle.url(forResource: "vendor", withExtension: nil, subdirectory: "web")?.standardizedFileURL
        self.appRoot = bundle.url(forResource: "web", withExtension: nil)?.standardizedFileURL
        self.realDocumentRoot = ConfinedFile.realDirectory(self.documentRoot)
        self.realVendorRoot = vendorRoot.flatMap(ConfinedFile.realDirectory)
        self.realAppRoot = appRoot.flatMap(ConfinedFile.realDirectory)
    }

    static var vendorBase: String { "\(scheme)://vendor" }
    static var documentBase: URL { URL(string: "\(scheme)://doc/")! }

    /// The real file a `vitrine:` URL names: a regular file inside its root once every link is followed; nil for
    /// anything else (another scheme or host, an escape, a missing file, a link out, a folder, a device, a FIFO).
    func resolve(_ url: URL) -> URL? {
        guard let found = locate(url) else { return nil }
        return URL(fileURLWithPath: found.real)
    }

    /// The bytes of the file a `vitrine:` URL names, read through the same check; nil when refused, unreadable or
    /// larger than `limit`.
    func read(_ url: URL, limit: Int = .max) -> (file: URL, data: Data)? {
        guard let found = locate(url),
              let data = ConfinedFile.read(found.real, identity: found.identity, limit: limit) else { return nil }
        return (URL(fileURLWithPath: found.real), data)
    }

    /// The target's real path and identity, when the URL passes every check.
    private func locate(_ url: URL) -> (real: String, identity: ConfinedFile.Identity)? {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let root: URL, realRoot: String
        switch host {
        case "vendor": guard let v = vendorRoot, let r = realVendorRoot else { return nil }; root = v; realRoot = r
        case "app": guard let a = appRoot, let r = realAppRoot else { return nil }; root = a; realRoot = r
        case "doc": guard let r = realDocumentRoot else { return nil }; root = documentRoot; realRoot = r
        default: return nil
        }
        // `path` is already percent-decoded; decoding it a second time would turn `%2520` into a space.
        let relative = url.path(percentEncoded: false)
        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }   // no lexical escape above the root
        return ConfinedFile.check(target.path, inside: realRoot)           // nor a real one, through any link
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        if let url = task.request.url, url.host == "remote", let image = remote.image(String(url.path.dropFirst())) {
            task.didReceive(URLResponse(url: url, mimeType: image.mime, expectedContentLength: image.data.count, textEncodingName: nil))
            task.didReceive(image.data)
            task.didFinish()
            return
        }
        guard let (file, data) = read(task.request.url ?? URL(string: "about:blank")!) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        // An HTTP-style response so module scripts load: the page sits at vitrine://doc/ and the code view's modules at
        // vitrine://app/, a different origin to WebKit, which fetches modules in CORS mode. Only Vitrine's own scheme
        // is ever served, so allowing every origin here opens nothing (G-9's rule list still blocks the network).
        let headers = ["Content-Type": mime.hasPrefix("text/") || mime.hasSuffix("javascript") ? "\(mime); charset=utf-8" : mime,
                       "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*"]
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: task.request.url!, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Reading a file a page or a document names without leaving a folder (S-16 F10, F14). The check resolves every
/// symbolic link in every component (realpath) and accepts only a regular file whose real path lies inside the
/// folder's real path. The read then opens that real path refusing a link anywhere in it (O_NOFOLLOW_ANY), never
/// blocks on a FIFO (O_NONBLOCK), and goes on only while the opened file is a regular file and the very file that
/// was checked (same device and inode), so a link put in place after the check is not followed either.
/// roadmap: S-16
enum ConfinedFile {
    struct Identity: Equatable { let device: dev_t; let inode: ino_t }

    /// `path` with every link resolved, or nil when a component does not exist or cannot be read.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A folder's real path; nil when it is not a folder.
    static func realDirectory(_ url: URL) -> String? {
        guard let real = realPath(url.path) else { return nil }
        var st = stat()
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return real
    }

    /// The real path and identity of `path` when it is a regular file inside `realRoot` (itself a real path).
    static func check(_ path: String, inside realRoot: String) -> (real: String, identity: Identity)? {
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        guard let real = realPath(path), real.hasPrefix(prefix) else { return nil }
        var st = stat()
        guard lstat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return (real, Identity(device: st.st_dev, inode: st.st_ino))
    }

    /// The bytes of a file `check` accepted, read only while it is still that same regular file; nil when it
    /// changed, cannot be read, or is larger than `limit`.
    static func read(_ real: String, identity: Identity, limit: Int) -> Data? {
        let fd = open(real, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)   // O_NOFOLLOW_ANY covers O_NOFOLLOW (both together are EINVAL)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Identity(device: st.st_dev, inode: st.st_ino) == identity,
              st.st_size >= 0, st.st_size <= Int64(limit) else { return nil }
        let size = Int(st.st_size)
        var data = Data(count: size)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return size == 0 }
            while filled < size {
                let n = Darwin.read(fd, base + filled, size - filled)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { break }   // the file shrank since fstat; keep what is there
                filled += n
            }
            return true
        }
        guard ok else { return nil }
        if filled < size { data.removeSubrange(filled...) }
        return data
    }
}
