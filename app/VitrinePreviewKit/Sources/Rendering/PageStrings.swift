import Foundation

/// The words the web previews draw (H-6, S-12). The pages never carry English of their own that people read: each
/// page gets one JSON object of already-localized strings in a data block,
/// `<script type="application/json" id="vt-strings">`, which the page's own script reads (the pages' CSP refuses
/// inline scripts, and a JSON data block is never executed). Every lookup in the pages falls back to English.
///
/// Counted phrases arrive as templates per plural category ({"one": "{n} line …", "other": "{n} lines …"}): each is
/// the localized sentence for a sample count with the number replaced by `{n}`; the page picks one with
/// `Intl.PluralRules` in the strings' language and puts the number back formatted for the person's locale. Named
/// arguments are written `{name}` in the localized text and filled by the page. roadmap: S-12
enum PageStrings {
    typealias Table = [String: Any]

    /// The data block for a page: the table plus the language and locale the page formats with.
    static func block(_ tables: Table...) -> String {
        var all: Table = ["_lang": language, "_locale": Locale.current.identifier(.bcp47)]
        for table in tables { all.merge(table) { _, new in new } }
        let data = (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data("{}".utf8)
        // `<` is escaped, so no string can end or confuse the element.
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        return "<script type=\"application/json\" id=\"vt-strings\">\(json)</script>"
    }

    /// The language the strings are in: the framework's localization in use (plural rules follow it).
    static var language: String { Bundle.previewKit.preferredLocalizations.first ?? "en" }

    /// A counted phrase as one template per plural category. `make` returns the localized sentence for a count.
    static func plural(_ make: (Int) -> String) -> [String: String] {
        var out: [String: String] = [:]
        for (category, sample) in [("one", 1), ("other", 2), ("many", 1_000_000)] {
            let text = make(sample)
            let shown = sample.formatted()
            if let range = text.range(of: shown) {
                out[category] = text.replacingCharacters(in: range, with: "{n}")
            } else {
                out[category] = text
            }
        }
        return out
    }

    // MARK: Shared

    /// Lines folded away from find matches (the code and diff pages).
    private static var linesWithoutMatch: [String: String] {
        plural { String(localized: "\($0) lines without a match", bundle: .previewKit,
                        comment: "A folded run of lines with no find match (code and diff previews).") }
    }

    // MARK: The code page (code-entry.js, appearance.js, log.js)

    static var code: Table {
        [
            "code.loadingLines": String(localized: "Loading lines {from}–{to}", bundle: .previewKit,
                                        comment: "Banner while a huge file's next lines load. Keep {from} and {to}."),
            "code.symbolsIn": String(localized: "Symbols in {file}", bundle: .previewKit,
                                     comment: "Heading of the symbol list in the code view. Keep {file}, the file name."),
            "code.noSymbolsMatch": String(localized: "No symbols match", bundle: .previewKit, comment: "Symbol list: nothing matches the typed text."),
            "code.ln": String(localized: "Ln {line}", bundle: .previewKit, comment: "Short for line number, e.g. 'Ln 42'. Keep {line}."),
            "code.linesWithoutMatch": linesWithoutMatch,
            "code.linesBelowLevel": plural { String(localized: "\($0) lines below {level}", bundle: .previewKit,
                                                    comment: "A folded run of log lines below the chosen level. Keep {level}, a log level word such as warn.") },
            "code.linesAtLevel": plural { String(localized: "\($0) lines at {level} or worse", bundle: .previewKit,
                                                 comment: "Find result in a log: lines at the chosen level or above. Keep {level}.") },
            "code.following": plural { String(localized: "Following · \($0) new lines", bundle: .previewKit,
                                              comment: "Chip while a growing log is followed: how many lines just arrived.") },
            "code.newLines": plural { String(localized: "\($0) new lines · newest at the bottom", bundle: .previewKit,
                                             comment: "Chip when lines arrived below the view of a growing log.") },
            "code.reopenAs": String(localized: "Reopen as…", bundle: .previewKit, comment: "Menu to read the file again in another text encoding."),
            "code.formattedFrom": plural { String(localized: "Formatted from \($0) lines for reading. The file on disk is untouched.", bundle: .previewKit,
                                                  comment: "Bar over a minified file shown re-indented.") },
            "code.asOnDisk": String(localized: "The file as it is on disk.", bundle: .previewKit, comment: "Bar over a minified file shown as it is."),
            "code.showOriginal": String(localized: "Show original", bundle: .previewKit, comment: "Button: show a minified file as it is on disk."),
            "code.formatForReading": String(localized: "Format for reading", bundle: .previewKit, comment: "Button: show a minified file re-indented."),
            "code.showAll": String(localized: "{label} · Show all", bundle: .previewKit,
                                   comment: "A folded run of repeated log lines, then a hint to unfold it. Keep {label}."),
            "code.typeLineNumber": String(localized: "Type a line number", bundle: .previewKit, comment: "Find with ':' before a number is typed."),
            "code.line": String(localized: "Line {line}", bundle: .previewKit, comment: "Find with ':': the line it went to. Keep {line}."),
            "code.symbolOf": plural { String(localized: "{i} of \($0) symbols", bundle: .previewKit,
                                             comment: "Find with '@': the current symbol of all matching symbols. Keep {i}.") },
            "code.noSymbols": String(localized: "No symbols", bundle: .previewKit, comment: "Find with '@': no symbol matches."),
            "code.levelHint": String(localized: "trace, debug, info, warn, error or fatal", bundle: .previewKit,
                                     comment: "Find with 'level:' before a level is typed: the level words it accepts. Keep the six words as they are; translate only 'or'."),
            "code.gap": String(localized: "{duration} with no lines", bundle: .previewKit,
                               comment: "A silence of a minute or more between two log lines. Keep {duration}."),
            "code.dur.s": String(localized: "{s} s", bundle: .previewKit, comment: "A duration in seconds. Keep {s}."),
            "code.dur.m": String(localized: "{m} min", bundle: .previewKit, comment: "A duration in minutes. Keep {m}."),
            "code.dur.ms": String(localized: "{m} min {s} s", bundle: .previewKit, comment: "A duration in minutes and seconds. Keep {m} and {s}."),
            "code.dur.h": String(localized: "{h} h", bundle: .previewKit, comment: "A duration in hours. Keep {h}."),
            "code.dur.hm": String(localized: "{h} h {m} min", bundle: .previewKit, comment: "A duration in hours and minutes. Keep {h} and {m}."),
            "code.run": String(localized: "×{count} {text}", bundle: .previewKit,
                               comment: "A folded run of near-identical log lines: how many times, then the line's words. Keep {count} and {text}."),
            "code.runOver": String(localized: "×{count} {text} over {duration}", bundle: .previewKit,
                                   comment: "A folded run of log lines and the time it spans. Keep {count}, {text} and {duration}."),
            // The display options popover (appearance.js).
            "code.appearance": String(localized: "Code appearance", bundle: .previewKit, comment: "Heading of the code view's display options popover."),
            "code.autoTheme": String(localized: "Vitrine (auto)", bundle: .previewKit,
                                     comment: "The code theme that follows the Mac's light or dark appearance. Vitrine is the app's name."),
            "code.imported": String(localized: "{name} · imported", bundle: .previewKit,
                                    comment: "An imported editor theme in the theme tiles. Keep {name}, the theme's own name."),
            "code.moreThemes": String(localized: "More themes ({n})", bundle: .previewKit, comment: "Button showing more code themes. Keep {n}, how many."),
            "code.fewerThemes": String(localized: "Fewer themes ({n})", bundle: .previewKit, comment: "Button hiding the extra code themes. Keep {n}."),
            "code.pt": String(localized: "{size} pt", bundle: .previewKit, comment: "A font size in points. Keep {size}."),
            "code.smaller": String(localized: "Smaller", bundle: .previewKit, comment: "Button: a smaller text size."),
            "code.larger": String(localized: "Larger", bundle: .previewKit, comment: "Button: a larger text size."),
            "code.font": String(localized: "Font", bundle: .previewKit, comment: "Display option label: the code font."),
            "code.lineHeight": String(localized: "Line height", bundle: .previewKit, comment: "Display option label: the space between lines."),
            "code.tight": String(localized: "Tight", bundle: .previewKit, comment: "Line height choice."),
            "code.normal": String(localized: "Normal", bundle: .previewKit, comment: "Line height choice."),
            "code.roomy": String(localized: "Roomy", bundle: .previewKit, comment: "Line height choice."),
            "code.tabWidth": String(localized: "Tab width", bundle: .previewKit, comment: "Display option label: how many spaces a tab is."),
            "code.wrap": String(localized: "Wrap lines", bundle: .previewKit, comment: "Display option toggle."),
            "code.lineNumbers": String(localized: "Line numbers", bundle: .previewKit, comment: "Display option toggle."),
            "code.indentGuides": String(localized: "Indent guides", bundle: .previewKit, comment: "Display option toggle."),
            "code.changedLines": String(localized: "Changed lines", bundle: .previewKit, comment: "Display option toggle: marks lines changed since the last commit."),
            "code.sticky": String(localized: "Sticky scope", bundle: .previewKit, comment: "Display option toggle: keeps the enclosing function's line at the top."),
            "code.minimap": String(localized: "Minimap", bundle: .previewKit, comment: "Display option toggle: a small map of the whole file."),
            "code.importTheme": String(localized: "Import theme…", bundle: .previewKit, comment: "Button: import an editor theme file."),
            "code.importNote": String(localized: "VS Code, Zed or TextMate · {n} built in · stays on this Mac", bundle: .previewKit,
                                      comment: "Note beside Import theme: the theme formats it reads, how many themes are built in, and that imports stay local. Keep {n}."),
        ]
    }

    // MARK: The diff and compare page (diff-entry.js)

    static var diff: Table {
        [
            "diff.linesWithoutMatch": linesWithoutMatch,
            "diff.notKept": String(localized: "Lines not kept: this patch is past the detail limit. Counted above.", bundle: .previewKit,
                                   comment: "A file in a very large patch whose lines are not drawn."),
            "diff.binaryFile": String(localized: "Binary file · {detail}", bundle: .previewKit, comment: "A binary file in a patch. Keep {detail}."),
            "diff.more": String(localized: "More", bundle: .previewKit, comment: "Button: show the whole commit message."),
            "diff.less": String(localized: "Less", bundle: .previewKit, comment: "Button: show less of the commit message."),
            "diff.checks": String(localized: "Checks", bundle: .previewKit, comment: "Heading of a patch's safety checks (secrets, scripts)."),
            "diff.show": String(localized: "Show", bundle: .previewKit, comment: "Link: scroll to the file a check is about."),
            "diff.secret": String(localized: "Secret", bundle: .previewKit, comment: "Badge: a check found a secret (a key or token) in the patch."),
            "diff.script": String(localized: "Script", bundle: .previewKit, comment: "Badge: a check found a script in the patch."),
            "diff.files": String(localized: "Files", bundle: .previewKit, comment: "Heading of the files a patch changes."),
            "diff.similar": String(localized: "{pct} similar", bundle: .previewKit,
                                   comment: "How similar a renamed file is to its old self. Keep {pct}, a percentage."),
            "diff.andMore": plural { String(localized: "and \($0) more", bundle: .previewKit, comment: "Button showing the rest of a list.") },
            "diff.rest": String(localized: "{coverage}. The rest are counted, not drawn.", bundle: .previewKit,
                                comment: "Under a long patch's file list. Keep {coverage}, a sentence saying how many are shown."),
            "diff.whatChanged": String(localized: "What changed", bundle: .previewKit, comment: "Heading of a compare's list of changes."),
            "diff.link": String(localized: "link “{text}”: {old} → {new}", bundle: .previewKit,
                                comment: "A changed link in a prose compare. Keep {text}, {old} and {new}."),
            "diff.sourceChanged": String(localized: "Source changed", bundle: .previewKit, comment: "A notebook cell's code or text changed."),
            "diff.outputChanged": String(localized: "Output changed", bundle: .previewKit, comment: "A notebook cell's output changed."),
            "diff.bothChanged": String(localized: "Source and output changed", bundle: .previewKit, comment: "A notebook cell's code and output changed."),
            "diff.added": String(localized: "Added", bundle: .previewKit, comment: "A notebook cell or output was added."),
            "diff.removed": String(localized: "Removed", bundle: .previewKit, comment: "A notebook cell or output was removed."),
            "diff.changed": String(localized: "Changed", bundle: .previewKit, comment: "A notebook output changed."),
            "diff.codeCell": String(localized: "Code cell", bundle: .previewKit, comment: "A notebook cell holding code."),
            "diff.markdownCell": String(localized: "Markdown cell", bundle: .previewKit, comment: "A notebook cell holding Markdown text."),
            "diff.rawCell": String(localized: "Raw cell", bundle: .previewKit, comment: "A notebook cell holding raw text."),
            "diff.cell": String(localized: "Cell", bundle: .previewKit, comment: "A notebook cell of an unknown kind."),
            "diff.output": String(localized: "Output · {type} · {status}", bundle: .previewKit,
                                  comment: "Label over a changed notebook output. Keep {type} (a MIME or stream name) and {status}."),
            "diff.noneBefore": String(localized: "none before", bundle: .previewKit, comment: "A notebook output that did not exist before."),
            "diff.noneAfter": String(localized: "none after", bundle: .previewKit, comment: "A notebook output that no longer exists."),
            "diff.before": String(localized: "Before · {width} × {height}", bundle: .previewKit,
                                  comment: "Caption of the old image in an image compare, with its pixel size. Keep {width} and {height}."),
            "diff.after": String(localized: "After · {width} × {height}", bundle: .previewKit,
                                 comment: "Caption of the new image in an image compare, with its pixel size. Keep {width} and {height}."),
        ]
    }

    // MARK: The Markdown page (markdown.js)

    static var markdown: Table {
        [
            "md.drawing": String(localized: "Drawing diagram…", bundle: .previewKit, comment: "Placeholder while a Mermaid diagram is drawn."),
            "md.diagramFailed": String(localized: "This diagram could not be drawn: {reason}", bundle: .previewKit,
                                       comment: "A Mermaid diagram failed. Keep {reason}, the library's own message."),
            "md.diagramsUnavailable": String(localized: "Diagrams are unavailable: the diagram library did not load.", bundle: .previewKit,
                                             comment: "The Mermaid library did not load."),
            "md.remoteNotLoaded": String(localized: "{host} — remote, not loaded", bundle: .previewKit,
                                         comment: "Tooltip of a remote image that is not loaded. Keep {host}."),
            "md.remoteFailed": String(localized: "{host} — remote, could not be loaded", bundle: .previewKit,
                                      comment: "Tooltip of a remote image that failed to load. Keep {host}."),
            "md.image": String(localized: "image", bundle: .previewKit, comment: "Stand-in name for a remote image that has no alt text."),
            "md.imagesNotLoaded": plural { String(localized: "\($0) images are not loaded", bundle: .previewKit,
                                                  comment: "Bar above a Markdown page with remote images.") },
            "md.imagesFailed": plural { String(localized: "\($0) images could not be loaded", bundle: .previewKit,
                                               comment: "Bar above a Markdown page when remote images failed to load.") },
            "md.loadOnce": String(localized: "Load once", bundle: .previewKit, comment: "Button: fetch a Markdown file's remote images this once."),
            "md.loadOnceHelp": String(localized: "Fetch these images once, for this file only", bundle: .previewKit, comment: "Tooltip of Load once."),
            "md.loading": String(localized: "Loading…", bundle: .previewKit, comment: "Load once button while the images load."),
            "md.copy": String(localized: "Copy", bundle: .previewKit, comment: "Capsule button tooltip: copies the file's text."),
            "md.copied": String(localized: "Copied", bundle: .previewKit, comment: "Capsule copy button tooltip for a moment after copying."),
            "md.themeAndSize": String(localized: "Theme and text size", bundle: .previewKit, comment: "The Aa popover of a Markdown page."),
            "md.theme": String(localized: "Theme", bundle: .previewKit, comment: "Heading of the theme tiles in the Aa popover."),
            "md.textSize": String(localized: "Text size", bundle: .previewKit, comment: "Label of the text size control in the Aa popover."),
            "md.smaller": String(localized: "Smaller", bundle: .previewKit, comment: "Button: a smaller text size."),
            "md.smallerKey": String(localized: "Smaller (⌘−)", bundle: .previewKit, comment: "Tooltip: a smaller text size, with its shortcut."),
            "md.larger": String(localized: "Larger", bundle: .previewKit, comment: "Button: a larger text size."),
            "md.largerKey": String(localized: "Larger (⌘+)", bundle: .previewKit, comment: "Tooltip: a larger text size, with its shortcut."),
        ]
    }

    // MARK: The notebook page (notebook.js)

    static var notebook: Table {
        [
            "nb.notLoaded": String(localized: "{host} — not loaded", bundle: .previewKit,
                                   comment: "Tooltip of a notebook image named by web address, never loaded. Keep {host}."),
            "md.image": String(localized: "image", bundle: .previewKit, comment: "Stand-in name for a remote image that has no alt text."),
        ]
    }
}
