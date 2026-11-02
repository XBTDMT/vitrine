import Foundation

/// What a Dockerfile or Containerfile builds: its stages (`FROM … AS`), each base image and whether a digest pins
/// it, how many of each instruction it has, the final stage's `USER`, its exposed ports, and warnings for a final
/// image that runs as root, `ADD` from a URL, and `curl … | sh` style downloads piped into a shell.
/// roadmap: S-22
public struct DockerfileSummary: Sendable, Equatable {
    /// One `FROM`. roadmap: S-22
    public struct Stage: Sendable, Equatable {
        /// The `AS` name, when given.
        public var name: String?
        /// The base as written (`node:22-alpine`, `builder`, `scratch`, `${BASE}`).
        public var base: String
        /// The base parsed as an image; nil when it is an earlier stage or `scratch`.
        public var image: InfraImage?
        /// The base is an earlier stage of this file.
        public var fromStage: Bool
        public var platform: String?
        /// 1-based line of the `FROM`.
        public var line: Int

        public init(name: String?, base: String, image: InfraImage?, fromStage: Bool, platform: String?, line: Int) {
            self.name = name; self.base = base; self.image = image; self.fromStage = fromStage
            self.platform = platform; self.line = line
        }
    }

    public var stages: [Stage]
    public var totalStages: Int
    /// Instruction (upper-case) → count, most first.
    public var instructions: [InfraNameCount]
    /// The last `USER` of the final stage; nil when it sets none (the image then runs as root).
    public var finalUser: String?
    public var exposedPorts: [String]
    /// The final stage has an `ENTRYPOINT` or `CMD`.
    public var hasEntrypoint: Bool
    public var hasHealthcheck: Bool
    public var headline: String
    public var facts: [InfraFact]
    public var warnings: [InfraWarning]
    public var truncated: Bool
}

