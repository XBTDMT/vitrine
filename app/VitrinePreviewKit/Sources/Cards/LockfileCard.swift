import Foundation
import VitrineDocument
import VitrineEngineering
import VitrineSupport
import VitrineTrust

/// A dependency lockfile on the card (A-12, cards r3-a): how many packages it pins and how many are direct, where
/// they come from, how firmly they are pinned (exact versions, integrity hashes, git commits) and, where the file
/// carries them, their licences. The Packages view lists them; Source is the file itself, secrets masked (G-23).
/// Vulnerability hints come from the opt-in OSV lists on this Mac (G-26), dated, never fetched per file. roadmap: S-22
extension PackageFacts {
    static func lockfile(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: LockfileReader.maxBytes) ?? Data()
        var b = Builder()
        var extras = Extras()
        let language = Lock.language(for: url.lastPathComponent.lowercased())
        let text = String(decoding: data.prefix(TextLens.maxBytes), as: UTF8.self)
        extras.extraViews.append((title: "Source", view: .code(LensPolicy.masked(text, kind: .code(language: language)).text, language: language)))
        guard let s = LockfileReader.read(data: data, fileName: url.lastPathComponent) else {
            b.add("form", Lock.ecosystem, Lock.unreadable)
            return (b.document(kind: kind), extras)
        }
        b.add("ecosystem", Lock.ecosystem, Lock.name(s.ecosystem))
        b.add("formatVersion", Lock.format, s.formatVersion)
        b.add("packages", Lock.packages, s.totalPackages.formatted())
        b.add("direct", Lock.direct, s.directCount.map { $0.formatted() })
        b.add("sources", Lock.sources, s.sources.sorted { $0.count > $1.count }.map { "\(Lock.source($0)) ×\($0.count.formatted())" }.joined(separator: ", "))
        b.add("sourceCount", "sourceCount", String(s.sources.count))
        let p = s.pinning
        // Local folders (the project's own crates, path dependencies) are not downloaded: they cannot drift on install.
        let local = s.sources.filter { $0.kind == .path }.reduce(0) { $0 + $1.count }
        let unpinnedFetched = max(0, p.unpinned - local)
        b.add("pinned", Lock.pinned, [
            p.withIntegrity > 0 ? String(localized: "\(p.withIntegrity) with a hash", bundle: .previewKit, comment: "Lockfile pinning: packages whose download is checked against a hash.") : nil,
            p.exact > 0 ? String(localized: "\(p.exact) by exact version", bundle: .previewKit, comment: "Lockfile pinning: packages pinned to an exact version, no hash.") : nil,
            p.gitWithCommit > 0 ? String(localized: "\(p.gitWithCommit) at a git commit", bundle: .previewKit, comment: "Lockfile pinning: git dependencies fixed to a commit.") : nil,
            p.gitWithoutCommit > 0 ? String(localized: "\(p.gitWithoutCommit) following a git branch", bundle: .previewKit, comment: "Lockfile pinning: git dependencies that follow a branch or tag.") : nil,
            unpinnedFetched > 0 ? String(localized: "\(unpinnedFetched) not pinned", bundle: .previewKit, comment: "Lockfile pinning: packages with no exact version, hash or commit.") : nil,
            local > 0 ? String(localized: "\(local) from local folders", bundle: .previewKit, comment: "Lockfile pinning: packages read from folders on disk, not downloaded.") : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        b.add("withIntegrity", "withIntegrity", String(p.withIntegrity))
        b.add("loose", "loose", String(unpinnedFetched + p.gitWithoutCommit))
        if let licences = s.licences {
            b.add("licences", Lock.licences, licences.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) ×\($0.value.formatted())" }.joined(separator: ", "))
        }
        if s.truncated { b.add("truncated", Lock.truncated, Word.yes) }
        if p.gitWithoutCommit > 0 {
            b.badges.append(Badge(level: .caution, title: String(localized: "\(p.gitWithoutCommit) git dependencies follow a branch", bundle: .previewKit, comment: "Warning title: git dependencies not fixed to a commit."),
                                  detail: String(localized: "A new install can fetch different code than the one locked here.", bundle: .previewKit, comment: "Warning detail for git dependencies that follow a branch.")))
        }
        if unpinnedFetched > 0 {
            b.badges.append(Badge(level: .caution, title: String(localized: "\(unpinnedFetched) packages are not pinned", bundle: .previewKit, comment: "Warning title: packages with no exact version, hash or commit."),
                                  detail: String(localized: "They have no exact version, hash or commit, so an install may not repeat.", bundle: .previewKit, comment: "Warning detail for unpinned packages.")))
        }
        advisories(s, into: &b)
        b.headline(String(localized: "\(s.totalPackages) packages", bundle: .previewKit, comment: "Pill summary: how many packages a lockfile pins."))
        // Packages, one per line: name, version, where from.
        let width = min(40, (s.packages.map(\.name.count).max() ?? 10) + 2)
        var list = s.packages.map { pkg in
            pkg.name.padding(toLength: max(width, pkg.name.count + 1), withPad: " ", startingAt: 0)
                + (pkg.version ?? "").padding(toLength: 16, withPad: " ", startingAt: 0)
                + (pkg.isDirect == true ? "● " : "  ") + (pkg.source ?? "")
        }
        if s.totalPackages > s.packages.count {
            list.append(String(localized: "… and \(s.totalPackages - s.packages.count) more", bundle: .previewKit, comment: "End of a lockfile's package list: how many are not listed."))
        }
        extras.extraViews.insert((title: "Packages", view: .text(list.joined(separator: "\n"))), at: 0)
        return (b.document(kind: kind), extras)
    }

    /// Known advisories for the locked packages (G-26), from the list installed for the lockfile's ecosystem.
    static func advisories(_ s: LockfileSummary, into b: inout Builder) {
        switch AdvisoryStore.coverage(for: s) {
        case .off:
            b.add("advisoryState", "advisoryState", "off")
        case .unsupported:
            b.add("advisoryState", "advisoryState", "unsupported")
        case .notDownloaded(let e):
            b.add("advisoryState", "advisoryState", "missing")
            b.add("advisoryEcosystem", "advisoryEcosystem", e.rawValue)
        case .checked(let meta, let matches):
            b.add("advisoryState", "advisoryState", "checked")
            b.add("advisoryDate", Lock.advisoryDate, (meta.sourceLastModified ?? meta.builtAt).formatted(date: .abbreviated, time: .omitted))
            b.add("advisoryCount", Lock.advisoryCount, String(matches.count))
            let lines = matches.prefix(12).map { m -> String in
                let top = m.advisories.first
                let fixed = top?.fixed.first.map { String(localized: "fixed in \($0)", bundle: .previewKit, comment: "An advisory's fixed version; e.g. “fixed in 4.0.2”.") }
                let what = top.map { a in a.isMalicious ? String(localized: "known malicious", bundle: .previewKit, comment: "An advisory that reports a package as malware.") : a.severity.rawValue }
                return "\(m.package) \(m.version): " + [top?.id, what, fixed].compactMap { $0 }.joined(separator: " · ")
            }
            b.add("advisoryList", Lock.advisoryList, lines.joined(separator: "\n"))
            let malicious = matches.filter { $0.advisories.contains(where: \.isMalicious) }
            if let first = malicious.first {
                b.badges.append(Badge(level: .danger, title: String(localized: "\(malicious.count) known malicious packages", bundle: .previewKit, comment: "Danger title: the lockfile pins packages OSV reports as malware."),
                                      detail: String(localized: "\(first.package) \(first.version) is reported as malware; do not install from this lockfile.", bundle: .previewKit,
                                                     comment: "Danger detail: the first malicious package and its version.")))
            } else if let first = matches.first {
                b.badges.append(Badge(level: .caution, title: String(localized: "\(matches.count) packages have known advisories", bundle: .previewKit, comment: "Warning title: locked packages with security advisories."),
                                      detail: lines.first ?? first.package))
            }
        }
    }

    enum Lock {
        static var advisoryDate: String { String(localized: "Advisory list from", bundle: .previewKit, comment: "Fact label: the date of the OSV list a lockfile was checked against.") }
        static var advisoryCount: String { String(localized: "Packages with advisories", bundle: .previewKit, comment: "Fact label: how many locked packages have known advisories.") }
        static var advisoryList: String { String(localized: "Advisories", bundle: .previewKit, comment: "Fact label: the locked packages with advisories, one per line.") }
        static var knownAdvisories: String { String(localized: "Any known advisories", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var ecosystem: String { String(localized: "Ecosystem", bundle: .previewKit, comment: "Fact label: the package manager a lockfile belongs to.") }
        static var unreadable: String { String(localized: "Not a lockfile Vitrine can read", bundle: .previewKit, comment: "Fact value: the file could not be read as a lockfile.") }
        static var format: String { String(localized: "Format version", bundle: .previewKit, comment: "Fact label: a lockfile's format version.") }
        static var packages: String { String(localized: "Packages", bundle: .previewKit, comment: "Fact label: how many packages a lockfile pins.") }
        static var direct: String { String(localized: "Direct", bundle: .previewKit, comment: "Fact label: how many of a lockfile's packages the project asks for itself.") }
        static var sources: String { String(localized: "Sources", bundle: .previewKit, comment: "Fact label: where a lockfile's packages come from.") }
        static var pinned: String { String(localized: "Pinning", bundle: .previewKit, comment: "Fact label: how firmly a lockfile's packages are pinned.") }
        static var licences: String { String(localized: "Licences", bundle: .previewKit, comment: "Fact label: the licences a lockfile records.") }
        static var truncated: String { String(localized: "Read in part", bundle: .previewKit, comment: "Fact label: the lockfile was larger than Vitrine reads.") }

        static func name(_ e: LockfileSummary.Ecosystem) -> String {
            switch e {
            case .npm: "npm"; case .yarn: "Yarn"; case .pnpm: "pnpm"; case .bun: "Bun"; case .cargo: "Cargo"; case .bundler: "Bundler"
            case .poetry: "Poetry"; case .uv: "uv"; case .pipenv: "Pipenv"; case .goModules: "Go modules"; case .swiftPM: "Swift Package Manager"
            case .composer: "Composer"; case .cocoapods: "CocoaPods"
            }
        }

        static func source(_ s: LockfileSummary.Source) -> String {
            switch s.kind {
            case .registry: s.host ?? String(localized: "the default registry", bundle: .previewKit, comment: "Lockfile source: the package manager's default registry, not named in the file.")
            case .git: "git" + (s.host.map { " (\($0))" } ?? "")
            case .path: String(localized: "local folders", bundle: .previewKit, comment: "Lockfile source: packages from folders on disk.")
            case .url: s.host ?? "URL"
            case .unknown: String(localized: "unknown", bundle: .previewKit, comment: "Lockfile source the file does not say.")
            }
        }

        static func language(for name: String) -> String {
            switch name {
            case "cargo.lock", "poetry.lock", "uv.lock": "toml"
            case "pnpm-lock.yaml", "podfile.lock": "yaml"
            case "yarn.lock", "go.sum", "go.work.sum", "gemfile.lock", "gems.locked": "plaintext"
            default: "json"
            }
        }
    }
}

extension BinaryCard {
    static func lockfile(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let ecosystem = v("ecosystem") ?? Phrase.unknown
        let packages = v("packages") ?? "0"
        let sourceCount = Int(v("sourceCount") ?? "0") ?? 0
        let total = Int(packages.filter(\.isNumber)) ?? 0
        let hashed = Int(v("withIntegrity") ?? "0") ?? 0
        let loose = Int(v("loose") ?? "0") ?? 0
        let sentence: String
        if let direct = v("direct").flatMap({ Int($0.filter(\.isNumber)) }) {
            sentence = String(localized: "A lockfile for \(ecosystem), pinning \(total) packages, \(direct) of them direct, from \(sourceCount) sources.", bundle: .previewKit,
                              comment: "A lockfile's sentence; e.g. “A lockfile for Cargo, pinning 212 packages, 14 of them direct, from 2 sources.”")
        } else {
            sentence = String(localized: "A lockfile for \(ecosystem), pinning \(total) packages from \(sourceCount) sources.", bundle: .previewKit,
                              comment: "A lockfile's sentence without a direct count; e.g. “A lockfile for Go modules, pinning 88 packages from 4 sources.”")
        }
        var answers = [
            Answer(mark: .neutral, question: String(localized: "Where are they from", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: v("sources") ?? Phrase.unknown),
            Answer(mark: loose > 0 ? .caution : .ok, question: String(localized: "Is every package pinned", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: loose == 0 ? String(localized: "Yes", bundle: .previewKit, comment: "A fact's value: yes.")
                                      : String(localized: "No, \(loose) can change on the next install", bundle: .previewKit, comment: "Trust card answer: how many packages are not firmly pinned."),
                   evidence: v("pinned")),
        ]
        if total > 0 {
            let percent = (Double(hashed) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
            answers.append(Answer(mark: .neutral, question: String(localized: "Are downloads checked", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: String(localized: "\(percent) carry a hash the installer checks", bundle: .previewKit, comment: "Trust card answer: the share of packages with an integrity hash; e.g. “98% carry a hash the installer checks”.")))
        }
        let checkedDate = v("advisoryDate")
        switch v("advisoryState") {
        case "checked":
            let count = Int(v("advisoryCount") ?? "0") ?? 0
            let date = checkedDate ?? Phrase.unknown
            answers.insert(Answer(mark: count == 0 ? .ok : (doc.badges.contains { $0.level == .danger } ? .danger : .caution),
                                  question: PackageFacts.Lock.knownAdvisories,
                                  answer: count == 0 ? String(localized: "None known in the OSV list from \(date)", bundle: .previewKit, comment: "Trust card answer: no advisories; the argument is the list's date.")
                                                     : String(localized: "Yes, \(count) packages (OSV list from \(date))", bundle: .previewKit, comment: "Trust card answer: how many packages have advisories, and the list's date."),
                                  evidence: count == 0 ? nil : v("advisoryList")?.replacingOccurrences(of: "\n", with: "; ")), at: 0)
        case "missing":
            answers.append(Answer(mark: .neutral, question: PackageFacts.Lock.knownAdvisories,
                                  answer: String(localized: "Not checked: the \(v("advisoryEcosystem") ?? "") list is not downloaded (Settings › Privacy)", bundle: .previewKit,
                                                 comment: "Trust card answer: hints are on but this ecosystem's list is not installed; the argument is the ecosystem.")))
        case "unsupported":
            answers.append(Answer(mark: .neutral, question: PackageFacts.Lock.knownAdvisories,
                                  answer: String(localized: "Not checked: OSV publishes no advisories for \(ecosystem)", bundle: .previewKit, comment: "Trust card answer: OSV has no feed for this ecosystem (CocoaPods).")))
        default:
            answers.append(Answer(mark: .neutral, question: PackageFacts.Lock.knownAdvisories,
                                  answer: String(localized: "Not checked: vulnerability hints are off (Settings › Privacy)", bundle: .previewKit, comment: "Trust card answer: the person has not turned vulnerability hints on.")))
        }
        if let licences = v("licences") {
            answers.append(Answer(mark: .neutral, question: String(localized: "Which licences", bundle: .previewKit, comment: "Trust card question (written without its question mark)."), answer: licences))
        }
        let strip = firstThree([
            Stat(value: packages, label: PackageFacts.Lock.packages),
            v("direct").map { Stat(value: $0, label: PackageFacts.Lock.direct) },
            Stat(value: sourceCount.formatted(), label: PackageFacts.Lock.sources),
        ])
        return BinaryCard(kind: doc.kind, title: fileName, sentence: sentence, bold: [ecosystem, total.formatted()],
                          stageChip: String(localized: "Lockfile", bundle: .previewKit, comment: "The kind chip on a lockfile's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: String(localized: "Check before installing", bundle: .previewKit, comment: "Verdict chip: a caution about a lockfile."),
                                           calmTitle: String(localized: "Every package is pinned", bundle: .previewKit, comment: "Calm verdict title for a lockfile with nothing loose."),
                                           calmReason: checkedDate.map { String(localized: "Installing from it repeats exactly; no known advisories in the OSV list from \($0).", bundle: .previewKit,
                                                                                         comment: "Calm verdict reason for a lockfile checked against an advisory list; the argument is its date.") }
                                               ?? String(localized: "Installing from it repeats exactly; Vitrine checks no registry or vulnerability list.", bundle: .previewKit,
                                                         comment: "Calm verdict reason for a lockfile.")),
                          answers: answers)
    }
}
