import Foundation
import OSLog

/// G-10 B (ruled 2026-10-29): a README's web images load only when the user clicks "Load once". The
/// extension fetches them, never the page (G-9 keeps the page locked off the network), and only the image URLs
/// written in the file itself: at most `maxImages`, each at most `maxBytes`, `image/*` responses only, over an
/// ephemeral session with no cookies, credentials or cache. The bytes live in memory for this page and are served
/// to it as `vitrine://remote/<key>`; nothing is written to disk or remembered for the next open. roadmap: S-4
enum RemoteImages {
    static let maxImages = 20
    static let maxBytes = 5 * 1024 * 1024
    private static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "markdown")

    /// The remote images a rendered page shows, in order, without repeats: the `src` exactly as the page has it
    /// (the page's chips carry the same text) and the URL to fetch (`//` becomes https).
    static func images(inHTML html: String) -> [(src: String, url: URL)] {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*\ssrc="([^"]*)""#, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>(), out: [(src: String, url: URL)] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let src = html[r].replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            guard let url = URL(string: src.hasPrefix("//") ? "https:" + src : src), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil, seen.insert(src).inserted else { continue }
            out.append((src, url))
            if out.count == maxImages { break }
        }
        return out
    }

    struct Fetched: Sendable { let src: String; let data: Data; let mime: String }

    /// Fetches each image once, four at a time; a failure, a non-image or an oversized body is simply left out.
    static func fetch(_ images: [(src: String, url: URL)], session: URLSession = RemoteImages.session) async -> [Fetched] {
        let list = Array(images.prefix(maxImages))
        let results = await withTaskGroup(of: (Int, Fetched?).self) { group in
            var next = 0, out: [(Int, Fetched?)] = []
            func add() { let i = next; next += 1; group.addTask { (i, await one(list[i], session: session)) } }
            while next < min(4, list.count) { add() }
            for await r in group { out.append(r); if next < list.count { add() } }
            return out
        }
        let fetched = results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        log.info("remote images: \(list.count, privacy: .public) asked, \(fetched.count, privacy: .public) loaded")
        return fetched
    }

    private static func one(_ image: (src: String, url: URL), session: URLSession) async -> Fetched? {
        let url = image.url
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime.hasPrefix("image/"),
              http.expectedContentLength <= Int64(maxBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch { return nil }
        return Fetched(src: image.src, data: data, mime: mime)
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()
}

/// The fetched images for one page, served by `PreviewSchemeHandler` as `vitrine://remote/<key>`.
final class RemoteImageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: (data: Data, mime: String)] = [:]

    func add(_ data: Data, mime: String) -> String {
        lock.withLock {
            let key = "r\(images.count + 1)"
            images[key] = (data, mime)
            return key
        }
    }

    func image(_ key: String) -> (data: Data, mime: String)? { lock.withLock { images[key] } }
}
