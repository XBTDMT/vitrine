import Foundation
import VitrineText

/// Bounds for one prose compare. roadmap: S-7
public struct ProseCompareLimits: Sendable, Equatable {
    /// Top-level Markdown blocks (or plain-text paragraphs) read from each side.
    public var maxBlocks: Int
    /// Wall-clock time for the word diffs; past it, changed blocks show as whole replacements.
    public var timeLimit: Duration
    /// Characters of a block above which it is not word-diffed (shown as a whole replacement).
    public var maxBlockCharacters: Int

    public init(maxBlocks: Int = 5_000, timeLimit: Duration = .seconds(2), maxBlockCharacters: Int = 20_000) {
        self.maxBlocks = max(1, maxBlocks); self.timeLimit = timeLimit; self.maxBlockCharacters = max(1, maxBlockCharacters)
    }

    public static let `default` = ProseCompareLimits()
}

/// Two drafts compared as prose, the way a reader sees them (design/mockups/unified/diff.html, "Two files: rich
/// prose diff"): Markdown is split into rendered blocks, blocks are matched (equal ones by a diff, edited ones by
/// word similarity), and inside an edited block the words are diffed into tracked-change segments. A link whose
/// text stayed but whose target moved is a change, named with its old and new target. roadmap: S-7
public struct ProseComparison: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Equatable, Codable { case markdown, plain }

    public enum BlockKind: String, Sendable, Equatable, Codable {
        case heading, paragraph, listItem, code, quote, table, other
    }

    public enum Mark: String, Sendable, Equatable, Codable { case same, inserted, deleted }

    public enum Status: String, Sendable, Equatable, Codable { case same, changed, added, removed }

    /// A run of text with one mark, in reading order (within a replacement, the deleted words come first).
    public struct Segment: Sendable, Equatable, Codable {
        public var text: String
        public var mark: Mark
    }

    /// A link whose text is in both versions but whose target differs.
    public struct LinkChange: Sendable, Equatable, Codable {
        public var text: String
        public var old: String
        public var new: String
    }

    /// One rendered block, in merged reading order (removed blocks where they stood).
    public struct Block: Sendable, Equatable, Codable {
        public var kind: BlockKind
        /// Heading level (1–6), list nesting (1 for a top-level item), quote nesting; 0 otherwise.
        public var level: Int
        public var segments: [Segment]
        public var status: Status
        public var linkChanges: [LinkChange]
        /// Language of a code block, when given.
        public var language: String?
    }

    /// One entry of the "what changed" list: "1 Title · “: notes that work offline”".
    public struct Item: Sendable, Equatable, Codable {
        /// 1-based.
        public var index: Int
        /// "Title", "Heading", "Intro", "Paragraph", "List", "Link", "Code block", "Quote", "Table", "Block".
        public var title: String
        /// "1 added, 1 removed", "target /3.0 → /3-0", "sentence replaced", "added".
        public var detail: String
        /// Index into `blocks` of the first block the entry covers, for the list to follow the detail.
        public var block: Int
    }

    public var format: Format
    public var blocks: [Block]
    public var changes: [Item]
    /// Words inserted and deleted, in edited, added and removed blocks alike.
    public var insertions: Int
    public var deletions: Int
    public var blocksChanged: Int
    /// "6 insertions and 4 deletions in 6 blocks"; "No differences" when equal.
    public var summary: String
    public var isEqual: Bool
    public var isComplete: Bool
    public var incompleteReason: String?
}

