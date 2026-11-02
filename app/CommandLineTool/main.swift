import AppKit
import VitrineMCP

// `vitrine`: the command-line tool inside Vitrine.app (Contents/Helpers/vitrine). It never shows anything itself:
// it checks the files, turns the arguments into a `vitrine://` request (CommandLineRequest.swift) and hands that to
// the Vitrine.app it lives in, so a running Vitrine gets the files as new tabs of its window. The person puts it on
// their PATH by choice, from the app (a link in a folder they own); nothing here installs anything.
// What it prints is translated through CommandLineText (CommandLineRequest.swift), which reads the app's String Catalog;
// the `vitrine:` prefix and `vitrine <version>` stay as written. roadmap: S-10 (H-3), S-12 (H-6)

let stderr = FileHandle.standardError
func fail(_ message: String, code: Int32) -> Never {
    stderr.write(Data("vitrine: \(message)\n".utf8))
    exit(code)
}

/// The Vitrine.app this tool belongs to: three levels above the real (symlink-resolved) executable, checked by its
/// bundle identifier. A copy of the tool outside an app falls back to the app Launch Services knows by that id.
func owningApp() -> URL? {
    let appID = "io.github.xbtdmt.vitrine"
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == appID { return app }
    }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID)
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
switch CommandLineInvocation.parse(Array(CommandLine.arguments.dropFirst()), cwd: cwd) {
case .help:
    print(CommandLineInvocation.usage)
    exit(0)
case .version:
    let app = owningApp().flatMap { Bundle(url: $0) }
    print("vitrine \(app?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
    exit(0)
case .usageError(let message):
    stderr.write(Data("vitrine: \(message)\n\n\(CommandLineInvocation.usage)\n".utf8))
    exit(64)   // EX_USAGE
case .notBuilt(let command):
    fail(CommandLineText.notBuilt(command), code: 69)   // EX_UNAVAILABLE
case .mcp:
    // The Claude connector (X-9, G-22): the protocol here, each tool call in a fresh worker, the app binary run with
    // --mcp-call (no window, no Dock icon). Standard output carries only protocol lines; messages go to standard error.
    guard let app = owningApp(), let bundle = Bundle(url: app), let worker = bundle.executableURL else {
        fail(CommandLineText.appNotFound, code: 69)
    }
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let server = MCPServer(name: "Vitrine", version: version, instructions: ConnectorTools.instructions, tools: ConnectorTools.all,
                           backend: WorkerBackend(executable: worker), wrapper: ConnectorTools.wrap)
    Task { await server.serve(); exit(0) }
    dispatchMain()
case .request(let request, let background):
    // Every named file must exist: a missing one is reported and the rest still open, like a shell glob that half
    // matched; the exit code says something was missing.
    var missing: [String] = []
    for file in request.files where !FileManager.default.fileExists(atPath: file.path) { missing.append(file.path) }
    for path in missing { stderr.write(Data("vitrine: \(CommandLineText.noSuchFile(path))\n".utf8)) }
    if case .open(_, _, true, _) = request {
        stderr.write(Data("vitrine: \(CommandLineText.followNotBuilt)\n".utf8))
    }
    let sent: VitrineRequest
    switch request {
    case .compare:
        if !missing.isEmpty { exit(1) }
        sent = request
    case .open(let files, let float, let follow, let newWindow):
        let present = files.filter { !missing.contains($0.path) }
        if present.isEmpty { exit(1) }
        sent = .open(files: present, float: float, follow: follow, newWindow: newWindow)
    }
    guard let app = owningApp() else { fail(CommandLineText.appNotFound, code: 69) }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = !background
    configuration.addsToRecentItems = false
    // The answer may arrive on any queue, the main one included, so the main run loop turns until it does.
    final class Outcome: @unchecked Sendable { var finished = false; var error: Error? }
    let outcome = Outcome()
    NSWorkspace.shared.open([sent.url], withApplicationAt: app, configuration: configuration) { _, error in
        DispatchQueue.main.async { outcome.error = error; outcome.finished = true }
    }
    let wait = 30
    let deadline = Date().addingTimeInterval(TimeInterval(wait))
    while !outcome.finished, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    if !outcome.finished { fail(CommandLineText.noAnswer(within: wait), code: 75) }
    if let error = outcome.error { fail(CommandLineText.unreachable(error.localizedDescription), code: 69) }
    exit(missing.isEmpty ? 0 : 1)
}
