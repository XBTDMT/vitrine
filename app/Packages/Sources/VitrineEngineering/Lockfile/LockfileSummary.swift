import Foundation

/// What a lockfile says about a project's dependencies (A-12): which ecosystem wrote it, how many packages it locks,
/// where they come from, how firmly each one is pinned and, only when the file itself carries them, their licences.
/// Everything here is read from the file's own bytes; nothing is looked up and nothing is guessed.
/// roadmap: S-22
public struct LockfileSummary: Sendable, Equatable {
    /// The package manager whose lockfile this is. roadmap: S-22
    public enum Ecosystem: String, Sendable {
        case npm, yarn, pnpm, bun, cargo, bundler, poetry, uv, pipenv, goModules, swiftPM, composer, cocoapods
    }

    public var ecosystem: Ecosystem
    /// The file's own format version when it states one: npm's lockfileVersion, yarn berry's __metadata version,
    /// pnpm's lockfileVersion, Package.resolved's version, Cargo.lock's and uv.lock's top-level version, poetry's
    /// lock-version, Pipfile.lock's pipfile-spec. nil when the format has none (go.sum, Gemfile.lock, Podfile.lock,
    /// composer.lock).
    public var formatVersion: String?
    /// The locked packages in file order, at most `LockfileReader.maxPackages` of them.
    public var packages: [Package]
    /// Every locked package counted, even past the cap on `packages`.
    public var totalPackages: Int
    /// How many locked packages the project asks for by name, when the lockfile records it; nil when it does not.
    public var directCount: Int?
    /// Where the packages come from, grouped by kind and host, most packages first; the counts add up to
    /// `totalPackages`.
    public var sources: [Source]
    /// How firmly the packages are pinned; the five counts add up to `totalPackages`.
    public var pinning: Pinning
    /// Licence → number of packages, only when the lockfile itself carries licences (npm lockfileVersion 2 and 3,
    /// composer.lock); nil for every other format. Packages the file gives no licence for are not counted.
    public var licences: [String: Int]?
    /// The input passed a limit (more than 8 MB, more than `maxPackages` packages, nesting too deep) or ended in the
    /// middle of a structure, so what is here was read from part of it.
    public var truncated: Bool

    public init(ecosystem: Ecosystem, formatVersion: String?, packages: [Package], totalPackages: Int, directCount: Int?,
                sources: [Source], pinning: Pinning, licences: [String: Int]?, truncated: Bool) {
        self.ecosystem = ecosystem
        self.formatVersion = formatVersion
        self.packages = packages
        self.totalPackages = totalPackages
        self.directCount = directCount
        self.sources = sources
        self.pinning = pinning
        self.licences = licences
        self.truncated = truncated
    }

    /// One locked package. roadmap: S-22
    public struct Package: Sendable, Equatable {
        public var name: String
        /// The locked version as the file writes it (pseudo-versions, platform suffixes and dev branches included).
        public var version: String?
        /// A short label for where it comes from: the registry, git or download host (never with user or password),
        /// or the local path for a path package; nil for the ecosystem's default registry when the file does not
        /// name it, and when the origin is unknown.
        public var source: String?
        /// The kind of origin, matching the group this package is counted in under `sources`.
        public var sourceKind: Source.Kind
        /// true when the project asks for it by name, false when only another package does; nil when the lockfile
        /// does not say.
        public var isDirect: Bool?
        /// The file records a hash (integrity, checksum, sha) for it.
        public var integrity: Bool
        /// The licence the file records for it (composer's alternatives joined with " OR ").
        public var licence: String?
        /// The full identifier advisory databases use when the display name is short: a SwiftPM pin's repository
        /// URL (G-26). Credentials are removed. nil when the name is the identifier.
        public var locator: String?

        public init(name: String, version: String?, source: String?, sourceKind: Source.Kind = .unknown,
                    isDirect: Bool?, integrity: Bool, licence: String?, locator: String? = nil) {
            self.name = name
            self.version = version
            self.source = source
            self.sourceKind = sourceKind
            self.isDirect = isDirect
            self.integrity = integrity
            self.licence = licence
            self.locator = locator
        }
    }

    /// One group of packages sharing an origin. `host` is nil for path packages, for unknown origins and for the
    /// ecosystem's default registry when the file does not name it (pnpm, yarn berry, bun, poetry, Package.resolved
    /// registry pins). roadmap: S-22
    public struct Source: Sendable, Equatable {
        public enum Kind: String, Sendable { case registry, git, path, url, unknown }
        public var kind: Kind
        public var host: String?
        public var count: Int

        public init(kind: Kind, host: String?, count: Int) {
            self.kind = kind
            self.host = host
            self.count = count
        }
    }

    /// How firmly packages are pinned. Every package lands in exactly one bucket, checked in this order: a git
    /// package is `gitWithCommit` or `gitWithoutCommit`; a path package is `unpinned`; a package with a recorded
    /// hash is `withIntegrity`; one with an exact version but no hash is `exact`; anything else (a URL without a
    /// hash, a dev branch, no version) is `unpinned`. roadmap: S-22
    public struct Pinning: Sendable, Equatable {
        public var exact: Int
        public var withIntegrity: Int
        public var gitWithCommit: Int
        public var gitWithoutCommit: Int
        public var unpinned: Int

        public init(exact: Int = 0, withIntegrity: Int = 0, gitWithCommit: Int = 0, gitWithoutCommit: Int = 0, unpinned: Int = 0) {
            self.exact = exact
            self.withIntegrity = withIntegrity
            self.gitWithCommit = gitWithCommit
            self.gitWithoutCommit = gitWithoutCommit
            self.unpinned = unpinned
        }

        /// The sum of the five buckets, which equals the summary's `totalPackages`.
        public var total: Int { exact + withIntegrity + gitWithCommit + gitWithoutCommit + unpinned }
    }
}