/// The prose compare engine. roadmap: S-7
public enum ProseCompare {
    public static func compare(old: String, new: String, format: ProseComparison.Format = .markdown,
                               limits: ProseCompareLimits = .default) -> ProseComparison {
        var reasons: [String] = []
        let a = ProseBlocks.read(old, format: format, maxBlocks: limits.maxBlocks)
        let b = ProseBlocks.read(new, format: format, maxBlocks: limits.maxBlocks)
        if a.cut { reasons.append(String(localized: "the old file is compared through its first \(limits.maxBlocks.formatted()) blocks", bundle: .module, comment: "Why a prose compare is incomplete; lower-case, no final period.")) }
        if b.cut { reasons.append(String(localized: "the new file is compared through its first \(limits.maxBlocks.formatted()) blocks", bundle: .module, comment: "Why a prose compare is incomplete; lower-case, no final period.")) }

        let oldTokens = a.blocks.map { WordToken.tokenize($0.text) }
        let newTokens = b.blocks.map { WordToken.tokenize($0.text) }
        let steps = Alignment.align(a.blocks.map(\.key), b.blocks.map(\.key), threshold: 0.5) { i, j in
            guard a.blocks[i].kind == b.blocks[j].kind else { return 0 }
            return WordToken.similarity(oldTokens[i], newTokens[j])
        }

        let deadline = Deadline(limits.timeLimit)
        var simplified = false
        var merged: [(block: ProseComparison.Block, source: ProseBlocks.Source, old: ProseBlocks.Source?)] = []
        var insertions = 0, deletions = 0
        for step in steps {
            switch step {
            case .equal(_, let j):
                let s = b.blocks[j]
                merged.append((block(s, [.init(text: s.text, mark: .same)], .same), s, nil))
            case .deleted(let i):
                let s = a.blocks[i]
                deletions += words(oldTokens[i])
                merged.append((block(s, [.init(text: s.text, mark: .deleted)], .removed), s, nil))
            case .inserted(let j):
                let s = b.blocks[j]
                insertions += words(newTokens[j])
                merged.append((block(s, [.init(text: s.text, mark: .inserted)], .added), s, nil))
            case .paired(let i, let j):
                let o = a.blocks[i], n = b.blocks[j]
                var segments: [ProseComparison.Segment]
                if o.text == n.text {
                    segments = [.init(text: n.text, mark: .same)]
                } else if deadline.passed || o.text.count > limits.maxBlockCharacters || n.text.count > limits.maxBlockCharacters {
                    if deadline.passed { simplified = true }
                    segments = [.init(text: o.text, mark: .deleted), .init(text: n.text, mark: .inserted)]
                } else {
                    segments = WordDiff.segments(oldTokens[i], newTokens[j])
                }
                for seg in segments {
                    if seg.mark == .inserted { insertions += words(WordToken.tokenize(seg.text)) }
                    if seg.mark == .deleted { deletions += words(WordToken.tokenize(seg.text)) }
                }
                var result = block(n, segments, .changed)
                result.linkChanges = linkChanges(o.links, n.links)
                merged.append((result, n, o))
            }
        }
        if simplified { reasons.append(String(localized: "the time limit was reached; later edited blocks show as whole replacements", bundle: .module, comment: "Why a prose compare is incomplete; lower-case, no final period.")) }

        let blocks = merged.map(\.block)
        let changes = describe(merged)
        let changed = blocks.filter { $0.status != .same }.count
        let insertionText = insertions == 1 ? String(localized: "1 insertion", bundle: .module, comment: "Count of inserted words in a prose compare.") : String(localized: "\(insertions) insertions", bundle: .module, comment: "Count of inserted words in a prose compare (not 1).")
        let deletionText = deletions == 1 ? String(localized: "1 deletion", bundle: .module, comment: "Count of deleted words in a prose compare.") : String(localized: "\(deletions) deletions", bundle: .module, comment: "Count of deleted words in a prose compare (not 1).")
        let blockText = changed == 1 ? String(localized: "1 block", bundle: .module, comment: "Count of changed blocks (paragraphs, headings, list items) in a prose compare.") : String(localized: "\(changed) blocks", bundle: .module, comment: "Count of changed blocks (paragraphs, headings, list items) in a prose compare (not 1).")
        let summary = changed == 0 ? String(localized: "No differences", bundle: .module, comment: "Compare summary: the two files have no differences.")
            : String(localized: "\(insertionText) and \(deletionText) in \(blockText)", bundle: .module, comment: "Prose compare summary, such as 12 insertions and 3 deletions in 4 blocks.")
        return ProseComparison(format: format, blocks: blocks, changes: changes, insertions: insertions,
                               deletions: deletions, blocksChanged: changed, summary: summary, isEqual: changed == 0,
                               isComplete: reasons.isEmpty, incompleteReason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
    }

    private static func words(_ tokens: [WordToken]) -> Int { tokens.reduce(0) { $0 + ($1.kind == .word ? 1 : 0) } }

    private static func block(_ s: ProseBlocks.Source, _ segments: [ProseComparison.Segment],
                              _ status: ProseComparison.Status) -> ProseComparison.Block {
        .init(kind: s.kind, level: s.level, segments: segments, status: status, linkChanges: [], language: s.language)
    }

    /// Links matched by their text in order; a matched link with another target is a change.
    private static func linkChanges(_ old: [ProseBlocks.Link], _ new: [ProseBlocks.Link]) -> [ProseComparison.LinkChange] {
        var used = Set<Int>()
        var out: [ProseComparison.LinkChange] = []
        for link in new {
            guard let k = old.indices.first(where: { !used.contains($0) && old[$0].text == link.text }) else { continue }
            used.insert(k)
            if old[k].url != link.url { out.append(.init(text: link.text, old: old[k].url, new: link.url)) }
        }
        return out
    }

    // MARK: The "what changed" list

    private static func describe(_ merged: [(block: ProseComparison.Block, source: ProseBlocks.Source,
                                             old: ProseBlocks.Source?)]) -> [ProseComparison.Item] {
        var items: [ProseComparison.Item] = []
        let firstParagraph = merged.firstIndex { $0.block.kind == .paragraph }
        var k = 0
        while k < merged.count {
            let entry = merged[k]
            if entry.block.kind == .listItem {
                // A run of list items (same ones included) is one entry: "1 added, 1 removed, …".
                var end = k
                while end < merged.count, merged[end].block.kind == .listItem { end += 1 }
                let run = merged[k..<end]
                if let first = run.firstIndex(where: { $0.block.status != .same }) {
                    var parts: [String] = []
                    let added = run.filter { $0.block.status == .added }.count
                    let removed = run.filter { $0.block.status == .removed }.count
                    if added > 0 { parts.append(String(localized: "\(added) added", bundle: .module, comment: "Part of a list change in a prose compare: how many items were added.")) }
                    if removed > 0 { parts.append(String(localized: "\(removed) removed", bundle: .module, comment: "Part of a list change in a prose compare: how many items were removed.")) }
                    for item in run where item.block.status == .changed {
                        if let part = detailParts(item.block, old: item.old, new: item.source).first { parts.append(part) }
                    }
                    items.append(.init(index: items.count + 1, title: String(localized: "List", bundle: .module, comment: "Kind of a changed block in a prose compare: a list."), detail: parts.prefix(4).joined(separator: ", "),
                                       block: first))
                }
                k = end
                continue
            }
            defer { k += 1 }
            guard entry.block.status != .same else { continue }
            var title: String
            switch entry.block.kind {
            case .heading: title = entry.block.level == 1 ? String(localized: "Title", bundle: .module, comment: "Kind of a changed block in a prose compare: the top-level heading.") : String(localized: "Heading", bundle: .module, comment: "Kind of a changed block in a prose compare.")
            case .paragraph: title = k == firstParagraph ? String(localized: "Intro", bundle: .module, comment: "Kind of a changed block in a prose compare: the first paragraph.") : String(localized: "Paragraph", bundle: .module, comment: "Kind of a changed block in a prose compare.")
            case .listItem: title = String(localized: "List", bundle: .module, comment: "Kind of a changed block in a prose compare: a list.")
            case .code: title = String(localized: "Code block", bundle: .module, comment: "Kind of a changed block in a prose compare.")
            case .quote: title = String(localized: "Quote", bundle: .module, comment: "Kind of a changed block in a prose compare: a block quote.")
            case .table: title = String(localized: "Table", bundle: .module, comment: "Kind of a changed block in a prose compare.")
            case .other: title = String(localized: "Block", bundle: .module, comment: "Kind of a changed block in a prose compare: any other block.")
            }
            let detail: String
            switch entry.block.status {
            case .added: detail = String(localized: "added", bundle: .module, comment: "What happened to a block in a prose compare.")
            case .removed: detail = String(localized: "removed", bundle: .module, comment: "What happened to a block in a prose compare.")
            default:
                let onlyLinks = entry.block.segments.allSatisfy { $0.mark == .same } && !entry.block.linkChanges.isEmpty
                    && entry.old?.level == entry.source.level
                if onlyLinks { title = String(localized: "Link", bundle: .module, comment: "Kind of a changed block in a prose compare: only a link target changed.") }
                var parts = detailParts(entry.block, old: entry.old, new: entry.source)
                if parts.count == 1, entry.block.segments.contains(where: { $0.mark != .same }),
                   let only = parts.first, isInsertionOnly(entry.block), !Self.sentencePhrases.contains(only) {
                    parts = [String(localized: "“\(only)”", bundle: .module, comment: "Words inserted in a prose compare, quoted; use your language's quotation marks.")]
                }
                detail = parts.isEmpty ? String(localized: "changed", bundle: .module, comment: "What happened to a block in a prose compare.") : parts.prefix(3).joined(separator: ", ")
            }
            items.append(.init(index: items.count + 1, title: title, detail: detail, block: k))
        }
        return items
    }

    /// The phrases for a whole sentence added, removed or replaced, which are never quoted as inserted words.
    private static var sentencePhrases: Set<String> { [sentenceReplaced, sentenceAdded, sentenceRemoved] }
    private static var sentenceReplaced: String { String(localized: "sentence replaced", bundle: .module, comment: "Part of a block change in a prose compare.") }
    private static var sentenceAdded: String { String(localized: "sentence added", bundle: .module, comment: "Part of a block change in a prose compare.") }
    private static var sentenceRemoved: String { String(localized: "sentence removed", bundle: .module, comment: "Part of a block change in a prose compare.") }

    private static func isInsertionOnly(_ block: ProseComparison.Block) -> Bool {
        !block.segments.contains { $0.mark == .deleted } && block.segments.contains { $0.mark == .inserted }
    }

    /// Short phrases for one edited block: inserted words as written, "removed “x”", "sentence replaced",
    /// "target /3.0 → /3-0", "heading level 2 → 3".
    private static func detailParts(_ block: ProseComparison.Block, old: ProseBlocks.Source?,
                                    new: ProseBlocks.Source) -> [String] {
        var parts: [String] = []
        if let old, old.level != new.level, new.kind == .heading {
            parts.append(String(localized: "heading level \(old.level) → \(new.level)", bundle: .module, comment: "Part of a block change in a prose compare: the heading level changed, such as 2 → 3."))
        }
        let segs = block.segments
        var k = 0
        while k < segs.count {
            let seg = segs[k]
            if seg.mark == .deleted, k + 1 < segs.count, segs[k + 1].mark == .inserted {
                let a = phrase(seg.text), b = phrase(segs[k + 1].text)
                if isSentence(a) || isSentence(b) {
                    parts.append(sentenceReplaced)
                } else {
                    parts.append(String(localized: "“\(CompareText.truncate(a, 30))” → “\(CompareText.truncate(b, 30))”", bundle: .module, comment: "Part of a block change in a prose compare: old words → new words, quoted; use your language's quotation marks."))
                }
                k += 2
                continue
            }
            let text = phrase(seg.text)
            if seg.mark == .inserted, !text.isEmpty {
                parts.append(isSentence(text) ? sentenceAdded : CompareText.truncate(text, 40))
            } else if seg.mark == .deleted, !text.isEmpty {
                parts.append(isSentence(text) ? sentenceRemoved
                    : String(localized: "removed “\(CompareText.truncate(text, 30))”", bundle: .module, comment: "Part of a block change in a prose compare: words removed, quoted; use your language's quotation marks."))
            }
            k += 1
        }
        for link in block.linkChanges {
            let (a, b) = shortTargets(link.old, link.new)
            parts.append(String(localized: "target \(a) → \(b)", bundle: .module, comment: "Part of a block change in a prose compare: a link target changed."))
        }
        return parts
    }

    /// Six words or more read as a sentence rather than a phrase.
    private static func isSentence(_ text: String) -> Bool {
        WordToken.tokenize(text).filter { $0.kind == .word }.count >= 6
    }

    /// A phrase as the list shows it: trimmed of spaces and of a dangling comma or semicolon.
    private static func phrase(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ",;".contains(last) { t.removeLast(); t = t.trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// The differing tails of two URLs from the last "/" before they part: "/3.0" and "/3-0".
    static func shortTargets(_ a: String, _ b: String) -> (String, String) {
        let x = Array(a), y = Array(b)
        var common = 0
        while common < x.count, common < y.count, x[common] == y[common] { common += 1 }
        guard common > 0, let slash = x[..<common].lastIndex(of: "/") else { return (a, b) }
        return (String(x[slash...]), String(y[slash...]))
    }
}

/// Word-level segments of one edited block. roadmap: S-7
///
/// A Myers token diff, then a semantic clean-up in the manner of diff-match-patch's: an unchanged run that is no
/// longer than the edits on both sides of it is folded into one replacement, so a rewritten sentence that happens
/// to share "and" and "the" with the old one reads as one sentence replaced, not as confetti.
enum WordDiff {
    /// An unchanged run (`same`) or an edit (`deleted` then `inserted`), as token indices.
    struct Region {
        var same: Range<Int>?
        /// The same run's tokens on the new side.
        var sameNew: Range<Int> = 0..<0
        var deleted: [Int] = []
        var inserted: [Int] = []
    }

    static func segments(_ a: [WordToken], _ b: [WordToken]) -> [ProseComparison.Segment] {
        let result = LineDiff.diff(a.map(\.text), b.map(\.text), algorithm: .myers,
                                   budget: .init(timeLimit: .milliseconds(50), maxElements: 60_000))
        var regions: [Region] = []
        for op in result.ops {
            switch op.kind {
            case .equal: regions.append(Region(same: op.old, sameNew: op.new))
            case .delete, .insert:
                if regions.last == nil || regions[regions.count - 1].same != nil { regions.append(Region()) }
                regions[regions.count - 1].deleted += Array(op.old)
                regions[regions.count - 1].inserted += Array(op.new)
            }
        }
        cleanUp(&regions, a: a, b: b)

        var segments: [ProseComparison.Segment] = []
        func append(_ text: String, _ mark: ProseComparison.Mark) {
            guard !text.isEmpty else { return }
            if let last = segments.last, last.mark == mark { segments[segments.count - 1].text += text } else {
                segments.append(.init(text: text, mark: mark))
            }
        }
        for region in regions {
            if let same = region.same {
                append(same.map { a[$0].text }.joined(), .same)
            } else {
                append(region.deleted.map { a[$0].text }.joined(), .deleted)
                append(region.inserted.map { b[$0].text }.joined(), .inserted)
            }
        }
        return segments
    }

    private static func length(_ indices: some Sequence<Int>, _ tokens: [WordToken]) -> Int {
        indices.reduce(0) { $0 + tokens[$1].text.count }
    }

    /// Folds each unchanged run that is no longer (in characters) than the larger side of the edit before it and of
    /// the edit after it, and runs of only spaces and punctuation between two edits; repeats until stable.
    static func cleanUp(_ regions: inout [Region], a: [WordToken], b: [WordToken]) {
        var changed = true
        while changed {
            changed = false
            var k = 1
            while k + 1 < regions.count {
                guard let same = regions[k].same, regions[k - 1].same == nil, regions[k + 1].same == nil else { k += 1; continue }
                let before = max(length(regions[k - 1].deleted, a), length(regions[k - 1].inserted, b))
                let after = max(length(regions[k + 1].deleted, a), length(regions[k + 1].inserted, b))
                let size = length(same, a)
                let onlyPunctuation = same.allSatisfy { a[$0].kind != .word }
                guard onlyPunctuation || (size <= before && size <= after) else { k += 1; continue }
                var merged = Region()
                merged.deleted = regions[k - 1].deleted + Array(same) + regions[k + 1].deleted
                merged.inserted = regions[k - 1].inserted + Array(regions[k].sameNew) + regions[k + 1].inserted
                regions.replaceSubrange((k - 1)...(k + 1), with: [merged])
                changed = true
            }
        }
    }
}

/// Prose split into the blocks a reader sees. roadmap: S-7
enum ProseBlocks {
    struct Link: Equatable { var text: String; var url: String }

    struct Source {
        var kind: ProseComparison.BlockKind
        var level: Int
        var text: String
        var links: [Link]
        var language: String?
        /// What the block diff matches on: kind, level, text and link targets.
        var key: String { "\(kind.rawValue)\u{1}\(level)\u{1}\(text)\u{1}" + links.map(\.url).joined(separator: "\u{1}") }
    }

    static func read(_ text: String, format: ProseComparison.Format, maxBlocks: Int) -> (blocks: [Source], cut: Bool) {
        switch format {
        case .plain:
            var blocks: [Source] = []
            var current: [Substring] = []
            var cut = false
            func flush() {
                if !current.isEmpty {
                    blocks.append(Source(kind: .paragraph, level: 0, text: current.joined(separator: "\n"), links: []))
                }
                current = []
            }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { flush() } else { current.append(line.hasSuffix("\r") ? line.dropLast() : line) }
                if blocks.count > maxBlocks { cut = true; break }
            }
            flush()
            if blocks.count > maxBlocks { cut = true; blocks = Array(blocks.prefix(maxBlocks)) }
            return (blocks, cut)
        case .markdown:
            let parsed = MarkdownBlocks.parse(text, maxBlocks: maxBlocks + 1)
            let cut = parsed.count > maxBlocks
            var out: [Source] = []
            for block in parsed.prefix(maxBlocks) { flatten(block, quote: 0, list: 0, into: &out) }
            return (out, cut)
        }
    }

    private static func flatten(_ block: MarkdownBlock, quote: Int, list: Int, into out: inout [Source]) {
        switch block {
        case .heading(let level, let inlines):
            out.append(Source(kind: .heading, level: level, text: plain(inlines), links: links(inlines)))
        case .paragraph(let inlines):
            out.append(Source(kind: quote > 0 ? .quote : .paragraph, level: quote, text: plain(inlines), links: links(inlines)))
        case .code(let language, let text):
            out.append(Source(kind: .code, level: 0, text: text, links: [], language: language))
        case .quote(let inner):
            for b in inner { flatten(b, quote: quote + 1, list: list, into: &out) }
        case .alert(let kind, let inner):
            out.append(Source(kind: .quote, level: quote + 1, text: kind, links: []))
            for b in inner { flatten(b, quote: quote + 1, list: list, into: &out) }
        case .list(_, _, let items):
            for item in items {
                var text: [String] = []
                var itemLinks: [Link] = []
                var nested: [MarkdownBlock] = []
                for b in item.blocks {
                    switch b {
                    case .paragraph(let inlines), .heading(_, let inlines):
                        text.append(plain(inlines)); itemLinks += links(inlines)
                    case .list: nested.append(b)
                    case .code(_, let t): text.append(t)
                    default: nested.append(b)
                    }
                }
                let box = item.checked.map { $0 ? "[x] " : "[ ] " } ?? ""
                out.append(Source(kind: .listItem, level: list + 1, text: box + text.joined(separator: " "), links: itemLinks))
                for b in nested { flatten(b, quote: quote, list: list + 1, into: &out) }
            }
        case .table(let rows):
            let text = rows.map { $0.map(plain).joined(separator: " | ") }.joined(separator: "\n")
            out.append(Source(kind: .table, level: 0, text: text, links: rows.flatMap { $0.flatMap(links) }))
        case .rule:
            out.append(Source(kind: .other, level: 0, text: "---", links: []))
        case .html(let html):
            out.append(Source(kind: .other, level: 0, text: html, links: []))
        }
    }

    private static func plain(_ inlines: [MarkdownInline]) -> String { inlines.map(MarkdownBlocks.plain).joined() }

    private static func links(_ inlines: [MarkdownInline]) -> [Link] {
        var out: [Link] = []
        for inline in inlines {
            switch inline {
            case .link(let inner, let url): out.append(Link(text: plain(inner), url: url)); out += links(inner)
            case .emphasis(let x), .strong(let x), .strikethrough(let x): out += links(x)
            default: break
            }
        }
        return out
    }
}
