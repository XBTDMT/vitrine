import Foundation

/// The dangerous-script lens (T-3, trust r3-a states 3, 8, 9): shell scripts, `.command` and `.terminal` launchers,
/// AppleScript text, and link files (`.webloc`, `.inetloc`, `.url`). It reads them as text and names what running
/// them would do: download and run code, remove macOS's download warning, run code hidden in base64, start at every
/// login, ask for the password. It runs nothing and decodes nothing into a shell. roadmap: S-20
public enum ScriptLens {
    /// One kind of thing a script does, in the design's words, with the test that shows it on one line.
    struct Rule: Sendable {
        let title: @Sendable () -> String
        /// Words the rule cannot match without (lower case): a line holding none of them is not scanned.
        let keywords: [String]
        let test: @Sendable (ScriptLine) -> Bool

        func matches(_ line: String) -> Bool { mayMatch(line.lowercased()) && test(ScriptLine(line)) }
        /// A literal search on scalars (String's own `contains` compares whole characters, so a combining mark after
        /// a keyword would hide it).
        func mayMatch(_ lowercased: String) -> Bool { keywords.contains { lowercased.range(of: $0, options: .literal) != nil } }
    }

    /// In the design's order: the reason a script is dangerous first.
    ///
    /// Each rule is a hand-written scan, linear in the line, of what a case-insensitive pattern once said (the
    /// pattern is quoted above each test). The patterns had overlapping unbounded quantifiers (`[^\n]*-o\s*\S+[^\n]*`)
    /// and restarted at every `curl` on a line, so one crafted line cost cubic time in the thumbnail and preview
    /// extensions (F43). A scan marks where each part of a pattern can end and carries those marks forward (or knows,
    /// from one backwards pass, what can still follow on the line), walks each run of spaces once, and keeps the
    /// patterns' own line rules: `[^\n]` stops at a line feed (a CRLF script reaches the lens as one line) while `\s`
    /// crosses it. `S16ParsersTrustTests` holds the old patterns as an oracle and compares the scans with them.
    static let rules: [Rule] = [
        Rule(title: { String(localized: "Downloads and runs code", bundle: .module, comment: "Trust lens finding: the script fetches code from the internet and runs it.") },
             keywords: ["curl", "wget", "iex"], test: { l in l.downloadsAndRuns }),
        Rule(title: { String(localized: "Removes the download warning", bundle: .module, comment: "Trust lens finding: the script deletes macOS's quarantine flag so Gatekeeper does not check what was downloaded.") },
             keywords: ["xattr", "spctl"], test: { l in l.removesQuarantine }),
        Rule(title: { String(localized: "Runs hidden code", bundle: .module, comment: "Trust lens finding: the script decodes base64 (or similar) and runs the result.") },
             keywords: ["base64", "openssl", "python"], test: { l in l.runsHiddenCode }),
        Rule(title: { String(localized: "Starts at every login", bundle: .module, comment: "Trust lens finding: the script installs itself to run at login (launch agent, launch daemon, login item, cron).") },
             keywords: ["library/launch", "launchctl", "login item", "crontab", "runatload"], test: { l in l.startsAtLogin }),
        Rule(title: { String(localized: "Asks for your password", bundle: .module, comment: "Trust lens finding: the script shows its own password prompt or feeds a password to sudo.") },
             keywords: ["display dialog", "with hidden answer", "sudo", "dscl", "security"], test: { l in l.asksForPassword }),
    ]

    /// Kinds of file the lens reads as scripts, by extension.
    public static let scriptExtensions: Set<String> = ["sh", "bash", "zsh", "command", "tool", "terminal", "applescript", "ksh", "fish"]
    public static let linkExtensions: Set<String> = ["webloc", "inetloc", "url", "desktop"]

