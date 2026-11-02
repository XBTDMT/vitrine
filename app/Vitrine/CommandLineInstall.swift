import AppKit
import SwiftUI
import VitrineUI

/// Putting the `vitrine` command on the person's PATH, only when they ask (onboarding.html screen 10 "Just for me",
/// settings.html › Integrations › Command line tool). The one thing Vitrine itself ever writes is a symbolic link in
/// `~/.local/bin`, a folder the person owns, so no password is asked. The every-account place (`/usr/local/bin`)
/// needs an administrator: Vitrine shows the exact command for the person to run in Terminal and never runs it.
/// Remove deletes only a link that points into a Vitrine.app. roadmap: S-10 (H-3)
struct CommandLineInstaller {
    /// The tool inside this app: `Vitrine.app/Contents/Helpers/vitrine`.
    var toolURL: URL
    /// Where "Just for me" puts the link: `~/.local/bin/vitrine`.
    var linkURL: URL

    static let toolName = "vitrine"

    init(toolURL: URL, linkURL: URL) {
        self.toolURL = toolURL
        self.linkURL = linkURL
    }

    /// This app's tool and the person's own `~/.local/bin`.
    static func forThisApp(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CommandLineInstaller {
        CommandLineInstaller(toolURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(toolName)"),
                             linkURL: home.appendingPathComponent(".local/bin/\(toolName)"))
    }

    enum State: Equatable {
        case notInstalled
        /// The link points at this app's tool.
        case installed
        /// The link points at the tool of another Vitrine.app (an older copy, a moved app): Install updates it.
        case linkedToOtherVitrine(String)
        /// Something that is not Vitrine's has the name: Vitrine leaves it alone. The payload is where the link points,
        /// nil when a file that is not a link has the name.
        case occupied(String?)
    }

    var state: State {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return fm.fileExists(atPath: linkURL.path) ? .occupied(nil) : .notInstalled
        }
        let resolved = URL(fileURLWithPath: target, relativeTo: linkURL.deletingLastPathComponent()).standardizedFileURL.path
        if resolved == toolURL.standardizedFileURL.path { return .installed }
        return Self.isVitrineTool(resolved) ? .linkedToOtherVitrine(resolved) : .occupied(resolved)
    }

    /// `…/<name>.app/Contents/Helpers/vitrine`.
    static func isVitrineTool(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count >= 4 else { return false }
        let tail = parts.suffix(4)
        return tail[tail.startIndex].hasSuffix(".app") && Array(tail.dropFirst()) == ["Contents", "Helpers", toolName]
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// Where the link that has the name points; nil for a file that is not a link.
        case occupied(String?)
        case toolMissing(String)
        var errorDescription: String? {
            let link = Self.short
            switch self {
            case .occupied(let target?):
                return String(localized: "\(link) is already taken by \(target). Vitrine left it alone.",
                              comment: "Command line install error; the link's path, then the path it points to")
            case .occupied(nil):
                return String(localized: "\(link) is already taken by a file that is not a link. Vitrine left it alone.",
                              comment: "Command line install error; the link's path")
            case .toolMissing(let path):
                return String(localized: "The command is missing from this copy of Vitrine (\(path)).", comment: "Command line install error; the expected path of the tool")
            }
        }
        static let short = "~/.local/bin/vitrine"
    }

    /// Creates `~/.local/bin` if needed and links the tool there; replaces only a link to another Vitrine.app.
    func install() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: toolURL.path) else { throw Failure.toolMissing(toolURL.path) }
        switch state {
        case .installed: return
        case .occupied(let what): throw Failure.occupied(what)
        case .linkedToOtherVitrine: try fm.removeItem(at: linkURL)
        case .notInstalled: break
        }
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: toolURL)
    }

    /// Deletes the link when it is Vitrine's (this app's or another Vitrine.app's); anything else stays.
    func remove() throws {
        switch state {
        case .installed, .linkedToOtherVitrine: try FileManager.default.removeItem(at: linkURL)
        case .notInstalled: return
        case .occupied(let what): throw Failure.occupied(what)
        }
    }

    // MARK: Words to copy

    /// The "Just for me" link as a Terminal command, for someone who prefers to make it themselves.
    var linkCommand: String { "mkdir -p ~/.local/bin && ln -sf \(Self.quote(toolURL.path)) ~/.local/bin/vitrine" }
    /// The every-account link: needs an administrator, so it is only ever shown.
    var allAccountsCommand: String { "sudo ln -sf \(Self.quote(toolURL.path)) /usr/local/bin/vitrine" }
    /// zsh (the macOS default shell) finds commands in `~/.local/bin` once this line is in `~/.zshrc`.
    static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#

    /// Single-quoted for any POSIX shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

