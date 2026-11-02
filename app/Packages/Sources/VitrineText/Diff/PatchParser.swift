import Foundation

/// Reads unified diffs in every form a `.patch` or `.diff` file takes: `diff -u` (and `diff -ru` with its `diff`
/// and `Only in` lines), `git diff` with extended headers (renames, copies, similarity, modes, binary markers and
/// `GIT binary patch`), combined merge diffs (`diff --cc`), `git format-patch` emails and mbox series, and
/// `git log -p` / `git show`.
///
/// The input is untrusted: a hunk's counts may lie, a file may be cut off, lines may be megabytes long or not UTF-8.
/// The parser trusts hunk counts while they hold (that is the only way to tell a deleted line `-- x` from a
/// signature or a `--- x` header), reports where they stop holding, and keeps going. It never throws and never
/// traps on input; caps bound memory and time, and past a cap it keeps counting so totals stay exact.
public enum PatchParser {
    public static func parse(_ data: Data, limits: PatchLimits = .default) -> Patch {
        var bytes = [UInt8](data)
        let total = bytes.count
        // A UTF-8 byte-order mark (some Windows editors write one) would hide the first header.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var cut = false
        if bytes.count > limits.maxBytes {
            // Stop at the last newline inside the cap, so the last line read is whole.
            var end = limits.maxBytes
            while end > 0, bytes[end - 1] != 0x0A { end -= 1 }
            bytes.removeSubrange((end == 0 ? limits.maxBytes : end)...)
            cut = true
        }
        let lines = PatchLines(bytes: bytes)
        let build = PatchBuild(limits: limits)
        build.coverage.totalBytes = total
        build.coverage.bytesRead = bytes.count
        if cut { build.issue(.inputCut(readBytes: bytes.count, totalBytes: total), line: lines.count) }
        var scanner = PatchScanner(lines: lines, build: build, lineOffset: 0)
        scanner.scan(0..<lines.count, documentStart: true)
        return build.finish(lines: lines)
    }

    public static func parse(_ text: String, limits: PatchLimits = .default) -> Patch {
        parse(Data(text.utf8), limits: limits)
    }
}

/// Mutable state shared by the scanners of one parse (a decoded email body is scanned by a nested scanner).
final class PatchBuild {
    let limits: PatchLimits
    var files: [DiffFile] = []
    var commits: [PatchCommit] = []
    var issues: [PatchIssue] = []
    var preamble: [String] = []
    var coverage = PatchCoverage()
    var totals = Patch.Totals()
    var currentCommit: Int?
    var detailExhausted = false
    var latin1Lines = 0
    var sawGit = false, sawPlain = false
    var reportedContextDiff = false
    private var reportedLimit = false

    init(limits: PatchLimits) { self.limits = limits }

    func issue(_ kind: PatchIssue.Kind, line: Int) { issues.append(PatchIssue(kind, line: line)) }

    /// Whether the next hunk's lines can be kept; the first refusal records the limit once.
    func canKeepHunk(line: Int) -> Bool {
        if !detailExhausted, coverage.hunksKept >= limits.maxDetailedHunks || coverage.linesKept >= limits.maxDetailedLines
            || files.count >= limits.maxFiles {
            detailExhausted = true
        }
        if detailExhausted, !reportedLimit { reportedLimit = true; issue(.limitReached, line: line) }
        return !detailExhausted
    }

    func canKeepLine(line: Int) -> Bool {
        if coverage.linesKept >= limits.maxDetailedLines {
            detailExhausted = true
            if !reportedLimit { reportedLimit = true; issue(.limitReached, line: line) }
            return false
        }
        return true
    }

    func add(_ file: DiffFile) {
        var file = file
        file.commitIndex = currentCommit
        totals.files += 1
        totals.additions += file.additions
        totals.deletions += file.deletions
        totals.hunks += file.hunkCount
        coverage.filesSeen += 1
        if files.count < limits.maxFiles {
            files.append(file)
            coverage.filesListed += 1
            if !file.isDetailOmitted { coverage.filesWithDetail += 1 }
        } else if !reportedLimit {
            reportedLimit = true
            issue(.limitReached, line: file.patchLine)
        }
    }

    func finish(lines: PatchLines) -> Patch {
        if coverage.truncatedLines > 0 { issue(.longLinesTruncated(count: coverage.truncatedLines), line: 0) }
        if latin1Lines > 0 { issue(.latin1Lines(count: latin1Lines), line: 0) }
        if totals.files == 0 && !issues.contains(where: { $0.severity == .error }) { issue(.noDiffFound, line: 0) }
        let format: Patch.Format
        if commits.contains(where: { $0.source == .email }) { format = .formatPatch }
        else if !commits.isEmpty { format = .gitLog }
        else if sawGit { format = .git }
        else if sawPlain || totals.files > 0 { format = .unified }
        else { format = .none }
        var crlf = 0
        for c in lines.crlf where c { crlf += 1 }
        let stableIssues = issues.enumerated().sorted { a, b in
            a.element.line != b.element.line ? a.element.line < b.element.line : a.offset < b.offset
        }.map(\.element)
        return Patch(format: format, commits: commits, files: files,
                     preamble: preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                     issues: stableIssues, coverage: coverage, totals: totals, crlfLineCount: crlf,
                     lineCount: lines.count)
    }
}