    /// The script's report, or nil when it does none of these things.
    public static func scan(script text: String, launcher: Bool) -> LensReport? {
        var findings: [LensReport.Finding] = []
        for (index, line) in Lines.of(text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") && !trimmed.hasPrefix("#!") { continue }   // a comment says, it does not do
            // Most lines name none of the rules' words: they cost one lower-casing and a few substring searches.
            let lowercased = line.lowercased()
            let candidates = rules.filter { $0.mayMatch(lowercased) }
            if candidates.isEmpty { continue }
            let prepared = ScriptLine(line)
            for rule in candidates where rule.test(prepared) {
                let title = rule.title()
                if findings.contains(where: { $0.title == title }) { continue }
                findings.append(.init(title: title, line: index + 1, detail: quote(trimmed), level: .danger))
            }
        }
        guard !findings.isEmpty else { return nil }
        findings.sort { a, b in order(a.title) < order(b.title) }
        return LensReport(level: .danger, headline: headline(findings.map(\.title), launcher: launcher),
                          chip: String(localized: "Do not run", bundle: .module, comment: "Trust lens verdict chip on a dangerous script."), findings: findings)
    }

    static func order(_ title: String) -> Int { rules.firstIndex { $0.title() == title } ?? rules.count }

    /// "Do not run: it downloads and runs code, removes the download warning and asks for your password" (state 8),
    /// from the first three findings.
    static func headline(_ titles: [String], launcher: Bool) -> String {
        let phrases = titles.prefix(3).map { $0.prefix(1).lowercased() + $0.dropFirst() }
        let list = phrases.formatted(.list(type: .and))
        return String(localized: "Do not run: it \(list)", bundle: .module,
                      comment: "Trust lens headline on a dangerous script; the argument is a list of what it does, lower-case, e.g. 'downloads and runs code and starts at every login'.")
    }

    /// The link a `.webloc` / `.inetloc` / `.url` file opens, and a report when it downloads an installer (state 9).
    public static func scan(link data: Data) -> LensReport? {
        guard let url = linkURL(data) else { return nil }
        let path = (URLComponents(string: url)?.path ?? url).lowercased()
        let installer = ["pkg", "mpkg", "dmg", "zip", "command", "sh", "app", "exe", "msi", "iso", "tar.gz", "tgz"]
            .contains { path.hasSuffix("." + $0) }
        guard installer else { return nil }
        let host = URLComponents(string: url)?.host ?? url
        return LensReport(level: .caution,
                          headline: String(localized: "Opens a link that downloads an installer, not a page", bundle: .module, comment: "Trust lens headline on a link file whose address is a downloadable installer."),
                          chip: String(localized: "Check before opening", bundle: .module, comment: "Trust lens verdict chip on a suspicious link file."),
                          findings: [.init(title: String(localized: "Downloads an installer", bundle: .module, comment: "Trust lens finding: a link file points straight at an installer download."),
                                           detail: host + (URLComponents(string: url)?.path ?? ""), level: .caution)])
    }