enum DockerfileReader {
    static let instructionNames: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER",
        "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL",
    ]

    /// One logical instruction: continuation lines joined, heredoc bodies attached.
    struct Instruction {
        var keyword: String
        var arguments: String
        var line: Int
        var heredoc: String = ""
    }

    /// Content alone says Dockerfile: the first instruction is `FROM` (after `ARG`s, comments and parser
    /// directives) and every instruction line starts with a known keyword.
    static func looksLikeDockerfile(_ head: String) -> Bool {
        let (instructions, unknown, _) = parse(head, limit: 400)
        guard unknown == 0, let first = instructions.first(where: { $0.keyword != "ARG" }), first.keyword == "FROM" else { return false }
        return instructions.count >= 2
    }

    static func read(_ text: String, capped: Bool) -> DockerfileSummary? {
        let (instructions, unknown, cut) = parse(text, limit: 200_000)
        guard instructions.contains(where: { $0.keyword == "FROM" }), instructions.count > unknown else { return nil }
        var truncated = capped || cut
        var stages = Capped<DockerfileSummary.Stage>()
        var stageNames: Set<String> = []
        var counts = NameCounter()
        var warnings = WarningList()
        var finalUser: String?, hasEntrypoint = false, hasHealthcheck = false
        var exposed: [String] = []

        for ins in instructions {
            counts.add(ins.keyword)
            switch ins.keyword {
            case "FROM":
                var words = ins.arguments.split(whereSeparator: \.isWhitespace).map(String.init)
                var platform: String?
                while let flag = words.first, flag.hasPrefix("--") {
                    if flag.lowercased().hasPrefix("--platform=") { platform = String(flag.dropFirst("--platform=".count)) }
                    words.removeFirst()
                }
                guard let base = words.first else { continue }
                var name: String?
                if words.count >= 3, words[1].lowercased() == "as" { name = words[2] }
                let fromStage = stageNames.contains(base.lowercased())
                let image = fromStage || base.lowercased() == "scratch" ? nil : InfraImage(base)
                stages.append(.init(name: name, base: InfraText.cut(base, 300), image: image, fromStage: fromStage, platform: platform, line: ins.line))
                if let name { stageNames.insert(name.lowercased()) }
                finalUser = nil; hasEntrypoint = false; hasHealthcheck = false; exposed = []
                if let image, image.floats {
                    let reference = InfraText.cut(base, 120)
                    warnings.add(.caution, .unpinnedImage, String(localized: "Base image \(reference) has no fixed tag or digest, so builds can change under the same name.", bundle: .module, comment: "Infra card warning on a Dockerfile; the argument is the base image reference, kept as written."), subject: lineLabel(ins.line))
                }
            case "USER":
                finalUser = ins.arguments.split(whereSeparator: \.isWhitespace).first.map(String.init)
            case "ENTRYPOINT", "CMD":
                hasEntrypoint = true
            case "HEALTHCHECK":
                hasHealthcheck = !ins.arguments.uppercased().hasPrefix("NONE")
            case "EXPOSE":
                for port in ins.arguments.split(whereSeparator: \.isWhitespace) where exposed.count < 200 { exposed.append(String(port)) }
            case "ADD":
                let words = ins.arguments.split(whereSeparator: \.isWhitespace)
                let checksum = words.contains { $0.lowercased().hasPrefix("--checksum=") }
                if !checksum, words.contains(where: { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }) {
                    warnings.add(.caution, .remoteAdd, String(localized: "ADD downloads a URL at build time without a --checksum, so the file is not verified.", bundle: .module, comment: "Infra card warning on a Dockerfile; ADD and --checksum are Dockerfile syntax, kept as written."), subject: lineLabel(ins.line))
                }
            case "RUN":
                if pipesDownloadToShell(ins.arguments + "\n" + ins.heredoc) {
                    warnings.add(.caution, .pipeToShell, String(localized: "Downloads a script and pipes it straight into a shell, running whatever the server sends.", bundle: .module, comment: "Infra card warning on a Dockerfile RUN line such as curl … | sh."), subject: lineLabel(ins.line))
                }
            default: break
            }
        }
        if let lastStage = stages.items.last, lastStage.base.lowercased() != "scratch" || finalUser != nil {
            let user = finalUser?.lowercased()
            if user == nil {
                warnings.add(.caution, .rootUser, String(localized: "The final stage sets no USER, so the container runs as root.", bundle: .module, comment: "Infra card warning on a Dockerfile; USER is a Dockerfile instruction, kept as written."))
            } else if let user, ["root", "0"].contains(user.split(separator: ":").first.map(String.init) ?? user) {
                let written = InfraText.cut(finalUser ?? "", 60)
                warnings.add(.caution, .rootUser, String(localized: "The final stage runs as root (USER \(written)).", bundle: .module, comment: "Infra card warning on a Dockerfile; USER is a Dockerfile instruction, kept as written; the argument is the user as written (root or 0)."))
            }
        }
        truncated = truncated || stages.truncated || warnings.truncated

        var facts: [InfraFact] = [.init(id: "stages", label: String(localized: "Stages", bundle: .module, comment: "Infra card fact label: Dockerfile build stages (FROM lines)."), value: stages.total.formatted())]
        let bases = stages.items.filter { !$0.fromStage }.map(\.base)
        if !bases.isEmpty { facts.append(.init(id: "bases", label: String(localized: "Base images", bundle: .module, comment: "Infra card fact label: the images a Dockerfile builds from."), value: bases.prefix(10).joined(separator: ", "))) }
        let images = stages.items.compactMap(\.image)
        if !images.isEmpty {
            let pinned = images.filter(\.pinnedByDigest).count, all = images.count
            facts.append(.init(id: "digestPinned", label: String(localized: "Pinned by digest", bundle: .module, comment: "Infra card fact label: base images fixed by a sha256 digest."), value: String(localized: "\(pinned) of \(all)", bundle: .module, comment: "Infra card fact value: how many of the base images are pinned by digest, out of all of them.")))
        }
        facts.append(.init(id: "instructions", label: String(localized: "Instructions", bundle: .module, comment: "Infra card fact label: Dockerfile instructions."), value: counts.total.formatted()))
        facts.append(.init(id: "user", label: String(localized: "Final user", bundle: .module, comment: "Infra card fact label: the user the built container runs as."), value: finalUser ?? String(localized: "root (not set)", bundle: .module, comment: "Infra card fact value: the Dockerfile sets no USER, so the container runs as root.")))
        if !exposed.isEmpty { facts.append(.init(id: "exposed", label: String(localized: "Exposed ports", bundle: .module, comment: "Infra card fact label: ports a Dockerfile EXPOSEs."), value: exposed.joined(separator: ", "))) }

        let instructionCount = counts.total
        let headline: String
        if stages.total > 1 {
            headline = String(localized: "Dockerfile · \(stages.total) stages · \(instructionCount) instructions", bundle: .module, comment: "Infra card headline for a multi-stage Dockerfile: stage count and instruction count.")
        } else {
            let base = stages.items.first.map { InfraText.cut($0.base, 60) } ?? ""
            headline = String(localized: "Dockerfile · \(base) · \(instructionCount) instructions", bundle: .module, comment: "Infra card headline for a single-stage Dockerfile: its base image (kept as written) and instruction count.")
        }
        return DockerfileSummary(stages: stages.items, totalStages: stages.total, instructions: counts.sorted, finalUser: finalUser,
                                 exposedPorts: exposed, hasEntrypoint: hasEntrypoint, hasHealthcheck: hasHealthcheck, headline: headline,
                                 facts: facts, warnings: warnings.sorted, truncated: truncated)
    }

    /// "line 12", the subject of a warning about one instruction.
    static func lineLabel(_ line: Int) -> String {
        String(localized: "line \(line)", bundle: .module, comment: "Subject of a Dockerfile warning: the line number of the instruction it is about.")
    }

    /// `curl … | sh`, `wget -qO- … | bash`, `curl … | sudo sh`, `bash <(curl …)`, `sh -c "$(curl …)"`.
    static func pipesDownloadToShell(_ command: String) -> Bool {
        let s = command.lowercased()
        guard s.contains("curl") || s.contains("wget") else { return false }
        let shells = ["sh", "bash", "zsh", "ash", "dash", "ksh", "python", "python3", "perl", "ruby", "node"]
        for segment in s.components(separatedBy: "&&").flatMap({ $0.components(separatedBy: ";") }) {
            let pipes = segment.components(separatedBy: "|").filter { !$0.isEmpty }
            if pipes.count >= 2, pipes.dropLast().contains(where: { $0.contains("curl") || $0.contains("wget") }) {
                for target in pipes.dropFirst() {
                    var words = target.split(whereSeparator: \.isWhitespace).map(String.init)
                    while let w = words.first, ["sudo", "-e", "env", "exec"].contains(w) || w.hasPrefix("-") { words.removeFirst() }
                    if let w = words.first, shells.contains((w as NSString).lastPathComponent) { return true }
                }
            }
            if segment.contains("<(curl") || segment.contains("<(wget") || segment.contains("$(curl") || segment.contains("$(wget") {
                if shells.contains(where: { segment.contains("\($0) ") || segment.contains("\($0) -c") }) { return true }
            }
        }
        return false
    }

    /// Instructions from the text: comments and blank lines dropped, `\` (or the `# escape=` character) continuation
    /// lines joined, `<<EOF` heredoc bodies attached to their instruction. Returns how many instruction lines had an
    /// unknown keyword, and whether `limit` instructions cut the reading short.
    static func parse(_ text: String, limit: Int) -> ([Instruction], unknown: Int, cut: Bool) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        var escape: Character = "\\"
        var out: [Instruction] = []
        var unknown = 0
        var k = 0
        var directivesOpen = true
        while k < lines.count {
            if out.count >= limit { return (out, unknown, true) }
            let line = lines[k]
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            k += 1
            if trimmed.isEmpty { directivesOpen = false; continue }
            if trimmed.hasPrefix("#") {
                if directivesOpen {
                    let directive = trimmed.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                    if directive.hasPrefix("escape="), let c = directive.dropFirst("escape=".count).trimmingCharacters(in: .whitespaces).first {
                        escape = c
                    } else if !directive.contains("=") { directivesOpen = false }
                }
                continue
            }
            directivesOpen = false
            let startLine = k
            var logical = String(trimmed)
            var joined = 0
            while logical.trimmingCharacters(in: .whitespaces).last == escape, k < lines.count, joined < 10_000 {
                logical = String(logical.trimmingCharacters(in: .whitespaces).dropLast())
                // Comment lines inside a continuation are skipped, as BuildKit does.
                while k < lines.count, lines[k].drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") { k += 1 }
                if k < lines.count { logical += " " + lines[k].trimmingCharacters(in: .whitespaces); k += 1 }
                joined += 1
            }
            let keywordEnd = logical.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? logical.endIndex
            let keyword = logical[..<keywordEnd].uppercased()
            let arguments = logical[keywordEnd...].trimmingCharacters(in: .whitespaces)
            guard instructionNames.contains(keyword) else { unknown += 1; continue }
            var ins = Instruction(keyword: keyword, arguments: InfraText.cut(arguments, 64 * 1024), line: startLine)
            // Heredocs: `<<EOF`, `<<-EOF`, `<<"EOF"`; the body runs to a line that is exactly the word.
            for word in heredocWords(arguments) {
                var body: [Substring] = []
                while k < lines.count {
                    let l = lines[k]
                    k += 1
                    if l.trimmingCharacters(in: .whitespaces) == word { break }
                    if body.count < 10_000 { body.append(l) }
                }
                ins.heredoc += body.joined(separator: "\n") + "\n"
            }
            out.append(ins)
        }
        return (out, unknown, false)
    }

    static func heredocWords(_ arguments: String) -> [String] {
        guard arguments.contains("<<") else { return [] }
        var words: [String] = []
        var rest = Substring(arguments)
        while let r = rest.range(of: "<<"), words.count < 8 {
            var after = rest[r.upperBound...]
            if after.hasPrefix("-") { after = after.dropFirst() }
            let word = after.prefix { !$0.isWhitespace && $0 != ">" && $0 != "|" && $0 != ";" && $0 != "&" }
            let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !clean.isEmpty, clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) { words.append(clean) }
            rest = after[word.endIndex...]
        }
        return words
    }
}