/// Walks one run of lines. `lineOffset` maps its line indices to patch lines for issue positions (nonzero only for
/// a decoded email body, where positions are those of the encoded message).
struct PatchScanner {
    let lines: PatchLines
    let build: PatchBuild
    let lineOffset: Int

    private func patchLine(_ i: Int) -> Int { lineOffset + i + 1 }

    // MARK: - The top level

    mutating func scan(_ range: Range<Int>, documentStart: Bool) {
        var i = range.lowerBound
        let end = range.upperBound
        var filesInSection = 0
        var unrecognizedStart: Int?
        var unrecognizedCount = 0

        func flush() {
            if let s = unrecognizedStart, unrecognizedCount > 0 {
                build.issue(.unrecognizedLines(count: unrecognizedCount), line: patchLine(s))
            }
            unrecognizedStart = nil; unrecognizedCount = 0
        }

        while i < end {
            if isMessageStart(i, end: end, documentStart: documentStart && i == range.lowerBound) {
                flush()
                i = parseEmail(i, end: end)
                filesInSection = 0
                continue
            }
            if isGitLogStart(i, end: end) {
                flush()
                i = parseGitLogHeader(i, end: end)
                filesInSection = 0
                continue
            }
            if let next = parseFileIfStart(i, end: end) {
                flush()
                i = next
                filesInSection += 1
                continue
            }
            if lines.hasPrefix(i, "@@ ") || lines.hasPrefix(i, "@@@ ") {
                flush()
                build.issue(.missingFileHeader, line: patchLine(i))
                var parents = 1
                while lines.byte(i, parents + 1) == 0x40 { parents += 1 }        // "@@@" is two parents
                var file = DiffFile(oldPath: nil, newPath: nil, isCombined: parents > 1, parentCount: max(1, parents),
                                    patchLine: patchLine(i))
                i = parseHunks(i, end: end, file: &file, parents: parents)
                build.add(file)
                filesInSection += 1
                continue
            }
            if isContextDiffStart(i, end: end) {
                flush()
                if !build.reportedContextDiff {
                    build.reportedContextDiff = true
                    build.issue(.contextDiffUnsupported, line: patchLine(i))
                }
                i += 1
                while i < end, !isRecognizedStart(i, end: end) { i += 1 }
                continue
            }
            if isSignature(i, end: end) {
                flush()
                if let c = build.currentCommit, i + 1 < end {
                    let version = lines.string(i + 1).trimmingCharacters(in: .whitespaces)
                    if !version.isEmpty, version.count < 40 { build.commits[c].gitVersion = version }
                }
                i += 2
                continue
            }
            if lines.hasPrefix(i, "Only in ") {
                flush()
                build.issue(.onlyInOneSide(lines.string(i)), line: patchLine(i))
                i += 1
                continue
            }
            if isKnownNoise(i) || lines.isEmpty(i) {
                // Blank lines keep a cover note's paragraphs; leading blanks are trimmed at the end.
                if lines.isEmpty(i), filesInSection == 0, build.currentCommit == nil, !build.preamble.isEmpty {
                    build.preamble.append("")
                }
                i += 1
                continue
            }
            if filesInSection == 0 {
                // Text before the first diff: the document's preamble, or a commit's diffstat (already read as
                // the commit's own, so not kept again).
                if build.currentCommit == nil { build.preamble.append(lines.string(i)) }
            } else {
                if unrecognizedStart == nil { unrecognizedStart = i }
                unrecognizedCount += 1
            }
            i += 1
        }
        flush()
    }

    /// Lines that sit between files in `diff -r`, SVN and CVS output and mean nothing for the preview.
    private func isKnownNoise(_ i: Int) -> Bool {
        (lines.hasPrefix(i, "diff ") && !lines.hasPrefix(i, "diff --git ") && !lines.hasPrefix(i, "diff --cc ")
            && !lines.hasPrefix(i, "diff --combined "))
            || lines.hasPrefix(i, "Index: ") || lines.hasPrefix(i, "=====") || lines.hasPrefix(i, "RCS file: ")
            || lines.hasPrefix(i, "retrieving revision ") || lines.hasPrefix(i, "Common subdirectories: ")
    }

    private func isFileStart(_ i: Int, end: Int) -> Bool {
        lines.hasPrefix(i, "diff --git ") || lines.hasPrefix(i, "diff --cc ") || lines.hasPrefix(i, "diff --combined ")
            || (lines.hasPrefix(i, "--- ") && i + 1 < end && lines.hasPrefix(i + 1, "+++ "))
    }

    private func isRecognizedStart(_ i: Int, end: Int) -> Bool {
        isFileStart(i, end: end) || isBinaryMarker(i) || isGitLogStart(i, end: end)
            || isMessageStart(i, end: end, documentStart: false) || lines.hasPrefix(i, "Index: ")
            || (lines.hasPrefix(i, "diff ") && !lines.hasPrefix(i, "diff --git "))
    }

    private func isBinaryMarker(_ i: Int) -> Bool {
        lines.hasPrefix(i, "Binary files ") && lines.hasSuffix(i, " differ")
    }

    private func isContextDiffStart(_ i: Int, end: Int) -> Bool {
        lines.equals(i, "***************")
            || (lines.hasPrefix(i, "*** ") && i + 1 < end && lines.hasPrefix(i + 1, "--- "))
    }