    /// The address in a link file: a property list's `URL`, or an `.url` / `.desktop` file's `URL=` line.
    static func linkURL(_ data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let url = plist["URL"] as? String {
            return url
        }
        let text = String(decoding: data.prefix(64 << 10), as: UTF8.self)
        for line in Lines.of(text) where line.hasPrefix("URL=") { return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func quote(_ line: String) -> String { line.count <= 120 ? line : String(line.prefix(117)) + "…" }
}

/// One script line prepared for the lens's rules: its scalars with ASCII letters folded to lower case (the rules
/// are case-insensitive and every literal in them is ASCII, so folding never changes a position), and which
/// scalars are word characters, for `\b`. Every test below is a single forward pass, or a few, over the line.
/// roadmap: S-16
struct ScriptLine {
    let s: [Unicode.Scalar]
    let word: [Bool]
    var count: Int { s.count }

    init(_ line: String) {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(line.unicodeScalars.count)
        for c in line.unicodeScalars {
            scalars.append((0x41...0x5A).contains(c.value) ? Unicode.Scalar(c.value + 0x20)! : c)
        }
        s = scalars
        word = scalars.map(Self.isWordScalar)
        space = scalars.map { $0.isASCII ? $0 == " " || (0x09...0x0D).contains($0.value) : $0.properties.isWhitespace }
    }

    /// Which scalars are `\s` (Unicode White_Space).
    let space: [Bool]

    /// ICU's `\w`: letters, marks, decimal digits, connector punctuation (`_`), ZWNJ and ZWJ.
    static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
        if c.isASCII { return (0x30...0x39).contains(c.value) || (0x61...0x7A).contains(c.value) || (0x41...0x5A).contains(c.value) || c == "_" }
        if c.value == 0x200C || c.value == 0x200D { return true }
        let p = c.properties
        switch p.generalCategory {
        case .decimalNumber, .connectorPunctuation, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return p.isAlphabetic
        }
    }

    // MARK: Primitives

    func isSpace(_ i: Int) -> Bool { i >= 0 && i < count && space[i] }
    func isWord(_ i: Int) -> Bool { i >= 0 && i < count && word[i] }
    /// `\b` at position `i`.
    func boundary(_ i: Int) -> Bool { isWord(i - 1) != isWord(i) }
    func isASCIILetter(_ i: Int) -> Bool { i < count && (0x61...0x7A).contains(s[i].value) }

    /// Whether `literal` (lower-case ASCII) sits at `i`; its end when it does.
    func literal(_ literal: String, at i: Int) -> Int? {
        guard i >= 0 else { return nil }
        var j = i
        for u in literal.unicodeScalars {
            guard j < count, s[j] == u else { return nil }
            j += 1
        }
        return j
    }

    /// The end of the first of `literals` at `i`.
    func any(_ literals: [String], at i: Int) -> Int? {
        for l in literals { if let end = literal(l, at: i) { return end } }
        return nil
    }

    /// One of `literals` at `i` followed by `\b`; its end.
    func anyThenBoundary(_ literals: [String], at i: Int) -> Int? {
        for l in literals { if let end = literal(l, at: i), boundary(end) { return end } }
        return nil
    }

    /// `\b(word|…)\b` at `i`.
    func wholeWord(_ words: [String], at i: Int) -> Int? { boundary(i) ? anyThenBoundary(words, at: i) : nil }

    /// The index after the run of spaces starting at `i` (`i` itself when there is none).
    func skipSpaces(_ i: Int) -> Int {
        var j = i
        while isSpace(j) { j += 1 }
        return j
    }

    /// `\s+` at `i`: the index after one or more spaces, or nil.
    func spaces(_ i: Int) -> Int? {
        let j = skipSpaces(i)
        return j > i ? j : nil
    }

    /// The first position at or after `from` where `test` holds.
    func first(from: Int = 0, _ test: (Int) -> Int?) -> (start: Int, end: Int)? {
        var i = max(0, from)
        while i <= count {
            if let end = test(i) { return (i, end) }
            i += 1
        }
        return nil
    }

    // MARK: Shared shapes

    static let fetchers = ["curl", "wget"]

    /// `\s*(sudo\s+)?` then one of `interpreters` followed by `\b`, right after a pipe at `i`.
    func pipesInto(_ interpreters: [String], at i: Int) -> Bool {
        let start = skipSpaces(i)
        if anyThenBoundary(interpreters, at: start) != nil { return true }
        if let sudo = literal("sudo", at: start), let after = spaces(sudo) {
            return anyThenBoundary(interpreters, at: after) != nil
        }
        return false
    }

    /// `result[i]`: some position at or after `i`, before the next line feed, passes `test` (the tail `[^\n]*X` of a
    /// pattern). One backwards pass.
    func laterOnLine(_ test: (Int) -> Bool) -> [Bool] {
        var out = [Bool](repeating: false, count: count + 1)
        var i = count - 1
        while i >= 0 {
            out[i] = s[i] != "\n" && (test(i) || out[i + 1])
            i -= 1
        }
        return out
    }

    /// The shape `A[^\n]*B`: an anchor (its end given by `anchor`), then, before any line feed, a position where
    /// `then` holds. Anchors are marked at their ends, so B never starts inside A. One forward pass.
    func onSameLine(after anchor: (Int) -> Int?, _ then: (Int) -> Bool) -> Bool {
        var ends = [Bool](repeating: false, count: count + 1)
        var open = false
        var i = 0
        while i < count {
            if ends[i] { open = true }
            if s[i] == "\n" {
                open = false
            } else {
                if open, then(i) { return true }
                if let end = anchor(i) { ends[end] = true }
            }
            i += 1
        }
        return false
    }


    /// `-[a-z]*X[a-z]*\b` at `i` (X a letter): a dash, then a run of ASCII letters holding X that ends at `\b`.
    func optionCluster(holding letter: Unicode.Scalar, at i: Int) -> Int? {
        guard literal("-", at: i) != nil else { return nil }
        var j = i + 1, holds = false
        while isASCIILetter(j) { if s[j] == letter { holds = true }; j += 1 }
        return holds && boundary(j) ? j : nil
    }

    /// For starts found by `start` (returning where a delimited run begins), whether a run up to the next scalar
    /// in `stops` holds one of `needles`. A run that begins inside one already searched ends at the same stop, so
    /// it is skipped: every scalar is searched once.
    func runAfterStart(_ start: (Int) -> Int?, stops: Set<Unicode.Scalar>, needles: [String]) -> Bool {
        var searchedUntil = -1
        var i = 0
        while i < count {
            guard let runStart = start(i) else { i += 1; continue }
            if runStart >= searchedUntil {
                var j = runStart
                while j < count, !stops.contains(s[j]) {
                    if any(needles, at: j) != nil { return true }
                    j += 1
                }
                searchedUntil = j
            }
            i += 1
        }
        return false
    }

    // MARK: Rules

    /// `\b(curl|wget)\b[^|;&\n]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b`
    /// `| \b(curl|wget)\b[^|;&\n]*\|\s*(python3?|perl|ruby|osascript|node)\b`
    /// `| \b(ba|z)?sh\s+-c\s+"?\$\((curl|wget)\b`
    /// `| \b(curl|wget)\b[^\n]*(-o|--output|-O)\s*\S+[^\n]*(&&|;)\s*(chmod\s+\+x|open|sh|bash)\b`
    /// `| \biex\s*\(?\s*\(?\s*(iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b`
    /// `| do shell script\s+"[^"]*(curl|wget)`
    var downloadsAndRuns: Bool { fetchPipedToInterpreter || shellRunsFetch || fetchSavedThenRun || powershellFetch || appleScriptFetch }

    static let pipeInterpreters = ["bash", "dash", "zsh", "ksh", "sh", "python3", "python", "perl", "ruby", "osascript", "node"]

    /// A fetcher, then the first `|` before any `;`, `&` or line feed, into an interpreter.
    var fetchPipedToInterpreter: Bool {
        var armed = false
        var i = 0
        while i < count {
            if !armed, wholeWord(Self.fetchers, at: i) != nil { armed = true }
            switch s[i] {
            case "|":
                if armed, pipesInto(Self.pipeInterpreters, at: i + 1) { return true }
                armed = false
            case ";", "&", "\n":
                armed = false
            default:
                break
            }
            i += 1
        }
        return false
    }

    /// `sh -c "$(curl …`
    var shellRunsFetch: Bool {
        first { i in
            guard boundary(i), let shell = any(["bash", "zsh", "sh"], at: i), let a = spaces(shell),
                  let c = literal("-c", at: a), var b = spaces(c) else { return nil }
            if literal("\"", at: b) != nil { b += 1 }
            guard let open = literal("$(", at: b) else { return nil }
            return anyThenBoundary(Self.fetchers, at: open)
        } != nil
    }

    /// A fetcher, then on the same line `-o`/`--output`/`-O` (`--output` holds `-o`, so `-o` stands for all three),
    /// then after any spaces (which may cross a line feed) a word, and on that word's line a `&&` or `;` whose
    /// command runs the file. Every `-o` is tried; whether a running separator follows on a line is known for every
    /// position from one backwards pass.
    var fetchSavedThenRun: Bool {
        let runsLater = laterOnLine { i in
            guard let sep = any(["&&", ";"], at: i) else { return false }
            let next = skipSpaces(sep)
            if let chmod = literal("chmod", at: next), let a = spaces(chmod), anyThenBoundary(["+x"], at: a) != nil { return true }
            return anyThenBoundary(["open", "bash", "sh"], at: next) != nil
        }
        var fetched = false                                   // a fetcher earlier on this line
        var i = 0
        while i < count {
            if s[i] == "\n" {
                fetched = false
            } else if !fetched, wholeWord(Self.fetchers, at: i) != nil {
                fetched = true
            } else if fetched, let option = literal("-o", at: i) {
                let argument = skipSpaces(option)             // `\S+` starts at the first non-space
                if argument < count, runsLater[argument + 1] { return true }
            }
            i += 1
        }
        return false
    }

    /// `iex (iwr …)`: the spaces and up to two parentheses are taken greedily, which is the only way they can match.
    var powershellFetch: Bool {
        first { i in
            guard boundary(i), let iex = literal("iex", at: i) else { return nil }
            var j = skipSpaces(iex)
            if literal("(", at: j) != nil { j = skipSpaces(j + 1) }
            if literal("(", at: j) != nil { j = skipSpaces(j + 1) }
            return anyThenBoundary(["iwr", "irm", "invoke-webrequest", "invoke-restmethod"], at: j)
        } != nil
    }

    /// `do shell script "…curl…`
    var appleScriptFetch: Bool {
        runAfterStart({ i in
            guard let words = literal("do shell script", at: i), let a = spaces(words), let quote = literal("\"", at: a) else { return nil }
            return quote
        }, stops: ["\""], needles: Self.fetchers)
    }

    /// `\bxattr\b[^\n]*\s-[a-z]*d[a-z]*\b[^\n]*com\.apple\.quarantine`
    /// `| \bxattr\s+-[a-z]*c[a-z]*\b`
    /// `| spctl\s+(--master-disable|--global-disable|--add)`
    var removesQuarantine: Bool {
        // xattr, then on its line a space (the line feed itself counts as one) before a `-…d…` option, then the
        // quarantine name on the option's line.
        let quarantineLater = laterOnLine { literal("com.apple.quarantine", at: $0) != nil }
        var sawXattr = false
        var i = 0
        while i < count {
            if sawXattr, isSpace(i), let end = optionCluster(holding: "d", at: i + 1), quarantineLater[end] { return true }
            if s[i] == "\n" {
                sawXattr = false
            } else if !sawXattr, wholeWord(["xattr"], at: i) != nil {
                sawXattr = true
            }
            i += 1
        }
        if first(from: 0, { i in
            guard boundary(i), let x = literal("xattr", at: i), let a = spaces(x) else { return nil }
            return optionCluster(holding: "c", at: a)
        }) != nil { return true }
        return first(from: 0, { i in
            guard let spctl = literal("spctl", at: i), let a = spaces(spctl) else { return nil }
            return any(["--master-disable", "--global-disable", "--add"], at: a)
        }) != nil
    }

    /// `\b(base64|openssl\s+(base64|enc))\b[^\n]*(-d|--decode|-D)\b[^\n]*\|\s*(sudo\s+)?((ba|z)?sh|python3?|perl|ruby|osascript|node)\b`
    /// `| \beval\s+"?\$\([^)]*base64`
    /// `| \bpython3?\s+-c\s+["'][^"']*(b64decode|exec\()`
    var runsHiddenCode: Bool {
        // A decoder (marked where it ends: `openssl` and its subcommand may be split by any spaces), then on that
        // line a decode option (marked where it ends), then on that line a pipe into an interpreter.
        var decoderEnds = [Bool](repeating: false, count: count + 1)
        var i = 0
        while i < count {
            if boundary(i) {
                if let end = anyThenBoundary(["base64"], at: i) {
                    decoderEnds[end] = true
                } else if let openssl = literal("openssl", at: i), let a = spaces(openssl), let end = anyThenBoundary(["base64", "enc"], at: a) {
                    decoderEnds[end] = true
                }
            }
            i += 1
        }
        var optionEnds = [Bool](repeating: false, count: count + 1)
        var decoder = false, option = false
        i = 0
        while i < count {
            if decoderEnds[i] { decoder = true }
            if optionEnds[i] { option = true }
            if s[i] == "\n" {
                decoder = false
                option = false
            } else {
                if option, s[i] == "|", pipesInto(["bash", "zsh", "sh", "python3", "python", "perl", "ruby", "osascript", "node"], at: i + 1) {
                    return true
                }
                if decoder, let end = anyThenBoundary(["--decode", "-d"], at: i) { optionEnds[end] = true }
            }
            i += 1
        }
        if runAfterStart({ i in
            guard boundary(i), let eval = literal("eval", at: i), var a = spaces(eval) else { return nil }
            if literal("\"", at: a) != nil { a += 1 }
            return literal("$(", at: a)
        }, stops: [")"], needles: ["base64"]) { return true }
        return runAfterStart({ i in
            guard boundary(i), var py = literal("python", at: i) else { return nil }
            if literal("3", at: py) != nil { py += 1 }          // `python3?` then `\s+`: a 3 must be taken
            guard let a = spaces(py), let c = literal("-c", at: a), let b = spaces(c),
                  b < count, s[b] == "\"" || s[b] == "'" else { return nil }
            return b + 1
        }, stops: ["\"", "'"], needles: ["b64decode", "exec("])
    }

    /// `Library/Launch(Agents|Daemons)|\blaunchctl\s+(load|bootstrap|submit|enable)\b|login item|\bcrontab\b|RunAtLoad`
    var startsAtLogin: Bool {
        first { i in
            if let end = any(["library/launchagents", "library/launchdaemons", "login item", "runatload"], at: i) { return end }
            if let end = wholeWord(["crontab"], at: i) { return end }
            guard boundary(i), let launchctl = literal("launchctl", at: i), let a = spaces(launchctl) else { return nil }
            return anyThenBoundary(["load", "bootstrap", "submit", "enable"], at: a)
        } != nil
    }

    /// `display dialog[^\n]*(password|passwort|mot de passe)[^\n]*|with hidden answer|\bsudo\s+-S\b`
    /// `| \bdscl\b[^\n]*-authonly|security\s+(find-generic-password|dump-keychain)`
    var asksForPassword: Bool {
        if onSameLine(after: { literal("display dialog", at: $0) }, { any(["password", "passwort", "mot de passe"], at: $0) != nil }) {
            return true
        }
        if onSameLine(after: { wholeWord(["dscl"], at: $0) }, { literal("-authonly", at: $0) != nil }) { return true }
        return first { i in
            if let end = literal("with hidden answer", at: i) { return end }
            if boundary(i), let sudo = literal("sudo", at: i), let a = spaces(sudo), let end = anyThenBoundary(["-s"], at: a) { return end }
            guard let security = literal("security", at: i), let a = spaces(security) else { return nil }
            return any(["find-generic-password", "dump-keychain"], at: a)
        } != nil
    }
}
