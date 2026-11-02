import AppKit
import SwiftUI
import VitrinePreviewKit

/// The person's actions behind Settings › General › Claude connector (X-9, G-22): connect or disconnect Vitrine in
/// Claude Code and in the Claude app. Each shows exactly what will change before it changes it, and nothing calls
/// these on its own; the Settings buttons (and only a click on them) do. roadmap: S-11
@MainActor
enum ClaudeConnector {
    /// The `vitrine` executable inside this copy of Vitrine, which Claude starts as `vitrine mcp`.
    nonisolated static var command: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vitrine").path }

    // MARK: Claude Code, through its own `claude mcp` commands (Claude Code owns its settings file)

    enum CodeState: Equatable { case checking, connected, connectedElsewhere, notConnected, noClaude }

    nonisolated static var addArguments: [String] { ["mcp", "add", "--scope", "user", ClaudeAppConnector.serverName, "--", command, "mcp"] }
    nonisolated static let removeArguments = ["mcp", "remove", "--scope", "user", ClaudeAppConnector.serverName]
    nonisolated static let getArguments = ["mcp", "get", ClaudeAppConnector.serverName]

    /// Claude Code's `claude`, found through the person's login shell (the app's own PATH is the system's), then the
    /// installer's usual places.
    nonisolated static func claudeExecutable() -> URL? {
        if let out = run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"], timeout: 10)?.output,
           let line = out.split(separator: "\n").last.map(String.init), line.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: line) { return URL(fileURLWithPath: line) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Runs a program to its end (or the time limit) and returns its exit status and combined output.
    nonisolated static func run(_ program: URL, _ arguments: [String], timeout: Double = 30) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        while process.isRunning, Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) } else { output.append(chunk) }
        }
        if process.isRunning { process.terminate(); return nil }
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// Whether Claude Code knows Vitrine, and whether it is this copy.
    nonisolated static func codeState() -> CodeState {
        guard let claude = claudeExecutable() else { return .noClaude }
        guard let result = run(claude, getArguments), result.status == 0 else { return .notConnected }
        return result.output.contains(command) ? .connected : .connectedElsewhere
    }

    static func confirmCodeConnect() async -> CodeState {
        guard let claude = await Task.detached(operation: { claudeExecutable() }).value else {
            show(title: String(localized: "Claude Code was not found", comment: "Alert title: the claude command is not installed"),
                 text: String(localized: "Vitrine looks for the claude command in your shell and in Claude Code’s usual places. Install Claude Code, then connect again.",
                              comment: "Alert text when the claude command is not found; keep the command name claude"))
            return .noClaude
        }
        let line = ([claude.path] + addArguments).map(shellQuoted).joined(separator: " ")
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect Vitrine to Claude Code?", comment: "Alert title before Vitrine registers its connector with Claude Code")
        alert.informativeText = String(localized: """
        Vitrine runs the command below, which adds Vitrine to Claude Code’s MCP servers for every project. Claude can then \
        describe, read, picture and scan files with Vitrine; every tool is read-only and nothing leaves this Mac. \
        Disconnect runs claude mcp remove.
        """, comment: "Alert text before registering with Claude Code; keep 'claude mcp remove' and MCP as written")
        alert.accessoryView = textBox(line)
        alert.addButton(withTitle: String(localized: "Connect", comment: "Alert button that registers the connector"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return await Task.detached { codeState() }.value }
        // A copy registered from elsewhere is taken out first, so the entry names this copy.
        let args = addArguments, remove = removeArguments
        let result = await Task.detached { () -> (status: Int32, output: String)? in
            if codeState() == .connectedElsewhere { _ = run(claude, remove) }
            return run(claude, args)
        }.value
        if result?.status != 0 { show(title: claudeFailed, text: result?.output ?? "") }
        return await Task.detached { codeState() }.value
    }

    static func confirmCodeDisconnect() async -> CodeState {
        guard let claude = await Task.detached(operation: { claudeExecutable() }).value else { return .noClaude }
        let alert = NSAlert()
        alert.messageText = String(localized: "Disconnect Vitrine from Claude Code?", comment: "Alert title before Vitrine removes its connector from Claude Code")
        alert.informativeText = String(localized: "Vitrine runs the command below; Claude Code stops offering Vitrine’s tools. Nothing else changes.",
                                       comment: "Alert text before removing the connector from Claude Code")
        alert.accessoryView = textBox(([claude.path] + removeArguments).map(shellQuoted).joined(separator: " "))
        alert.addButton(withTitle: String(localized: "Disconnect", comment: "Alert button that removes the connector"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return await Task.detached { codeState() }.value }
        let args = removeArguments
        let result = await Task.detached { run(claude, args) }.value
        if result?.status != 0 { show(title: claudeFailed, text: result?.output ?? "") }
        return await Task.detached { codeState() }.value
    }

    static var claudeFailed: String { String(localized: "Claude Code did not make the change", comment: "Alert title when a claude mcp command failed") }

    // MARK: The Claude app, through its settings file (shown before it is written)

    static func confirmAppConnect(_ connector: ClaudeAppConnector = ClaudeAppConnector(command: command)) {
        do {
            guard let plan = try connector.planConnect() else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Connect Vitrine to the Claude app?", comment: "Alert title before Vitrine edits the Claude app's settings file")
            alert.informativeText = String(localized: """
            Vitrine adds the entry below to the MCP servers in \(display(plan.file)) and changes nothing else. Quit and reopen \
            the Claude app to see Vitrine’s tools. Every tool is read-only and nothing leaves this Mac.
            """, comment: "Alert text; the settings file's path; keep MCP as written")
            alert.accessoryView = textBox(plan.change)
            alert.addButton(withTitle: String(localized: "Connect", comment: "Alert button that registers the connector"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try connector.apply(plan)
        } catch {
            show(title: appFailed, text: error.localizedDescription)
        }
    }

    static func confirmAppDisconnect(_ connector: ClaudeAppConnector = ClaudeAppConnector(command: command)) {
        do {
            guard let plan = try connector.planDisconnect() else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Disconnect Vitrine from the Claude app?", comment: "Alert title before Vitrine edits the Claude app's settings file")
            alert.informativeText = String(localized: "Vitrine takes this text out of \(display(plan.file)) and changes nothing else.",
                                           comment: "Alert text; the settings file's path")
            alert.accessoryView = textBox(plan.change.trimmingCharacters(in: .whitespacesAndNewlines))
            alert.addButton(withTitle: String(localized: "Disconnect", comment: "Alert button that removes the connector"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try connector.apply(plan)
        } catch {
            show(title: appFailed, text: error.localizedDescription)
        }
    }

    static var appFailed: String { String(localized: "The Claude app’s settings were not changed", comment: "Alert title when connecting to the Claude app failed") }

    // MARK: Shared

    nonisolated static func shellQuoted(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=".contains($0) } ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private static func textBox(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 80))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.string = text
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }

    private static func show(title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Settings › General › Claude connector › Claude Code: Connect… or Disconnect…, after a check of `claude mcp get`.
struct ClaudeCodeConnectButton: View {
    @State private var state: ClaudeConnector.CodeState = .checking

    var body: some View {
        Group {
            switch state {
            case .checking:
                ProgressView().controlSize(.small)
            case .connected:
                Button(String(localized: "Disconnect…", comment: "Settings › Claude connector: button")) {
                    Task { state = await ClaudeConnector.confirmCodeDisconnect() }
                }
            case .connectedElsewhere, .notConnected, .noClaude:
                Button(String(localized: "Connect…", comment: "Settings › Claude connector: button")) {
                    Task { state = await ClaudeConnector.confirmCodeConnect() }
                }
                .help(state == .connectedElsewhere
                      ? String(localized: "Claude Code has another copy of Vitrine; connecting points it at this one", comment: "Settings › Claude connector: tooltip")
                      : "")
            }
        }
        .buttonStyle(.vitrine)
        .task { state = await Task.detached { ClaudeConnector.codeState() }.value }
    }
}

/// Settings › General › Claude connector › Claude app.
struct ClaudeAppConnectButton: View {
    @State private var registered = ClaudeAppConnector(command: ClaudeConnector.command).registeredCommand

    var body: some View {
        Button(registered == ClaudeConnector.command
               ? String(localized: "Disconnect…", comment: "Settings › Claude connector: button")
               : String(localized: "Connect…", comment: "Settings › Claude connector: button")) {
            if registered == ClaudeConnector.command { ClaudeConnector.confirmAppDisconnect() } else { ClaudeConnector.confirmAppConnect() }
            registered = ClaudeAppConnector(command: ClaudeConnector.command).registeredCommand
        }
        .buttonStyle(.vitrine)
    }
}