    /// git's email signature: a line `-- ` then the version.
    private func isSignature(_ i: Int, end: Int) -> Bool {
        lines.equals(i, "-- ") && i + 1 < end && !lines.isEmpty(i + 1) && lines.length(i + 1) < 40
            && (i + 2 >= end || lines.isEmpty(i + 2) || isMessageStart(i + 2, end: end, documentStart: false))
    }

    /// Parses a file when line `i` starts one, returning the index after it.
    private mutating func parseFileIfStart(_ i: Int, end: Int) -> Int? {
        if lines.hasPrefix(i, "diff --git ") { return parseGitFile(i, end: end) }
        if lines.hasPrefix(i, "diff --cc ") || lines.hasPrefix(i, "diff --combined ") { return parseCombinedFile(i, end: end) }
        if lines.hasPrefix(i, "--- "), i + 1 < end, lines.hasPrefix(i + 1, "+++ ") { return parsePlainFile(i, end: end) }
        if isBinaryMarker(i) {
            build.sawPlain = true
            let (old, new) = binaryMarkerNames(lines.string(i))
            var file = DiffFile(oldPath: old.flatMap(Self.devNull), newPath: new.flatMap(Self.devNull),
                                binary: DiffBinary(source: .marker), patchLine: patchLine(i))
            file.isNewFile = old.map { $0 == "/dev/null" } ?? false
            file.isDeletedFile = new.map { $0 == "/dev/null" } ?? false
            build.add(file)
            return i + 1
        }
        return nil
    }

    // MARK: - Emails and commit headers

    private func isHeaderLine(_ i: Int) -> Bool {
        guard !lines.isEmpty(i), let first = lines.byte(i, 0), first != 0x20, first != 0x09 else { return false }
        var k = 0
        while let b = lines.byte(i, k), k < 80 {
            if b == 0x3A { return k > 0 }
            if b <= 32 || b >= 127 { return false }
            k += 1
        }
        return false
    }

    /// An mbox `From ` separator followed by a header, or (at the very start) a bare header block.
    private func isMessageStart(_ i: Int, end: Int, documentStart: Bool) -> Bool {
        if lines.hasPrefix(i, "From "), i + 1 < end, isHeaderLine(i + 1) {
            let token = lines.string(i, from: 5).split(separator: " ", maxSplits: 1).first ?? ""
            return documentStart || PatchMail.isHex(token, length: 7...64) || lines.hasSuffix(i, " 2001")
                || lines.hasPrefix(i + 1, "From:") || lines.hasPrefix(i + 1, "Return-Path:")
        }
        guard documentStart, isHeaderLine(i) else { return false }
        let name = lines.string(i).prefix { $0 != ":" }.lowercased()
        return ["from", "subject", "date", "to", "return-path", "received", "message-id", "mime-version",
                "delivered-to", "reply-to", "in-reply-to", "references"].contains(name)
    }

    private mutating func parseEmail(_ start: Int, end: Int) -> Int {
        var i = start
        var commit = PatchCommit(source: .email)
        if lines.hasPrefix(i, "From ") && !lines.hasPrefix(i, "From:") {
            let token = lines.string(i, from: 5).split(separator: " ", maxSplits: 1).first ?? ""
            if PatchMail.isHex(token, length: 7...64) { commit.hash = String(token) }
            i += 1
        }
        var headers: [(String, String)] = []
        while i < end, !lines.isEmpty(i) {
            let raw = lines.string(i)
            if let first = raw.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + raw.trimmingCharacters(in: .whitespaces)
            } else if let field = PatchMail.headerField(raw) {
                headers.append(field)
            } else {
                break
            }
            i += 1
        }
        if i < end, lines.isEmpty(i) { i += 1 }
        var transfer = ""
        for (name, value) in headers {
            switch name.lowercased() {
            case "from": setAuthor(&commit, PatchMail.decodeEncodedWords(value))
            case "date": commit.dateText = value; commit.date = PatchMail.parseDate(value)
            case "subject": setSubject(&commit, PatchMail.decodeEncodedWords(value))
            case "content-transfer-encoding": transfer = value.lowercased()
            default: break
            }
        }
        build.commits.append(commit)
        build.currentCommit = build.commits.count - 1

        var messageEnd = i
        while messageEnd < end, !isMessageStart(messageEnd, end: end, documentStart: false) { messageEnd += 1 }

