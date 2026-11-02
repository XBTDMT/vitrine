import Foundation

/// What the `vitrine` command asks the app to do, and the one wire format it travels in: a `vitrine://` URL.
///
/// The command (`app/CommandLineTool`, installed as `Vitrine.app/Contents/Helpers/vitrine`) parses its arguments into
/// a request, turns it into a URL and asks Launch Services to open that URL *with the app bundle it lives in*
/// (`NSWorkspace.open(_:withApplicationAt:configuration:)`, the call behind `open -a <app> <url>`). A running Vitrine
/// receives it as an Apple event in `application(_:open:)`, so a second `vitrine` call reuses the running app and
/// its window; a stopped Vitrine is launched first. The same URLs are the design's "URL scheme for Raycast and Alfred"
/// (`vitrine://open?path=…`, settings.html › Integrations).
///
/// Foundation only: compiled into the app, the command and the tests. roadmap: S-10 (H-3)
enum VitrineRequest: Equatable, Sendable {
    /// Open each file as a tab of the frontmost Vitrine window (window.html state 8). `float` opens each in its own
    /// window kept on top instead; `newWindow` starts a new window rather than adding tabs; `follow` asks the preview
    /// to stay on a growing file's newest lines.
    case open(files: [URL], float: Bool = false, follow: Bool = false, newWindow: Bool = false)
    /// Two files compared side by side in one tab (window.html state 3; the diff design's two-file compare).
    case compare(old: URL, new: URL)

    static let scheme = "vitrine"
    /// The most files one request may open: a link on a web page can carry a `vitrine://` URL too, and must not be
    /// able to bury the screen in windows.
    static let maxFiles = 50

    var files: [URL] {
        switch self {
        case .open(let files, _, _, _): return files
        case .compare(let old, let new): return [old, new]
        }
    }

    // MARK: URL form

    /// `vitrine://open?path=/a&path=/b[&float=1][&follow=1][&window=new]` · `vitrine://compare?old=/a&new=/b`.
    /// Paths are absolute and percent-encoded byte for byte, so `&`, `=`, `+`, `#`, `%` and spaces survive.
    var url: URL {
        var items: [(String, String)] = []
        let host: String
        switch self {
        case .open(let files, let float, let follow, let newWindow):
            host = "open"
            items = files.map { ("path", $0.path) }
            if float { items.append(("float", "1")) }
            if follow { items.append(("follow", "1")) }
            if newWindow { items.append(("window", "new")) }
        case .compare(let old, let new):
            host = "compare"
            items = [("old", old.path), ("new", new.path)]
        }
        let query = items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(Self.scheme)://\(host)?\(query)")!
    }

    /// Reads a `vitrine://` URL. Only absolute paths are accepted (a relative path has no meaning to the app, whose
    /// working directory is not the shell's), each is standardized, and anything else in the URL is refused.
    init(url: URL) throws(RequestError) {
        guard url.scheme?.lowercased() == Self.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .notVitrine }
        let items = parts.queryItems ?? []
        func paths(_ name: String) throws(RequestError) -> [URL] {
            var out: [URL] = []
            for item in items where item.name == name {
                guard let value = item.value, value.hasPrefix("/") else { throw .relativePath(item.value ?? "") }
                out.append(URL(fileURLWithPath: value).standardizedFileURL)
            }
            return out
        }
        func flag(_ name: String) -> Bool { items.contains { $0.name == name && ["1", "true", "yes"].contains($0.value ?? "") } }
        switch parts.host?.lowercased() {
        case "open":
            let files = try paths("path")
            guard !files.isEmpty else { throw .noFiles }
            guard files.count <= Self.maxFiles else { throw .tooManyFiles(files.count) }
            self = .open(files: files, float: flag("float"), follow: flag("follow"),
                         newWindow: items.contains { $0.name == "window" && $0.value == "new" })
        case "compare":
            let old = try paths("old"), new = try paths("new")
            guard old.count == 1, new.count == 1 else { throw .compareNeedsTwo }
            self = .compare(old: old[0], new: new[0])
        default:
            throw .unknownAction(parts.host ?? "")
        }
    }

    /// RFC 3986 unreserved characters and `/` stay; every other byte of the UTF-8 path is %XX.
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Why a `vitrine://` URL was not taken. Only the app's log shows these, so they stay English.
enum RequestError: Error, Equatable, CustomStringConvertible {
    case notVitrine, noFiles, compareNeedsTwo
    case relativePath(String)
    case tooManyFiles(Int)
    case unknownAction(String)

    var description: String {
        switch self {
        case .notVitrine: return "not a vitrine:// request"
        case .noFiles: return "no files named"
        case .compareNeedsTwo: return "compare takes exactly two files"
        case .relativePath(let p): return "not an absolute path: \(p)"
        case .tooManyFiles(let n): return "\(n) files is more than the \(VitrineRequest.maxFiles) one request may open"
        case .unknownAction(let a): return "unknown action: \(a)"
        }
    }
}

// MARK: Command-line arguments

/// What the `vitrine` command was asked, before any file is checked: a request for the app, help, the version, or
/// a usage error with its message. Pure, so the tests can run every form without starting a process.
enum CommandLineInvocation: Equatable {
    case request(VitrineRequest, background: Bool)
    case help
    case version
    case usageError(String)
    /// A command the design names (`describe`, `render`) that this build does not have yet.
    case notBuilt(String)
    /// `vitrine mcp`: serve the Claude connector over stdio (X-9, G-22).
    case mcp

