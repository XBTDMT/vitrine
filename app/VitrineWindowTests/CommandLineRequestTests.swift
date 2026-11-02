import XCTest

/// The `vitrine` command's arguments and the vitrine:// wire format (S-10, H-3). Pure: no process, no app, no files.
final class CommandLineRequestTests: XCTestCase {
    let cwd = URL(fileURLWithPath: "/tmp/invented-project", isDirectory: true)

    private func parse(_ args: String...) -> CommandLineInvocation { CommandLineInvocation.parse(args, cwd: cwd) }
    private func file(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }

    func testBareFilesOpenAsTabsResolvedAgainstTheShellDirectory() {
        XCTAssertEqual(parse("README.md", "data/orders.csv"),
                       .request(.open(files: [file("/tmp/invented-project/README.md"), file("/tmp/invented-project/data/orders.csv")]), background: false))
    }

    func testOpenSubcommandAndOptions() {
        XCTAssertEqual(parse("open", "--float", "--follow", "logs/app.log"),
                       .request(.open(files: [file("/tmp/invented-project/logs/app.log")], float: true, follow: true), background: false))
        XCTAssertEqual(parse("open", "--new-window", "-g", "/abs/a.txt"),
                       .request(.open(files: [file("/abs/a.txt")], newWindow: true), background: true))
    }

    func testCompareBothSpellings() {
        let expected = CommandLineInvocation.request(.compare(old: file("/tmp/invented-project/staging.yaml"),
                                                              new: file("/tmp/invented-project/production.yaml")), background: false)
        XCTAssertEqual(parse("compare", "staging.yaml", "production.yaml"), expected)
        XCTAssertEqual(parse("--compare", "staging.yaml", "production.yaml"), expected)
        guard case .usageError = parse("compare", "only-one.yaml") else { return XCTFail("one file must be a usage error") }
        guard case .usageError = parse("--compare", "a", "b", "c") else { return XCTFail("three files must be a usage error") }
    }

    func testHelpVersionAndErrors() {
        XCTAssertEqual(parse(), .help)
        XCTAssertEqual(parse("--help"), .help)
        XCTAssertEqual(parse("-h"), .help)
        XCTAssertEqual(parse("--version"), .version)
        guard case .usageError(let m) = parse("open", "--bogus", "a") else { return XCTFail() }
        XCTAssertTrue(m.contains("--bogus"))
        guard case .usageError = parse("open") else { return XCTFail("open with no file is a usage error") }
        guard case .usageError = parse("compare", "--float", "a", "b") else { return XCTFail("--float is not a compare option") }
    }

    func testDesignedCommandsNotInThisBuildSaySo() {
        XCTAssertEqual(parse("describe", "orders.csv"), .notBuilt("describe"))
        XCTAssertEqual(parse("render", "server.ts", "--png"), .notBuilt("render"))
        XCTAssertEqual(parse("mcp"), .mcp)
        if case .usageError = parse("mcp", "--port", "80") {} else { XCTFail("mcp takes no arguments") }
    }

    func testDoubleDashLetsFilesLookLikeOptionsOrCommands() {
        XCTAssertEqual(parse("open", "--", "--float", "-g"),
                       .request(.open(files: [file("/tmp/invented-project/--float"), file("/tmp/invented-project/-g")]), background: false))
        XCTAssertEqual(parse("./describe"), .request(.open(files: [file("/tmp/invented-project/describe")]), background: false))
    }

    func testTildeExpandsAndDotsCollapse() {
        guard case .request(.open(let files, _, _, _), _) = parse("~/notes/a.md", "../other/b.md") else { return XCTFail() }
        XCTAssertEqual(files[0].path, NSString(string: "~/notes/a.md").expandingTildeInPath)
        XCTAssertEqual(files[1].path, "/tmp/other/b.md")
    }

    func testTooManyFilesIsRefusedBeforeAnythingOpens() {
        let many = (0...VitrineRequest.maxFiles).map { "f\($0).txt" }
        guard case .usageError = CommandLineInvocation.parse(many, cwd: cwd) else { return XCTFail() }
    }

    // MARK: vitrine:// URLs

    func testURLRoundTripsAwkwardPaths() throws {
        let awkward = ["/tmp/a b/c&d=e+f.md", "/tmp/100%/#hash?.txt", "/tmp/café/日本語 ファイル.csv", "/tmp/quote'\"back\\slash.log"]
        let request = VitrineRequest.open(files: awkward.map { URL(fileURLWithPath: $0) }, float: true, follow: true, newWindow: true)
        let url = request.url
        XCTAssertEqual(url.scheme, "vitrine")
        XCTAssertEqual(url.host, "open")
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertEqual(try VitrineRequest(url: url), request)
    }

    func testCompareURLRoundTrips() throws {
        let request = VitrineRequest.compare(old: URL(fileURLWithPath: "/tmp/x/staging.yaml"), new: URL(fileURLWithPath: "/tmp/x/production.yaml"))
        XCTAssertEqual(request.url.absoluteString, "vitrine://compare?old=/tmp/x/staging.yaml&new=/tmp/x/production.yaml")
        XCTAssertEqual(try VitrineRequest(url: request.url), request)
    }

    func testTheDesignsRaycastFormReads() throws {
        // settings.html › Integrations: "vitrine://open?path=…"
        let url = URL(string: "vitrine://open?path=%2Ftmp%2Fnotes%2FREADME.md")!
        XCTAssertEqual(try VitrineRequest(url: url), .open(files: [URL(fileURLWithPath: "/tmp/notes/README.md")]))
    }

    func testURLsTheAppMustRefuse() {
        func refuses(_ s: String, _ expected: RequestError, line: UInt = #line) {
            XCTAssertThrowsError(try VitrineRequest(url: URL(string: s)!), line: line) { XCTAssertEqual($0 as? RequestError, expected, line: line) }
        }
        refuses("https://open?path=/tmp/a", .notVitrine)
        refuses("vitrine://open", .noFiles)
        refuses("vitrine://open?path=relative/a.md", .relativePath("relative/a.md"))
        refuses("vitrine://delete?path=/tmp/a", .unknownAction("delete"))
        refuses("vitrine://compare?old=/tmp/a", .compareNeedsTwo)
        let tooMany = (0...VitrineRequest.maxFiles).map { "path=/tmp/f\($0)" }.joined(separator: "&")
        refuses("vitrine://open?\(tooMany)", .tooManyFiles(VitrineRequest.maxFiles + 1))
    }

    func testDotDotInAURLPathIsCollapsed() throws {
        let request = try VitrineRequest(url: URL(string: "vitrine://open?path=/tmp/a/../b.md")!)
        XCTAssertEqual(request.files.map(\.path), ["/tmp/b.md"])
    }
}