// MARK: The install view

/// The command's install controls as one block, for the Settings › Integrations row and onboarding's "Command line"
/// extra (both drawn by their own agents); today it also opens from the app menu's "Command Line Tool…".
struct CommandLineInstallView: View {
    var installer = CommandLineInstaller.forThisApp()
    @State private var state: CommandLineInstaller.State = .notInstalled
    @State private var problem: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The vitrine command").font(.system(size: Metric.value("fs-title3"), weight: .semibold))
                Text("Preview any file from Terminal. Optional.")
                    .foregroundStyle(Color.token("t2"))
            }
            group {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Just for me")
                        Text("~/.local/bin/vitrine · no password").font(.caption).foregroundStyle(Color.token("t2"))
                    }
                    Spacer()
                    statusText
                    switch state {
                    case .installed: Button("Remove") { act { try installer.remove() } }
                    case .linkedToOtherVitrine: Button("Update") { act { try installer.install() } }
                    case .notInstalled: Button("Install") { act { try installer.install() } }.keyboardShortcut(.defaultAction)
                    case .occupied: EmptyView()
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("For every account on this Mac")
                    Text("/usr/local/bin/vitrine needs your password, so Vitrine does not do it. Run this in Terminal:")
                        .font(.caption).foregroundStyle(Color.token("t2")).fixedSize(horizontal: false, vertical: true)
                    commandRow(installer.allAccountsCommand)
                }
            }
            if let problem {
                Text(problem).foregroundStyle(Color.token("danger-text")).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("If Terminal says “command not found”, add this line to ~/.zshrc:")
                    .font(.caption).foregroundStyle(Color.token("t2"))
                commandRow(CommandLineInstaller.pathLine)
            }
            VStack(alignment: .leading, spacing: 2) {
                // The commands are code and stay as written; the comment lines above them are translated.
                Text(verbatim: "# " + String(localized: "preview files in a Vitrine window", comment: "Command line example: a shell comment above `vitrine README.md data/orders.csv`"))
                Text(verbatim: "vitrine README.md data/orders.csv")
                Text(verbatim: "# " + String(localized: "compare two files", comment: "Command line example: a shell comment above `vitrine compare staging.yaml production.yaml`"))
                Text(verbatim: "vitrine compare staging.yaml production.yaml")
            }
            .font(.system(size: Metric.value("fs-mono"), design: .monospaced))
            .foregroundStyle(Color.token("t1"))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metric.value("r-code")).fill(Color.token("code")))
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { state = installer.state }
    }

    @ViewBuilder private var statusText: some View {
        switch state {
        case .installed: Text("Installed").foregroundStyle(Color.token("ok-text"))
        case .notInstalled: Text("Not installed").foregroundStyle(Color.token("t2"))
        case .linkedToOtherVitrine: Text("Points at another copy of Vitrine").foregroundStyle(Color.token("needs-text"))
        case .occupied: Text("Taken by something else").foregroundStyle(Color.token("needs-text"))
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Metric.value("r-card")).fill(Color.token("card")))
            .overlay(RoundedRectangle(cornerRadius: Metric.value("r-card")).strokeBorder(Color.token("hair"), lineWidth: 0.5))
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: Metric.value("fs-mono"), design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(copied == command ? String(localized: "Copied", comment: "Command line window: button after the command was copied")
                                     : String(localized: "Copy", comment: "Command line window: button that copies the command")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = command
            }
            .controlSize(.small)
        }
    }

    private func act(_ change: () throws -> Void) {
        do { try change(); problem = nil } catch { problem = error.localizedDescription }
        state = installer.state
    }
}
