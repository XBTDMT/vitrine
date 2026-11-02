import XCTest

/// Installing the command (S-10, H-3): a link in a folder the person owns, made only on request, and Remove that
/// deletes only Vitrine's own link. Every path is an invented one in a temporary folder; nothing touches the real
/// home folder or PATH.
final class CommandLineInstallTests: XCTestCase {
    var root: URL!
    var tool: URL!
    var installer: CommandLineInstaller!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-install-\(UUID().uuidString)")
        let helpers = root.appendingPathComponent("Apps/Vitrine.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        tool = helpers.appendingPathComponent("vitrine")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        installer = CommandLineInstaller(toolURL: tool, linkURL: root.appendingPathComponent("home/.local/bin/vitrine"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testInstallCreatesTheFolderAndALinkToTheTool() throws {
        XCTAssertEqual(installer.state, .notInstalled)
        try installer.install()
        XCTAssertEqual(installer.state, .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path), tool.path)
        try installer.install()   // again: nothing changes
        XCTAssertEqual(installer.state, .installed)
    }

    func testRemoveDeletesOnlyTheLink() throws {
        try installer.install()
        try installer.remove()
        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tool.path), "the tool inside the app stays")
        try installer.remove()    // nothing to remove: no error
    }

    func testSomethingElseWithTheNameIsLeftAlone() throws {
        let bin = installer.linkURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A different program already called vitrine.
        try Data("someone else's".utf8).write(to: installer.linkURL)
        guard case .occupied = installer.state else { return XCTFail("a plain file is not Vitrine's") }
        XCTAssertThrowsError(try installer.install())
        XCTAssertThrowsError(try installer.remove())
        XCTAssertEqual(try String(contentsOf: installer.linkURL, encoding: .utf8), "someone else's")

        // A link to something that is not a Vitrine tool.
        try FileManager.default.removeItem(at: installer.linkURL)
        let other = root.appendingPathComponent("other-tool")
        try Data().write(to: other)
        try FileManager.default.createSymbolicLink(at: installer.linkURL, withDestinationURL: other)
        guard case .occupied(let target) = installer.state else { return XCTFail() }
        XCTAssertEqual(target, other.path)
        XCTAssertThrowsError(try installer.install())
        XCTAssertThrowsError(try installer.remove())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installer.linkURL.path), other.path)
    }

    func testALinkToAnotherCopyOfVitrineIsUpdated() throws {
        let oldHelpers = root.appendingPathComponent("Old/Vitrine.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: oldHelpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installer.linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: installer.linkURL, withDestinationURL: oldHelpers.appendingPathComponent("vitrine"))
        guard case .linkedToOtherVitrine = installer.state else { return XCTFail() }
        try installer.install()
        XCTAssertEqual(installer.state, .installed)
    }

    func testAMissingToolIsReportedNotLinked() throws {
        try FileManager.default.removeItem(at: tool)
        XCTAssertThrowsError(try installer.install()) { XCTAssertEqual($0 as? CommandLineInstaller.Failure, .toolMissing(self.tool.path)) }
        XCTAssertEqual(installer.state, .notInstalled)
    }

    func testRecognisesVitrineToolPaths() {
        XCTAssertTrue(CommandLineInstaller.isVitrineTool("/Applications/Vitrine.app/Contents/Helpers/vitrine"))
        XCTAssertTrue(CommandLineInstaller.isVitrineTool("/Users/x/Applications/Vitrine 2.app/Contents/Helpers/vitrine"))
        XCTAssertFalse(CommandLineInstaller.isVitrineTool("/usr/local/bin/vitrine"))
        XCTAssertFalse(CommandLineInstaller.isVitrineTool("/Applications/Vitrine.app/Contents/MacOS/Vitrine"))
    }

    func testCopyableCommandsQuoteThePathAndNeverRunSudo() {
        let odd = CommandLineInstaller(toolURL: URL(fileURLWithPath: "/Apps/Sam's Vitrine.app/Contents/Helpers/vitrine"),
                                       linkURL: URL(fileURLWithPath: "/tmp/x/vitrine"))
        XCTAssertEqual(odd.linkCommand, #"mkdir -p ~/.local/bin && ln -sf '/Apps/Sam'\''s Vitrine.app/Contents/Helpers/vitrine' ~/.local/bin/vitrine"#)
        XCTAssertEqual(odd.allAccountsCommand, #"sudo ln -sf '/Apps/Sam'\''s Vitrine.app/Contents/Helpers/vitrine' /usr/local/bin/vitrine"#)
        XCTAssertEqual(CommandLineInstaller.pathLine, #"export PATH="$HOME/.local/bin:$PATH""#)
    }
}