        if transfer == "quoted-printable" || transfer == "base64" {
            let raw = lines.joinedBytes(i..<messageEnd)
            let decoded: [UInt8]
            if transfer == "base64" {
                decoded = Data(base64Encoded: Data(raw), options: .ignoreUnknownCharacters).map { [UInt8]($0) } ?? raw
            } else {
                decoded = PatchMail.quotedPrintable(raw)
            }
            build.issue(.transferEncodingDecoded(transfer), line: patchLine(start))
            var nested = PatchScanner(lines: PatchLines(bytes: decoded), build: build, lineOffset: lineOffset + i)
            nested.parseMessageBody(0..<nested.lines.count)
        } else {
            parseMessageBody(i..<messageEnd)
        }
        return messageEnd
    }

    /// The commit message (up to git's `---` line or the first diff), then the diffs.
    private mutating func parseMessageBody(_ range: Range<Int>) {
        guard let c = build.currentCommit else { scan(range, documentStart: false); return }
        var i = range.lowerBound
        let end = range.upperBound
        // In-body headers: git puts `From:` / `Date:` / `Subject:` first when the sender is not the author.
        var inBody = false
        while i < end, isHeaderLine(i), let field = PatchMail.headerField(lines.string(i)),
              ["from", "date", "subject"].contains(field.name.lowercased()) {
            inBody = true
            switch field.name.lowercased() {
            case "from": setAuthor(&build.commits[c], PatchMail.decodeEncodedWords(field.value))
            case "date": build.commits[c].dateText = field.value; build.commits[c].date = PatchMail.parseDate(field.value)
            default: setSubject(&build.commits[c], PatchMail.decodeEncodedWords(field.value))
            }
            i += 1
        }
        if inBody, i < end, lines.isEmpty(i) { i += 1 }
        let bodyStart = i
        var bodyEnd = end
        while i < end {
            if lines.equals(i, "---") { bodyEnd = i; i += 1; break }
            if isFileStart(i, end: end) || lines.hasPrefix(i, "Index: ") { bodyEnd = i; break }
            i += 1
        }
        build.commits[c].body = (bodyStart..<bodyEnd).map { lines.string($0) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        scan(i..<end, documentStart: false)
    }

    private func isGitLogStart(_ i: Int, end: Int) -> Bool {
        guard lines.hasPrefix(i, "commit "), i + 1 < end else { return false }
        let token = lines.string(i, from: 7).split(separator: " ", maxSplits: 1).first ?? ""
        guard PatchMail.isHex(token, length: 7...64) else { return false }
        return lines.hasPrefix(i + 1, "Author:") || lines.hasPrefix(i + 1, "Merge:") || lines.hasPrefix(i + 1, "Date:")
    }

    private mutating func parseGitLogHeader(_ start: Int, end: Int) -> Int {
        var commit = PatchCommit(source: .gitLog)
        commit.hash = lines.string(start, from: 7).split(separator: " ", maxSplits: 1).first.map(String.init)
        var i = start + 1
        while i < end, isHeaderLine(i), let field = PatchMail.headerField(lines.string(i)) {
            switch field.name {
            case "Author": setAuthor(&commit, field.value)
            case "Date", "AuthorDate": commit.dateText = field.value; commit.date = PatchMail.parseDate(field.value)
            case "Merge": commit.mergeParents = field.value.split(separator: " ").map(String.init)
            default: break
            }
            i += 1
        }
        if i < end, lines.isEmpty(i) { i += 1 }
        var message: [String] = []
        while i < end {
            if lines.isEmpty(i) { message.append(""); i += 1; continue }
            guard lines.hasPrefix(i, "    ") else { break }
            message.append(lines.string(i, from: 4))
            i += 1
        }
        let text = message.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        commit.subject = parts.first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        commit.body = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        build.commits.append(commit)
        build.currentCommit = build.commits.count - 1
        return i
    }

    private func setAuthor(_ commit: inout PatchCommit, _ value: String) {
        commit.author = value
        let (name, email) = PatchMail.splitAuthor(value)
        commit.authorName = name; commit.authorEmail = email
    }

    private func setSubject(_ commit: inout PatchCommit, _ value: String) {
        let s = PatchMail.splitSubject(value)
        commit.subject = s.subject; commit.subjectPrefix = s.prefix
        commit.seriesIndex = s.index; commit.seriesTotal = s.total
    }

    // MARK: - Files

    static func devNull(_ path: String) -> String? { path == "/dev/null" ? nil : path }

    private mutating func parseGitFile(_ start: Int, end: Int) -> Int {
        build.sawGit = true
        let names = Self.gitHeaderNames(lines.string(start, from: 11))
        var file = DiffFile(oldPath: names?.old, newPath: names?.new, patchLine: patchLine(start))
        var renameFrom: String?, renameTo: String?
        var i = start + 1
        headers: while i < end {
            let line = lines.string(i)
            func value(_ prefix: String) -> String? { line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil }
            if let v = value("old mode ") { file.oldMode = mode(v, at: i) }
            else if let v = value("new mode ") { file.newMode = mode(v, at: i) }
            else if let v = value("deleted file mode ") { file.isDeletedFile = true; file.oldMode = mode(v, at: i) }
            else if let v = value("new file mode ") { file.isNewFile = true; file.newMode = mode(v, at: i) }
            else if let v = value("similarity index ") { file.similarity = Self.percent(v) }
            else if let v = value("dissimilarity index ") { file.dissimilarity = Self.percent(v) }
            else if let v = value("rename from ") ?? value("rename old ") { file.isRenamed = true; renameFrom = Self.unquote(v) }
            else if let v = value("rename to ") ?? value("rename new ") { file.isRenamed = true; renameTo = Self.unquote(v) }
            else if let v = value("copy from ") { file.isCopied = true; renameFrom = Self.unquote(v) }
            else if let v = value("copy to ") { file.isCopied = true; renameTo = Self.unquote(v) }
            else if let v = value("index ") { readIndex(v, into: &file, at: i) }
            else { break headers }
            i += 1
        }
        if i + 1 < end, lines.hasPrefix(i, "--- "), lines.hasPrefix(i + 1, "+++ ") {
            let old = Self.headerPath(lines.string(i, from: 4))
            let new = Self.headerPath(lines.string(i + 1, from: 4))
            if old == "/dev/null" { file.isNewFile = true }
            if new == "/dev/null" { file.isDeletedFile = true }
            file.oldPath = Self.stripGitPrefix(old, known: renameFrom ?? names?.old) ?? file.oldPath
            file.newPath = Self.stripGitPrefix(new, known: renameTo ?? names?.new) ?? file.newPath
            i += 2
        } else if i < end, isBinaryMarker(i) {
            file.binary = DiffBinary(source: .marker)
            i += 1
        } else if i < end, lines.equals(i, "GIT binary patch") {
            i = parseBinaryPatch(i + 1, end: end, file: &file)
        }
        if let renameFrom { file.oldPath = renameFrom }
        if let renameTo { file.newPath = renameTo }
        i = parseHunks(i, end: end, file: &file, parents: 1)
        if file.isNewFile { file.oldPath = nil }
        if file.isDeletedFile { file.newPath = nil }
        build.add(file)
        return i
    }

    private mutating func parseCombinedFile(_ start: Int, end: Int) -> Int {
        build.sawGit = true
        let prefixLength = lines.hasPrefix(start, "diff --cc ") ? 10 : 16
        let path = Self.unquote(lines.string(start, from: prefixLength))
        var file = DiffFile(oldPath: path, newPath: path, isCombined: true, patchLine: patchLine(start))
        var i = start + 1
        while i < end {
            let line = lines.string(i)
            if line.hasPrefix("index ") {
                let ids = line.dropFirst(6).split(separator: " ").first ?? ""
                let sides = ids.split(separator: ".", omittingEmptySubsequences: true)
                if let parents = sides.first?.split(separator: ","), parents.count >= 2 { file.parentCount = parents.count }
                if let result = sides.last { file.newIndex = String(result) }
            } else if line.hasPrefix("mode ") {
                if let result = line.split(separator: ".").last { file.newMode = DiffFileMode(octal: result) }
            } else if line.hasPrefix("new file mode ") {
                file.isNewFile = true; file.newMode = DiffFileMode(octal: line.dropFirst(14))
            } else if line.hasPrefix("deleted file mode ") {
                file.isDeletedFile = true
            } else {
                break
            }
            i += 1
        }
        if i + 1 < end, lines.hasPrefix(i, "--- "), lines.hasPrefix(i + 1, "+++ ") {
            let new = Self.headerPath(lines.string(i + 1, from: 4))
            if new != "/dev/null", let stripped = Self.stripGitPrefix(new, known: path) { file.newPath = stripped }
            i += 2
        } else if i < end, isBinaryMarker(i) {
            file.binary = DiffBinary(source: .marker)
            i += 1
        }
        // The hunk header says how many parents there are (`@@@` for two); it wins over the index line.
        if i < end, lines.hasPrefix(i, "@@") {
            var ats = 0
            while lines.byte(i, ats) == 0x40 { ats += 1 }
            if ats >= 3 { file.parentCount = ats - 1 }
        }
        file.parentCount = max(2, file.parentCount)
        build.issue(.combinedDiff(parents: file.parentCount), line: patchLine(start))
        i = parseHunks(i, end: end, file: &file, parents: file.parentCount)
        if file.isNewFile { file.oldPath = nil }
        build.add(file)
        return i
    }

    private mutating func parsePlainFile(_ start: Int, end: Int) -> Int {
        build.sawPlain = true
        let oldField = lines.string(start, from: 4)
        let newField = lines.string(start + 1, from: 4)
        var old = Self.headerPath(oldField), new = Self.headerPath(newField)
        // Many tools (Mercurial, git without its `diff --git` line, review sites) write `a/` and `b/` prefixes in
        // plain diffs. Both sides carrying them (or /dev/null) is the signal, as `patch -p1` assumes.
        if old.hasPrefix("a/") || old == "/dev/null", new.hasPrefix("b/") || new == "/dev/null", old != new {
            if old != "/dev/null" { old = String(old.dropFirst(2)) }
            if new != "/dev/null" { new = String(new.dropFirst(2)) }
        }
        var file = DiffFile(oldPath: Self.devNull(old), newPath: Self.devNull(new), patchLine: patchLine(start))
        file.isNewFile = old == "/dev/null"
        file.isDeletedFile = new == "/dev/null"
        let i = parseHunks(start + 2, end: end, file: &file, parents: 1)
        // `diff -N` writes the missing side with an epoch timestamp and a `-0,0` (or `+0,0`) range.
        if !file.isNewFile, file.hunkCount == 1, Self.isEpoch(oldField), file.deletions == 0,
           file.hunks.first.map({ $0.oldStart == 0 && $0.oldCount == 0 }) ?? true {
            file.isNewFile = true
        }
        if !file.isDeletedFile, !file.isNewFile, file.hunkCount == 1, Self.isEpoch(newField), file.additions == 0,
           file.hunks.first.map({ $0.newStart == 0 && $0.newCount == 0 }) ?? true {
            file.isDeletedFile = true
        }
        if file.isNewFile { file.oldPath = nil }
        if file.isDeletedFile { file.newPath = nil }
        build.add(file)
        return i
    }

    private func mode(_ text: String, at i: Int) -> DiffFileMode? {
        if let m = DiffFileMode(octal: text) { return m }
        build.issue(.invalidMode(String(text.prefix(20))), line: patchLine(i))
        return nil
    }

    private func readIndex(_ value: String, into file: inout DiffFile, at i: Int) {
        let parts = value.split(separator: " ")
        guard let ids = parts.first else { return }
        let sides = ids.components(separatedBy: "..")
        if sides.count == 2 {
            if !sides[0].isEmpty, PatchMail.isHex(Substring(sides[0]), length: 4...64) { file.oldIndex = sides[0] }
            if !sides[1].isEmpty, PatchMail.isHex(Substring(sides[1]), length: 4...64) { file.newIndex = sides[1] }
        }
        if parts.count > 1, let m = mode(String(parts[1]), at: i) {
            if file.oldMode == nil { file.oldMode = m }
            if file.newMode == nil { file.newMode = m }
        }
    }

    /// `GIT binary patch` then a forward block and an optional reverse block, each `literal N` or `delta N`
    /// followed by base-85 lines and a blank line. Sizes are read; data is skipped.
    private mutating func parseBinaryPatch(_ start: Int, end: Int, file: inout DiffFile) -> Int {
        var binary = DiffBinary(source: .gitBinaryPatch)
        var i = start
        for block in 0..<2 {
            guard i < end else { break }
            let header = lines.string(i)
            let method: DiffBinary.Method
            if header.hasPrefix("literal ") { method = .literal }
            else if header.hasPrefix("delta ") { method = .delta }
            else { break }
            let size = Int(header.split(separator: " ").last ?? "").flatMap { $0 >= 0 ? $0 : nil }
            if block == 0 {
                binary.forward = method
                if method == .literal { binary.newSize = size }
            } else {
                binary.reverse = method
                if method == .literal { binary.oldSize = size }
            }
            i += 1
            while i < end, let first = lines.byte(i, 0), (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A) {
                i += 1
            }
            if i < end, lines.isEmpty(i) { i += 1 }
        }
        if file.isNewFile { binary.oldSize = binary.oldSize ?? 0 }
        if file.isDeletedFile { binary.newSize = binary.newSize ?? 0 }
        file.binary = binary
        build.issue(.binaryNotDecoded, line: patchLine(start - 1))
        return i
    }

    // MARK: - Hunks

    private mutating func parseHunks(_ start: Int, end: Int, file: inout DiffFile, parents: Int) -> Int {
        var i = start
        var hunkCount = 0, additions = 0, deletions = 0
        var omitted = false
        while i < end, lines.hasPrefix(i, "@@") {
            let result = parseHunk(i, end: end, parents: parents)
            i = result.next
            guard let counted = result.counted else { continue }
            hunkCount += 1
            additions += counted.additions
            deletions += counted.deletions
            if let hunk = result.hunk { file.hunks.append(hunk) }
            if !result.complete { omitted = true }
        }
        file.hunkCount += hunkCount
        file.additions += additions
        file.deletions += deletions
        file.isDetailOmitted = file.isDetailOmitted || omitted
        return i
    }

    private struct HunkResult {
        var next: Int
        var hunk: DiffHunk?
        var counted: (additions: Int, deletions: Int)?
        /// Every line of the hunk was kept.
        var complete: Bool
    }

    private mutating func parseHunk(_ start: Int, end: Int, parents: Int) -> HunkResult {
        guard let header = Self.hunkHeader(lines.string(start), parents: parents) else {
            var i = start + 1
            var skipped = 0
            while i < end, let b = lines.byte(i, 0), b == 0x20 || b == 0x2B || b == 0x2D || b == 0x5C,
                  !isFileStart(i, end: end), !isSignature(i, end: end) {
                i += 1; skipped += 1
            }
            build.issue(.badHunkHeader(skippedLines: skipped), line: patchLine(start))
            return HunkResult(next: i, hunk: nil, counted: nil, complete: true)
        }
        build.coverage.hunksSeen += 1
        let keep = build.canKeepHunk(line: patchLine(start))
        var hunk = header
        if keep { build.coverage.hunksKept += 1 }
        var complete = keep

        var remainingOld = parents == 1 ? [header.oldCount] : header.parentRanges.map(\.count)
        var remainingNew = header.newCount
        var oldNumber = header.oldStart, newNumber = header.newStart
        var foundOld = 0, foundNew = 0, additions = 0, deletions = 0, extra = 0
        var lastKind: DiffLine.Kind?
        var i = start + 1
        var short = false

        while i < end {
            let satisfied = remainingNew <= 0 && remainingOld.allSatisfy { $0 <= 0 }
            let first = lines.byte(i, 0)
            if first == 0x5C {                                       // "\ No newline at end of file"
                if lastKind == nil { build.issue(.orphanNoNewlineMarker, line: patchLine(i)) }
                if keep, !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].ending = .none }
                i += 1
                continue
            }
            if satisfied {
                guard let b = first, b == 0x20 || b == 0x2B || b == 0x2D,
                      !isFileStart(i, end: end), !lines.equals(i, "-- "),
                      markersValid(i, parents: parents) else { break }
                extra += 1
            } else if first == nil {
                // An empty line where a context line is due: mailers strip the lone space. git apply accepts it.
                guard parents == 1 else { short = true; break }
            } else if !markersValid(i, parents: parents) {
                short = true
                break
            }

            let kind: DiffLine.Kind
            var markers: String?
            if parents == 1 {
                switch first {
                case 0x2B: kind = .added
                case 0x2D: kind = .deleted
                default: kind = .context
                }
                if kind != .added { remainingOld[0] -= 1 }
                if kind != .deleted { remainingNew -= 1 }
            } else {
                var plus = false, minus = false
                var columns = [UInt8]()
                for p in 0..<parents {
                    let b = lines.byte(i, p) ?? 0x20
                    columns.append(b)
                    if b == 0x2B { plus = true } else if b == 0x2D { minus = true }
                }
                // A removed line is in the parents marked `-`; any other line is in the parents marked ` `.
                for p in 0..<parents where minus ? columns[p] == 0x2D : columns[p] == 0x20 { remainingOld[p] -= 1 }
                kind = minus ? .deleted : plus ? .added : .context
                if kind != .deleted { remainingNew -= 1 }
                markers = String(decoding: columns, as: UTF8.self)
            }
            if kind != .added { foundOld += 1 }
            if kind != .deleted { foundNew += 1 }
            if kind == .added { additions += 1 } else if kind == .deleted { deletions += 1 }
            build.coverage.linesSeen += 1
            if keep {
                if build.canKeepLine(line: patchLine(i)) {
                    let decoded = lines.text(i, from: parents, maxBytes: build.limits.maxLineBytes)
                    if decoded.truncated { build.coverage.truncatedLines += 1 }
                    if decoded.latin1 { build.latin1Lines += 1 }
                    hunk.lines.append(DiffLine(
                        kind: kind, text: decoded.text,
                        oldNumber: kind == .added || parents > 1 ? nil : oldNumber,
                        newNumber: kind == .deleted ? nil : newNumber,
                        ending: lines.crlf[i] ? .crlf : .lf, isTruncated: decoded.truncated, combinedMarkers: markers))
                    build.coverage.linesKept += 1
                } else {
                    complete = false
                }
            }
            if kind != .added { oldNumber += 1 }
            if kind != .deleted { newNumber += 1 }
            lastKind = kind
            i += 1
        }
        if !short, i >= end, remainingNew > 0 || remainingOld.contains(where: { $0 > 0 }) { short = true }
        if short {
            hunk.isShort = true
            let declaredOld = parents == 1 ? header.oldCount : (header.parentRanges.first?.count ?? 0)
            build.issue(.hunkTooShort(declaredOld: declaredOld, declaredNew: header.newCount,
                                      foundOld: parents == 1 ? foundOld : declaredOld - (remainingOld.first ?? 0),
                                      foundNew: foundNew), line: patchLine(start))
            if i >= end { build.issue(.truncated, line: patchLine(max(start, end - 1))) }
        }
        if extra > 0 {
            hunk.isLong = true
            build.issue(.hunkTooLong(extraLines: extra), line: patchLine(start))
        }
        return HunkResult(next: i, hunk: keep ? hunk : nil, counted: (additions, deletions), complete: complete)
    }

    /// The first `parents` bytes of a hunk line are each a space, `+` or `-`.
    private func markersValid(_ i: Int, parents: Int) -> Bool {
        if parents == 1 {
            guard let b = lines.byte(i, 0) else { return true }
            return b == 0x20 || b == 0x2B || b == 0x2D
        }
        guard lines.length(i) >= parents else { return false }
        var plus = false, minus = false
        for p in 0..<parents {
            guard let b = lines.byte(i, p) else { return false }
            if b == 0x2B { plus = true } else if b == 0x2D { minus = true } else if b != 0x20 { return false }
        }
        return !(plus && minus)
    }

    // MARK: - Header text

    /// `@@ -a[,b] +c[,d] @@ section`, or with `parents + 1` at-signs and one `-` range per parent. Numbers are
    /// limited to nine digits so arithmetic on them cannot overflow.
    static func hunkHeader(_ line: String, parents: Int) -> DiffHunk? {
        let ats = String(repeating: "@", count: parents + 1)
        guard line.hasPrefix(ats + " ") else { return nil }
        var rest = Substring(line.dropFirst(ats.count + 1))
        guard let close = rest.range(of: " " + ats) else { return nil }
        let ranges = rest[..<close.lowerBound].split(separator: " ")
        rest = rest[close.upperBound...]
        let section = rest.hasPrefix(" ") ? String(rest.dropFirst()) : (rest.isEmpty ? nil : String(rest))
        guard ranges.count == parents + 1 else { return nil }
        func parse(_ token: Substring, sign: Character) -> DiffHunk.ClosedRangeCount? {
            guard token.first == sign else { return nil }
            let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }),
                  let start = Int(parts[0]) else { return nil }
            let count = parts.count == 2 ? Int(parts[1]) ?? 1 : 1
            return .init(start: start, count: count)
        }
        var olds: [DiffHunk.ClosedRangeCount] = []
        for token in ranges.dropLast() {
            guard let r = parse(token, sign: "-") else { return nil }
            olds.append(r)
        }
        guard let new = parse(ranges[ranges.count - 1], sign: "+"), let firstOld = olds.first else { return nil }
        return DiffHunk(oldStart: firstOld.start, oldCount: firstOld.count, newStart: new.start, newCount: new.count,
                        section: section.flatMap { $0.isEmpty ? nil : $0 },
                        parentRanges: parents > 1 ? olds : [])
    }

    /// The path in a `---`/`+++` line: unquoted, without the tab and timestamp `diff -u` (and git, for names with
    /// spaces) put after it.
    static func headerPath(_ field: String) -> String {
        if field.hasPrefix("\"") { return unquote(field) }
        let path = field.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? field
        return path.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    private static func isEpoch(_ field: String) -> Bool {
        guard let tab = field.firstIndex(of: "\t") else { return false }
        let stamp = field[field.index(after: tab)...]
        return stamp.hasPrefix("1970-01-01") || stamp.hasPrefix("1969-12-31") || stamp.contains("Jan  1 00:00:00 1970")
            || stamp.contains("Dec 31 ") && stamp.contains(" 1969")
    }

    /// git's `a/` and `b/` (or the mnemonic `i/ w/ c/ o/`) prefixes. When the `diff --git` line gave the name, a
    /// path equal to it (or to it under any one-component prefix) is that name; otherwise a one-letter prefix is
    /// dropped.
    static func stripGitPrefix(_ path: String, known: String?) -> String? {
        if path == "/dev/null" { return nil }
        if let known {
            if path == known { return known }
            if let slash = path.firstIndex(of: "/"), path[path.index(after: slash)...] == known { return known }
        }
        if let slash = path.firstIndex(of: "/"), path.distance(from: path.startIndex, to: slash) == 1 {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    /// The two names in `diff --git a/x b/x`. Names with spaces are ambiguous on this line; git resolves it by the
    /// two names being equal (no rename), and so does this, falling back to the ` b/` split for renames.
    static func gitHeaderNames(_ rest: String) -> (old: String, new: String)? {
        func strip(_ a: String, _ b: String) -> (String, String) {
            let pa = a.firstIndex(of: "/").map { a.distance(from: a.startIndex, to: $0) == 1 } ?? false
            let pb = b.firstIndex(of: "/").map { b.distance(from: b.startIndex, to: $0) == 1 } ?? false
            return pa && pb ? (String(a.dropFirst(2)), String(b.dropFirst(2))) : (a, b)
        }
        if rest.hasPrefix("\"") {
            guard let (old, after) = quotedToken(Substring(rest)) else { return nil }
            let tail = after.drop { $0 == " " }
            let new = tail.hasPrefix("\"") ? quotedToken(tail).map { $0.0 } ?? String(tail) : String(tail)
            return strip(old, new)
        }
        if let q = rest.range(of: " \"") {
            let old = String(rest[..<q.lowerBound])
            let new = quotedToken(rest[rest.index(after: q.lowerBound)...]).map { $0.0 } ?? ""
            return strip(old, new)
        }
        let chars = Array(rest)
        if chars.count % 2 == 1, chars[chars.count / 2] == " " {
            let a = String(chars[..<(chars.count / 2)]), b = String(chars[(chars.count / 2 + 1)...])
            if a == b { return (a, b) }
            let (sa, sb) = strip(a, b)
            if sa == sb { return (sa, sb) }
        }
        if let split = rest.range(of: " b/", options: .backwards) {
            return strip(String(rest[..<split.lowerBound]), String(rest[rest.index(after: split.lowerBound)...]))
        }
        guard let space = rest.firstIndex(of: " ") else { return nil }
        return strip(String(rest[..<space]), String(rest[rest.index(after: space)...]))
    }

    /// git's C-style quoting: `"caf\303\251 menu.txt"` → `café menu.txt`. Unquoted input comes back as is.
    static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\"") else { return text }
        return quotedToken(Substring(text))?.0 ?? text
    }

    private static func quotedToken(_ s: Substring) -> (String, Substring)? {
        guard s.first == "\"" else { return nil }
        var bytes: [UInt8] = []
        let utf8 = Array(s.utf8)
        var i = 1
        while i < utf8.count {
            let b = utf8[i]
            if b == 0x22 {
                let restIndex = s.utf8.index(s.utf8.startIndex, offsetBy: i + 1)
                return (decodePathBytes(bytes), s[restIndex...])
            }
            if b == 0x5C, i + 1 < utf8.count {
                let n = utf8[i + 1]
                switch n {
                case 0x6E: bytes.append(0x0A); i += 2
                case 0x74: bytes.append(0x09); i += 2
                case 0x72: bytes.append(0x0D); i += 2
                case 0x61: bytes.append(0x07); i += 2
                case 0x62: bytes.append(0x08); i += 2
                case 0x66: bytes.append(0x0C); i += 2
                case 0x76: bytes.append(0x0B); i += 2
                case 0x30...0x37:
                    var value = 0, k = i + 1
                    while k < utf8.count, k < i + 4, (0x30...0x37).contains(utf8[k]) { value = value * 8 + Int(utf8[k] - 0x30); k += 1 }
                    bytes.append(UInt8(truncatingIfNeeded: value)); i = k
                default: bytes.append(n); i += 2
                }
                continue
            }
            bytes.append(b)
            i += 1
        }
        return nil
    }

    private static func decodePathBytes(_ bytes: [UInt8]) -> String {
        String(validating: bytes, as: UTF8.self) ?? String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    static func percent(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces).dropLast(text.hasSuffix("%") ? 1 : 0)
        guard digits.count <= 3, let v = Int(digits), (0...100).contains(v) else { return nil }
        return v
    }

    /// `Binary files a/x and b/x differ` → the two names, prefixes kept (stripped by the caller for git).
    private func binaryMarkerNames(_ line: String) -> (String?, String?) {
        let inner = line.dropFirst("Binary files ".count).dropLast(" differ".count)
        guard let and = inner.range(of: " and ") else { return (nil, nil) }
        return (String(inner[..<and.lowerBound]), String(inner[and.upperBound...]))
    }
}