    static var usage: String {
        String(localized: """
        usage: vitrine <file>…                      open files as tabs in the Vitrine window
               vitrine open [options] <file>…       the same, with options
               vitrine compare <old> <new>          compare two files side by side
               vitrine --compare <old> <new>        the same
               vitrine mcp                          serve the Claude connector (MCP over stdio)

        options for open:
          --float        open each file in its own small window, kept on top
          --follow       stay on the newest lines of a growing file (not in this build yet;
                         an open file already reloads when it changes)
          --new-window   open the files in a new window instead of the frontmost one
          -g, --background   leave Vitrine behind the app you are in
          --             everything after this is a file name

        Vitrine shows files; it never changes them.
        """, bundle: CommandLineText.bundle,
        comment: "`vitrine --help`. Translate the descriptions only: keep the command, its words (open, compare), the options and <file> placeholders as written, and keep the columns lined up")
    }

    /// The design's later commands; named so `vitrine describe x` says what it is instead of trying to open a file
    /// called "describe".
    static let notBuiltCommands: Set<String> = ["describe", "render"]

    /// `arguments` excludes the program name. `cwd` resolves relative file names (the app has no shell directory).
    static func parse(_ arguments: [String], cwd: URL) -> CommandLineInvocation {
        var args = arguments[...]
        guard let first = args.first else { return .help }
        var verb = "open"
        switch first {
        case "-h", "--help", "help": return .help
        case "--version", "version": return .version
        case "open": verb = "open"; args = args.dropFirst()
        case "compare", "--compare": verb = "compare"; args = args.dropFirst()
        case "mcp":
            return args.count == 1 ? .mcp
                : .usageError(String(localized: "mcp takes no arguments", bundle: CommandLineText.bundle, comment: "`vitrine` usage error; keep the command word mcp"))
        default:
            if notBuiltCommands.contains(first) { return .notBuilt(first) }
        }
        var float = false, follow = false, newWindow = false, background = false
        var files: [URL] = []
        var onlyFiles = false
        for arg in args {
            if !onlyFiles, arg.hasPrefix("-"), arg != "-" {
                switch (verb, arg) {
                case (_, "--"): onlyFiles = true
                case (_, "-g"), (_, "--background"): background = true
                case ("open", "--float"): float = true
                case ("open", "--follow"): follow = true
                case ("open", "--new-window"): newWindow = true
                case (_, "-h"), (_, "--help"): return .help
                default:
                    return .usageError(String(localized: "unknown option \(arg) for \(verb)", bundle: CommandLineText.bundle,
                                              comment: "`vitrine` usage error; the option as typed, then the command word (open, compare)"))
                }
                continue
            }
            let path = (arg as NSString).expandingTildeInPath
            files.append(URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL.absoluteURL)
        }
        switch verb {
        case "compare":
            let count = files.count
            guard count == 2 else {
                return .usageError(String(localized: "compare takes exactly two files, got \(count)", bundle: CommandLineText.bundle,
                                          comment: "`vitrine compare` usage error; keep `compare`; how many files were named"))
            }
            return .request(.compare(old: files[0], new: files[1]), background: background)
        default:
            guard !files.isEmpty else {
                return .usageError(String(localized: "name at least one file", bundle: CommandLineText.bundle, comment: "`vitrine` usage error: no file was named"))
            }
            let count = files.count, most = VitrineRequest.maxFiles
            guard count <= most else {
                return .usageError(String(localized: "\(count) files is more than the \(most) one call may open", bundle: CommandLineText.bundle,
                                          comment: "`vitrine` usage error; how many files were named, then the most one call may open"))
            }
            return .request(.open(files: files, float: float, follow: follow, newWindow: newWindow), background: background)
        }
    }
}

// MARK: The command's words

/// What the `vitrine` command prints, marked for translation (S-12, parity H-6). The strings live in this file, which
/// the app compiles too, so Xcode extracts them into the app's String Catalog; the command, a bare tool with no
/// resources of its own, looks them up in the Vitrine.app it belongs to.
enum CommandLineText {
    /// The app the translations are in: `Bundle.main` in the app; in the command (`Vitrine.app/Contents/Helpers/vitrine`,
    /// perhaps reached through a link) the app three folders above the real executable. Anywhere else (tests) the
    /// English text is used.
    static var bundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app", let bundle = Bundle(url: app) { return bundle }
        }
        return Bundle.main
    }

    static func noSuchFile(_ path: String) -> String {
        String(localized: "no such file: \(path)", bundle: bundle, comment: "`vitrine` error; the path as named")
    }

    static var followNotBuilt: String {
        String(localized: "--follow is not in this build yet; the file still reloads when it changes", bundle: bundle,
               comment: "`vitrine` warning; keep --follow as written")
    }

    static func notBuilt(_ command: String) -> String {
        String(localized: "`\(command)` is not in this build of Vitrine yet", bundle: bundle,
               comment: "`vitrine` error; a later command's name (describe, render)")
    }

    static var appNotFound: String {
        String(localized: "cannot find Vitrine.app", bundle: bundle, comment: "`vitrine` error; Vitrine.app is the app's file name")
    }

    /// "Vitrine did not answer within 30s", the wait in the locale's own short unit.
    static func noAnswer(within seconds: Int) -> String {
        let wait = Measurement(value: Double(seconds), unit: UnitDuration.seconds).formatted(.measurement(width: .narrow))
        return String(localized: "Vitrine did not answer within \(wait)", bundle: bundle, comment: "`vitrine` error; how long it waited (30s)")
    }

    static func unreachable(_ reason: String) -> String {
        String(localized: "could not reach Vitrine: \(reason)", bundle: bundle, comment: "`vitrine` error; the system's reason")
    }
}
