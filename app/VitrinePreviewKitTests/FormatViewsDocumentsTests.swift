import AppKit
import Network
import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineFormats

/// Format views F5, F6 and F7 (option A, picked): the book and comic stage, the email stage and the invite and
/// contact stages. Every file is invented here: an EPUB and a CBZ assembled byte by byte (with covers drawn by Core
/// Graphics), and .eml, .ics and .vcf text read through the real readers. Each view is laid out at 900 × 420 on the
/// card's stage (with the card's 16/44 insets), drawn light and dark into PNGs in the temporary folder (paths
/// printed), and checked for meaningful pixels. The email test also proves the message cannot reach the network: a
/// listener on 127.0.0.1 stands in for the internet, a positive control shows it hears a direct request, then the
/// message's remote image and a link must leave it silent. roadmap: S-23
@MainActor
final class FormatViewsDocumentsTests: XCTestCase {

    // MARK: Invented files

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for x in bytes { crc = table[Int((crc ^ UInt32(x)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// A stored (uncompressed) zip with a correct central directory.
    private func zip(_ files: [(String, [UInt8])]) -> Data {
        var out: [UInt8] = [], central: [UInt8] = []
        func le16(_ v: Int, _ b: inout [UInt8]) { b += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int, _ b: inout [UInt8]) { for i in 0..<4 { b.append(UInt8((v >> (8 * i)) & 0xFF)) } }
        for (name, data) in files {
            let offset = out.count, crc = Int(crc32(data)), n = Array(name.utf8)
            le32(0x0403_4B50, &out); le16(20, &out); le16(0, &out); le16(0, &out); le16(0, &out); le16(0x21, &out)
            le32(crc, &out); le32(data.count, &out); le32(data.count, &out); le16(n.count, &out); le16(0, &out)
            out += n; out += data
            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le16(0x21, &central); le32(crc, &central); le32(data.count, &central); le32(data.count, &central)
            le16(n.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central); le32(0, &central)
            le32(offset, &central); central += n
        }
        let cdOffset = out.count
        out += central
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out); le16(files.count, &out); le16(files.count, &out)
        le32(central.count, &out); le32(cdOffset, &out); le16(0, &out)
        return Data(out)
    }

    /// An invented cover: a dusk sky over the sea, a moon and a lighthouse, drawn with Core Graphics as a PNG.
    private func coverPNG(width: Int = 380, height: Int = 560) throws -> [UInt8] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [CGColor(srgbRed: 0.78, green: 0.54, blue: 0.29, alpha: 1), CGColor(srgbRed: 0.18, green: 0.35, blue: 0.42, alpha: 1),
                      CGColor(srgbRed: 0.12, green: 0.23, blue: 0.30, alpha: 1)] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.91, blue: 0.71, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width * 62 / 100, y: height * 45 / 100, width: 60, height: 60))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.90, blue: 0.84, alpha: 1))
        ctx.fill(CGRect(x: width * 44 / 100, y: height * 22 / 100, width: 28, height: 170))
        let image = try XCTUnwrap(ctx.makeImage())
        return Array(try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])))
    }

    private func epub(cover: [UInt8]?) -> Data {
        let container = """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let coverItem = cover == nil ? "" : #"<item id="cov" href="images/cover.png" media-type="image/png" properties="cover-image"/>"#
        let chapters = ["The Last Lamp on the Coast", "Charts and Tides", "A Keeper's Log", "Winter Light", "The Paper Harbour",
                        "Fog Signals", "The Northern Reef", "Salt and Brass", "A Letter from the Mainland", "Low Water"]
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>The Lighthouse Keeper's Atlas</dc:title>
            <dc:creator id="a1">Mara Ellison</dc:creator>
            <meta refines="#a1" property="role" scheme="marc:relators">aut</meta>
            <dc:language>en-GB</dc:language>
            <dc:publisher>Example Press</dc:publisher>
            <dc:date>2025-03-14</dc:date>
            <dc:identifier id="id">urn:uuid:00000000-1111-2222-3333-44444444a17f</dc:identifier>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(coverItem)
            <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """
        var items = chapters.enumerated().map { i, t in "<li><a href=\"text/ch1.xhtml#c\(i)\">\(t.replacingOccurrences(of: "'", with: "&#39;"))</a></li>" }
        items[1] = "<li><a href=\"text/ch1.xhtml#c1\">Charts and Tides</a><ol><li><a href=\"text/ch1.xhtml#c1a\">Reading a Chart</a></li></ol></li>"
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol>\(items.joined())</ol></nav></body></html>
        """
        var files: [(String, [UInt8])] = [("mimetype", Array("application/epub+zip".utf8)), ("META-INF/container.xml", Array(container.utf8)),
                                          ("OEBPS/content.opf", Array(opf.utf8)), ("OEBPS/nav.xhtml", Array(nav.utf8)),
                                          ("OEBPS/text/ch1.xhtml", Array("<html/>".utf8))]
        if let cover { files.append(("OEBPS/images/cover.png", cover)) }
        return zip(files)
    }

    // MARK: Hosting and pictures

    /// The view on the card's stage, as BinaryCardView places a format view: 16 pt sides and foot, 44 pt top.
    private func host(_ view: NSView, appearance: NSAppearance.Name = .aqua) -> (StageView, NSWindow) {
        let stage = StageView()
        stage.translatesAutoresizingMaskIntoConstraints = true
        stage.frame = NSRect(x: 0, y: 0, width: 932, height: 480)
        view.frame = NSRect(x: 16, y: 16, width: 900, height: 420)
        stage.addSubview(view)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 932, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = stage
        window.appearance = NSAppearance(named: appearance)
        stage.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (stage, window)
    }

    /// Draws the stage into a bitmap; a web view inside is pasted from its own snapshot (WebKit draws out of process).
    private func picture(_ stage: StageView, web: WKWebView? = nil) async throws -> NSBitmapImageRep {
        stage.layoutSubtreeIfNeeded()
        stage.displayIfNeeded()
        let rep = try XCTUnwrap(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
        stage.cacheDisplay(in: stage.bounds, to: rep)
        guard let web else { return rep }
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        let shot = try await web.takeSnapshot(configuration: config)
        let frame = web.convert(web.bounds, to: stage)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        shot.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @discardableResult
    private func write(_ rep: NSBitmapImageRep, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-formatviews-\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("FormatViewsDocumentsTests PNG: \(url.path)")
        return url
    }

    /// The colour at a point given in the stage's top-left coordinates (the bitmap's own rows run top-down).
    private func color(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
    }

    /// How many sampled pixels inside `rect` (stage coordinates, top-left origin) differ clearly from the stage
    /// ground at the same height, and how many distinct colours they take.
    private func ink(_ rep: NSBitmapImageRep, in rect: NSRect) -> (differing: Int, colours: Int) {
        var differing = 0
        var colours = Set<UInt32>()
        for y in stride(from: rect.minY, to: rect.maxY, by: 2) {
            guard let ground = color(rep, x: 4, y: y) else { continue }
            for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
                guard let c = color(rep, x: x, y: y) else { continue }
                let d = abs(c.redComponent - ground.redComponent) + abs(c.greenComponent - ground.greenComponent) + abs(c.blueComponent - ground.blueComponent)
                if d > 0.12 { differing += 1 }
                colours.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return (differing, colours.count)
    }

    /// A rectangle in a view's own coordinates as stage coordinates with a top-left origin (the bitmap's).
    private func topLeft(_ rect: NSRect, in view: NSView, on stage: NSView) -> NSRect {
        let r = view.convert(rect, to: stage)
        return NSRect(x: r.minX, y: stage.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func texts(_ view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            let own = (sub as? NSTextField).map { [$0.stringValue] } ?? []
            return own + texts(sub)
        }
    }

    // MARK: F5 book and comic

    func testBookStandsOnItsPlinthWithContentsBesideDetails() async throws {
        guard case .book(let book)? = MediaReader.read(data: epub(cover: try coverPNG()), fileName: "atlas.epub") else {
            return XCTFail("not read as a book")
        }
        XCTAssertNotNil(book.cover, "the invented cover is in the summary")
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = BookStageView(book: book)
            let (stage, window) = host(view, appearance: appearance)
            defer { window.orderOut(nil) }
            await view.waitUntilDrawn()
            view.layoutSubtreeIfNeeded()
            if case .image = view.coverView.state {} else { XCTFail("the cover picture is decoded and drawn") }
            XCTAssertLessThan(abs(view.coverView.aspect - 380.0 / 560.0), 0.01, "the cover keeps its own shape")
            let words = texts(view)
            XCTAssertTrue(words.contains("The Last Lamp on the Coast"), "the contents list the first chapter")
            XCTAssertTrue(words.contains("Reading a Chart"), "a nested entry is listed under its chapter")
            XCTAssertTrue(words.contains("Mara Ellison"), "the details name the author")
            XCTAssertTrue(words.contains("Example Press"))
            XCTAssertTrue(words.contains { $0.hasPrefix("urn:uuid:") }, "the identifier is in the details")
            XCTAssertFalse(view.contentsGroup.isHidden)
            XCTAssertGreaterThan(view.contentsGroup.visibleRowCount, 5, "the contents fill the height beside the cover")
            XCTAssertLessThan(view.coverView.frame.maxX, view.contentsGroup.frame.minX, "the contents stand beside the cover")
            XCTAssertLessThan(view.contentsGroup.frame.maxX, view.detailsGroup.frame.minX, "the details stand beside the contents")

            let rep = try await picture(stage)
            try write(rep, "book-\(mode)")
            let cover = view.convert(view.coverView.frame, to: stage)
            let coverTop = NSRect(x: cover.minX, y: stage.bounds.height - cover.maxY, width: cover.width, height: cover.height)
            let painted = ink(rep, in: coverTop.insetBy(dx: 12, dy: 12))
            XCTAssertGreaterThan(painted.differing, 1_000, "the cover is painted, not the bare stage")
            let moon = try XCTUnwrap(color(rep, x: coverTop.minX + coverTop.width * 0.70, y: coverTop.minY + coverTop.height * 0.50))
            XCTAssertGreaterThan(moon.redComponent, 0.85, "the invented cover's pale moon shows where it was drawn")
            let groups = ink(rep, in: NSRect(x: 340, y: 60, width: 560, height: 360))
            XCTAssertGreaterThan(groups.colours, 6, "the groups carry text and panels")
        }
    }

    func testBookWithoutCoverGetsACalmGeneratedCoverAndAComicShowsItsFirstPage() async throws {
        guard case .book(let book)? = MediaReader.read(data: epub(cover: nil), fileName: "atlas.epub") else { return XCTFail("not a book") }
        XCTAssertNil(book.cover)
        let view = BookStageView(book: book)
        let (stage, window) = host(view)
        defer { window.orderOut(nil) }
        await view.waitUntilDrawn()
        XCTAssertTrue(view.coverView.isGenerated, "no cover in the file: a generated one with the title")
        XCTAssertEqual(view.coverView.title, "The Lighthouse Keeper's Atlas")
        let rep = try await picture(stage)
        try write(rep, "book-generated-light")
        let cover = view.convert(view.coverView.frame, to: stage)
        let box = NSRect(x: cover.minX, y: stage.bounds.height - cover.maxY, width: cover.width, height: cover.height).insetBy(dx: 14, dy: 14)
        let painted = ink(rep, in: box)
        XCTAssertGreaterThan(painted.differing, 1_000, "the generated cover is painted")
        XCTAssertGreaterThan(painted.colours, 8, "the generated cover carries its gradient and its title")

        // A comic: the first page (in reading order) is the cover; its pages are the contents.
        let page1 = try coverPNG(width: 300, height: 460)
        let info = "<?xml version=\"1.0\"?><ComicInfo><Series>Invented Heroes</Series><Number>7</Number><Title>The Test</Title><Writer>Dee Author</Writer><Penciller>Eve Artist</Penciller><Year>2025</Year></ComicInfo>"
        let cbz = zip([("pages/page2.png", try coverPNG(width: 40, height: 60)), ("pages/page1.png", page1), ("ComicInfo.xml", Array(info.utf8))])
        guard case .comic(let comic)? = MediaReader.read(data: cbz, fileName: "heroes.cbz") else { return XCTFail("not a comic") }
        let comicView = BookStageView(comic: comic)
        let (comicStage, comicWindow) = host(comicView, appearance: .darkAqua)
        defer { comicWindow.orderOut(nil) }
        await comicView.waitUntilDrawn()
        comicView.layoutSubtreeIfNeeded()
        XCTAssertEqual(comicView.kind, .comic)
        if case .image(let image) = comicView.coverView.state { XCTAssertEqual(image.width * 46, image.height * 30, "page 1 is the cover") } else {
            XCTFail("the first page is drawn as the cover")
        }
        let words = texts(comicView)
        XCTAssertTrue(words.contains("page1.png") && words.contains("page2.png"), "the pages are listed")
        XCTAssertTrue(words.contains("Eve Artist"))
        try write(try await picture(comicStage), "comic-dark")
    }

    func testANarrowStageShowsTheCoverAlone() async throws {
        guard case .book(let book)? = MediaReader.read(data: epub(cover: nil), fileName: "atlas.epub") else { return XCTFail("not a book") }
        let view = BookStageView(book: book)
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 360)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.contentsGroup.isHidden && view.detailsGroup.isHidden)
        XCTAssertEqual(view.coverView.frame.midX, 150, accuracy: 1, "the cover is centred")
    }

    // MARK: F6 email

    private final class Listener: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        let ready = XCTestExpectation(description: "listener ready")

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.lock.withLock { self?._count += 1 }
                connection.cancel()
            }
            listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.fulfill() } }
            listener.start(queue: .global())
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }
        deinit { listener.cancel() }
    }

    private func phishing(base: String) -> String {
        let html = """
        <html><head><style>.brand{color:#2C4A7A;font-weight:700;font-size:14px}.btn{display:inline-block;background:#2C4A7A;color:#fff;padding:8px 16px;border-radius:6px;text-decoration:none;font-weight:600}</style></head>
        <body><div class="brand"><img src="\(base)/logo.png" width="24" height="24" alt=""> Northwind Bank</div>
        <h2 style="font-size:18px;margin:12px 0 8px">Your account is on hold</h2>
        <p>Dear customer,</p>
        <p>We noticed unusual sign-in activity and have placed a temporary hold on your account. To avoid losing access, confirm your details within <b>24 hours</b>.</p>
        <p><a class="btn" href="\(base)/signin?u=1">Sign in to Northwind</a></p>
        <p style="color:#777;font-size:11px">Northwind Bank · This is an automated message.</p>
        <img src="\(base)/pixel.gif" width="1" height="1" alt="">
        <script>document.title = "pwned"</script>
        </body></html>
        """
        return [
            "Authentication-Results: mx.example.com; spf=fail smtp.mailfrom=northwind-secure-login.example;",
            "  dkim=none; dmarc=fail header.from=northwind-bank.example",
            "From: Northwind Bank <alerts@northwind-bank.example>",
            "To: name@example.com",
            "Subject: Your account is on hold",
            "Date: Mon, 26 Oct 2026 09:14:00 +0000",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"alt\"",
            "",
            "--alt",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Dear customer, we noticed unusual sign-in activity.",
            "--alt",
            "Content-Type: text/html; charset=utf-8",
            "",
            html,
            "--alt--",
            "",
        ].joined(separator: "\r\n")
    }

    func testEmailRendersTheMessageWithoutLoadingAnythingRemote() async throws {
        let sink = try Listener()
        await fulfillment(of: [sink.ready], timeout: 5)
        let base = "http://127.0.0.1:\(sink.port)"

        // Positive control: the listener does hear a direct request, so silence later means something.
        _ = try? await URLSession.shared.data(from: URL(string: "\(base)/control")!)
        for _ in 0..<40 where sink.count == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThanOrEqual(sink.count, 1, "control: the listener must accept a direct connection")
        try await Task.sleep(for: .milliseconds(300))
        var baseline = sink.count

        guard case .email(let mail)? = EverydayReader.read(data: Data(phishing(base: base).utf8), fileName: "Your account is on hold.eml") else {
            return XCTFail("not read as an email")
        }
        XCTAssertNotNil(mail.htmlBody)
        XCTAssertTrue(mail.warnings.contains { $0.level == .danger }, "the invented message fails DMARC")

        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = EmailStageView(summary: mail)
            let (stage, window) = host(view, appearance: appearance)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            await view.waitUntilLoaded()
            let web = try XCTUnwrap(view.webView, "the HTML body is drawn by a web view")
            XCTAssertNil(view.textView)
            XCTAssertTrue(view.isLockedDown, "the content rule list was installed before the page loaded")
            XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript, "page JavaScript is off")
            XCTAssertFalse(web.configuration.websiteDataStore.isPersistent, "nothing is stored")
            XCTAssertEqual(view.remoteReferences, 2, "the logo and the tracking pixel are remote references, both blocked")
            XCTAssertEqual(view.navigationLog.map { $0.url?.absoluteString }, ["about:blank"], "the page's own load is the only navigation")
            XCTAssertFalse(view.navigationLog.contains { ["http", "https"].contains($0.url?.scheme ?? "") }, "no http(s) request reached the delegate")

            // The message's own script did not run; the remote pictures did not load (asked from the app's world).
            let title = try await web.evaluateJavaScript("document.title") as? String
            XCTAssertNotEqual(title, "pwned", "a script in the message must not run")
            let widths = try await web.callAsyncJavaScript("return Array.from(document.images).map(i => i.naturalWidth)",
                                                           contentWorld: .defaultClient) as? [NSNumber]
            XCTAssertEqual(widths?.map(\.intValue), [0, 0], "neither remote picture loaded")

            // The link is shown (its target kept for the ring) but is no link: a click activates nothing.
            let link = try await web.callAsyncJavaScript(
                "const a = document.querySelector('a'); const r = [a.hasAttribute('href') ? 1 : 0, a.getAttribute('data-vitrine-href') || '']; a.click(); return r;",
                contentWorld: .defaultClient) as? [Any]
            XCTAssertEqual(link?.first as? Int, 0, "the link has no href to follow")
            XCTAssertEqual(link?.last as? String, "\(base)/signin?u=1", "the target is kept for the ring")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(view.navigationLog.count, 1, "a click on the link starts no navigation")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(sink.count, baseline, "nothing from the message, nor the click, reached the listener (\(mode))")

            // A navigation that reaches the delegate anyway (here the app's own load call) is cancelled.
            let beforeAPI = sink.count
            web.load(URLRequest(url: URL(string: "\(base)/clicked")!))
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(view.navigationLog.last?.url?.absoluteString, "\(base)/clicked")
            XCTAssertEqual(view.navigationLog.last?.allowed, false, "a navigation after the first load is refused")
            // Measured, not asserted: WebKit may open a speculative connection to a URL the app itself loads while
            // the policy is decided. The view never calls load with a remote URL, and the page cannot ask for one.
            print("FormatViewsDocumentsTests: connections during an app-initiated load of a remote URL: \(sink.count - beforeAPI)")
            try await Task.sleep(for: .milliseconds(400))
            baseline = sink.count

            // The danger label says why, in the reader's words.
            let label = try XCTUnwrap(view.dangerLabel, "a danger warning puts the red label on the message")
            XCTAssertTrue(label.text.stringValue.hasPrefix("Probably phishing."))
            XCTAssertTrue(label.text.stringValue.contains("DMARC"))

            let rep = try await picture(stage, web: web)
            try write(rep, "email-\(mode)")
            let webFrame = web.convert(web.bounds, to: stage)
            let body = NSRect(x: webFrame.minX, y: stage.bounds.height - webFrame.maxY, width: webFrame.width, height: webFrame.height)
            let paper = try XCTUnwrap(color(rep, x: body.maxX - 12, y: body.maxY - 6))
            XCTAssertGreaterThan(paper.brightnessComponent, 0.95, "the message keeps its light page in \(mode)")
            var dark = 0
            for y in stride(from: body.minY, to: body.maxY, by: 2) {
                for x in stride(from: body.minX, to: body.maxX, by: 2) where (color(rep, x: x, y: y)?.brightnessComponent ?? 1) < 0.5 { dark += 1 }
            }
            XCTAssertGreaterThan(dark, 300, "the rendered message has text and its button")
            let labelFrame = label.convert(label.bounds, to: stage)
            let red = try XCTUnwrap(color(rep, x: labelFrame.midX, y: stage.bounds.height - labelFrame.maxY + 1.5))
            XCTAssertGreaterThan(red.redComponent, 0.7, "the label's strong red rule is drawn")
            XCTAssertLessThan(red.greenComponent, 0.35)
        }
    }

    func testAPlainMessageShowsItsTextWithoutAWebView() async throws {
        let text = "From: Ana Lima <ana@acme.example>\nTo: bo@acme.example\nSubject: Lunch on Thursday\nDate: 3 Nov 26 12:00 GMT\n"
            + "Authentication-Results: mx.acme.example; spf=pass; dkim=pass; dmarc=pass\n\nHi Bo,\n\nShall we meet at the harbour café at noon?\n\nAna\n"
        guard case .email(let mail)? = EverydayReader.read(data: Data(text.utf8), fileName: "lunch.eml") else { return XCTFail("not an email") }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = EmailStageView(summary: mail)
            let (stage, window) = host(view, appearance: appearance)
            defer { window.orderOut(nil) }
            await view.waitUntilLoaded()
            XCTAssertNil(view.webView, "no HTML, no web view")
            XCTAssertNil(view.dangerLabel, "a clean message has no red label")
            let shown = try XCTUnwrap(view.textView?.string)
            XCTAssertTrue(shown.hasPrefix("Lunch on Thursday"), "the subject heads the text")
            XCTAssertTrue(shown.contains("harbour café"))
            let rep = try await picture(stage)
            try write(rep, "email-plain-\(mode)")
            XCTAssertGreaterThan(ink(rep, in: NSRect(x: 200, y: 60, width: 520, height: 120)).colours, 4, "the text is drawn on the sheet")
            if appearance == .aqua {
                // The sheet's foot is square (the page runs on): its very corner is the white page, not the stage.
                let sheet = topLeft(view.sheetContent.frame, in: view, on: stage)
                let corner = try XCTUnwrap(color(rep, x: sheet.minX + 1, y: sheet.maxY - 1))
                let ground = try XCTUnwrap(color(rep, x: 4, y: sheet.maxY - 1))
                XCTAssertGreaterThan(corner.brightnessComponent - ground.brightnessComponent, 0.04, "the bottom corner is not rounded away")
                let top = try XCTUnwrap(color(rep, x: sheet.minX + 1, y: sheet.minY + 1))
                XCTAssertLessThan(abs(top.brightnessComponent - ground.brightnessComponent), 0.08, "the top corner is rounded")
            }
        }
    }

    // MARK: F7 invite and contact

    private let invite = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example//Invented//EN
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:walkthrough-0001@example.com
    SUMMARY:Studio walkthrough
    DTSTART:20261112T140000
    DTEND:20261112T150000
    LOCATION:Pier 9 Studio\\, 9 Example Wharf
    ORGANIZER;CN=Priya Raman:mailto:priya@example.com
    ATTENDEE;CN=Jonah Whitaker;PARTSTAT=ACCEPTED:mailto:jonah@example.com
    ATTENDEE;CN=Sam Patel;PARTSTAT=ACCEPTED:mailto:sam@example.com
    ATTENDEE;CN=Lee Morgan;PARTSTAT=TENTATIVE:mailto:lee@example.com
    ATTENDEE;CN=Ana Lima;PARTSTAT=NEEDS-ACTION:mailto:ana@example.com
    ATTENDEE;CN=Bo Okafor;PARTSTAT=DECLINED:mailto:bo@example.com
    RRULE:FREQ=WEEKLY;COUNT=4;BYDAY=TH
    BEGIN:VALARM
    ACTION:DISPLAY
    TRIGGER:-PT15M
    END:VALARM
    END:VEVENT
    END:VCALENDAR
    """

    func testInviteDrawsTheEventCardWithItsHourAndTheMissingZone() async throws {
        guard case .calendar(let cal)? = EverydayReader.read(data: Data(invite.replacingOccurrences(of: "\n", with: "\r\n").utf8), fileName: "walkthrough.ics") else {
            return XCTFail("not read as a calendar")
        }
        let event = try XCTUnwrap(cal.events.first)
        XCTAssertTrue(event.start?.isFloating == true, "the invented invite names no time zone")
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = InviteStageView(calendar: cal)
            let (stage, window) = host(view, appearance: appearance)
            defer { window.orderOut(nil) }
            XCTAssertEqual(view.dateTile.day, "12")
            XCTAssertFalse(view.dateTile.month.isEmpty)
            XCTAssertTrue(view.kicker.stringValue.hasPrefix(String(localized: "Invitation", bundle: .previewKit).uppercased()))
            XCTAssertEqual(view.titleField.stringValue, "Studio walkthrough")
            XCTAssertTrue(view.whenField.stringValue.contains("Pier 9 Studio"))
            let strip = try XCTUnwrap(view.strip)
            XCTAssertEqual(strip.startMinute, 14 * 60)
            XCTAssertEqual(strip.endMinute, 15 * 60)
            XCTAssertEqual(view.visibleLineCount, view.lines.count, "every line fits at 900 × 420")
            XCTAssertEqual(view.lines.first?.tone, .caution, "a floating time is the caution line")
            let words = view.lines.map(\.text)
            XCTAssertTrue(words.contains { $0.contains("Priya Raman") }, "the organiser is named")
            XCTAssertTrue(words.contains { $0.contains("5") && $0.contains("2 accepted") }, "the guests and their answers")
            XCTAssertTrue(words.contains { $0 == event.recurrence }, "the repeat rule in words")
            XCTAssertTrue(words.contains { $0.contains("15 minutes") }, "the alert")
            let rep = try await picture(stage)
            try write(rep, "invite-\(mode)")
            let card = ink(rep, in: NSRect(x: 216, y: 60, width: 500, height: 400))
            XCTAssertGreaterThan(card.differing, 2_000, "the invite card stands out from the stage")
            let block = strip.convert(NSRect(x: strip.x(forMinute: 14 * 60 + 30), y: 30, width: 1, height: 1), to: stage)
            let accent = try XCTUnwrap(color(rep, x: block.minX, y: stage.bounds.height - block.minY))
            XCTAssertGreaterThan(accent.greenComponent, accent.redComponent, "the event block is drawn in the accent")
        }

        // A zoned invite says its zone.
        let zoned = invite.replacingOccurrences(of: "DTSTART:20261112T140000", with: "DTSTART;TZID=Europe/Paris:20261112T140000")
            .replacingOccurrences(of: "DTEND:20261112T150000", with: "DTEND;TZID=Europe/Paris:20261112T150000")
        guard case .calendar(let zonedCal)? = EverydayReader.read(data: Data(zoned.utf8), fileName: "z.ics") else { return XCTFail("zoned") }
        let zonedView = InviteStageView(calendar: zonedCal)
        XCTAssertEqual(zonedView.lines.first?.tone, .plain)
        XCTAssertTrue(zonedView.lines.first?.text.contains("Europe/Paris") == true)
    }

    private func photoPNG() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.35, blue: 0.20, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.85, blue: 0.70, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 35, y: 40, width: 50, height: 50))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage())).representation(using: .png, properties: [:]))
    }

    func testContactDrawsInitialsOrPhotoNameOrganisationAndReach() async throws {
        let card = [
            "BEGIN:VCARD", "VERSION:4.0", "FN:Jonah Whitaker", "N:Whitaker;Jonah;;;", "ORG:Example Robotics", "TITLE:Lead Engineer",
            "TEL;TYPE=cell:+1 555 010 0199", "TEL;TYPE=work:+1 555 010 0142", "EMAIL;TYPE=work:jonah@example.com",
            "BDAY:--0314", "END:VCARD",
        ]
        guard case .contacts(let plain)? = EverydayReader.read(data: Data(card.joined(separator: "\r\n").utf8), fileName: "Jonah Whitaker.vcf") else {
            return XCTFail("not read as contacts")
        }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = ContactStageView(contacts: plain)
            let (stage, window) = host(view, appearance: appearance)
            defer { window.orderOut(nil) }
            await view.waitUntilDrawn()
            XCTAssertEqual(view.initials, "JW")
            XCTAssertNil(view.photo)
            XCTAssertEqual(view.nameField.stringValue, "Jonah Whitaker")
            XCTAssertEqual(view.subtitleField?.stringValue, "Lead Engineer · Example Robotics")
            XCTAssertEqual(view.reach.map(\.value), ["+1 555 010 0199", "+1 555 010 0142", "jonah@example.com"])
            XCTAssertEqual(view.reach.first?.label, "mobile")
            XCTAssertEqual(view.visibleReachCount, 3, "every number and address fits")
            let rep = try await picture(stage)
            try write(rep, "contact-\(mode)")
            // The avatar's centre is the avatar gradient, not the stage.
            let avatar = ink(rep, in: topLeft(view.avatarFrame.insetBy(dx: 12, dy: 12), in: view, on: stage))
            XCTAssertGreaterThan(avatar.differing, 300, "the initials avatar is drawn")
        }

        // With an embedded photo, the photo is drawn in the circle.
        let withPhoto = card.dropLast() + ["PHOTO:data:image/png;base64," + (try photoPNG()).base64EncodedString(), "END:VCARD"]
        let second = ["BEGIN:VCARD", "VERSION:3.0", "FN:Sam Patel", "END:VCARD"]
        guard case .contacts(let pictured)? = EverydayReader.read(data: Data((withPhoto + second).joined(separator: "\r\n").utf8), fileName: "two.vcf") else {
            return XCTFail("photo card")
        }
        let view = ContactStageView(contacts: pictured)
        let (stage, window) = host(view)
        defer { window.orderOut(nil) }
        await view.waitUntilDrawn()
        XCTAssertNotNil(view.photo, "the embedded photo is decoded")
        XCTAssertNotNil(view.countField, "a second card is counted")
        let rep = try await picture(stage)
        try write(rep, "contact-photo-light")
        var orange = 0
        let circle = topLeft(view.avatarFrame, in: view, on: stage)
        for y in stride(from: circle.minY, to: circle.maxY, by: 2) {
            for x in stride(from: circle.minX, to: circle.maxX, by: 2) {
                if let c = color(rep, x: x, y: y), c.redComponent > 0.75, c.greenComponent < 0.5, c.blueComponent < 0.35 { orange += 1 }
            }
        }
        XCTAssertGreaterThan(orange, 100, "the photo's own colours are in the circle")
    }
}
