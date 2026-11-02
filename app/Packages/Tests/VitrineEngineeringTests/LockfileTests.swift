import Foundation
import Testing
@testable import VitrineEngineering

// The lockfile reader (A-12) on invented lockfiles: every package name, host path and hash below is made up
// (acme-notes, harbor-utils, tiny-lint, local-kit …), written by hand in each format's shape. Nothing here runs git
// or touches the network. roadmap: S-22

private func read(_ text: String, _ name: String) -> LockfileSummary? {
    LockfileReader.read(data: Data(text.utf8), fileName: name)
}

private func source(_ s: LockfileSummary, _ kind: LockfileSummary.Source.Kind, _ host: String?) -> Int? {
    s.sources.first { $0.kind == kind && $0.host == host }?.count
}

private func pins(exact: Int = 0, integrity: Int = 0, gitCommit: Int = 0, gitNoCommit: Int = 0, unpinned: Int = 0) -> LockfileSummary.Pinning {
    LockfileSummary.Pinning(exact: exact, withIntegrity: integrity, gitWithCommit: gitCommit, gitWithoutCommit: gitNoCommit, unpinned: unpinned)
}

private let sha = "0123456789abcdef0123456789abcdef01234567"

// MARK: - npm

@Suite("npm lockfiles")
struct NPMLockfileTests {
    static let v3 = """
    {
      "name": "acme-app",
      "version": "1.0.0",
      "lockfileVersion": 3,
      "requires": true,
      "packages": {
        "": { "name": "acme-app", "version": "1.0.0",
              "dependencies": { "acme-notes": "^1.2.0", "harbor-utils": "github:acme/harbor-utils" },
              "devDependencies": { "tiny-lint": "^0.3.0" } },
        "node_modules/acme-notes": { "version": "1.2.0", "resolved": "https://registry.npmjs.org/acme-notes/-/acme-notes-1.2.0.tgz",
              "integrity": "sha512-AAAA", "license": "MIT", "dependencies": { "left-pad-lite": "^2.0.0" } },
        "node_modules/left-pad-lite": { "version": "2.0.1", "resolved": "https://registry.npmjs.org/left-pad-lite/-/left-pad-lite-2.0.1.tgz",
              "integrity": "sha512-BBBB", "license": "MIT" },
        "node_modules/harbor-utils": { "version": "0.4.0", "resolved": "git+ssh://git@github.com/acme/harbor-utils.git#\(sha)", "license": "Apache-2.0" },
        "node_modules/tiny-lint": { "version": "0.3.2", "resolved": "https://deploy:hunter2@npm.example.com/tiny-lint/-/tiny-lint-0.3.2.tgz",
              "dev": true, "license": "ISC" },
        "node_modules/tiny-lint/node_modules/left-pad-lite": { "version": "1.0.0",
              "resolved": "https://registry.npmjs.org/left-pad-lite/-/left-pad-lite-1.0.0.tgz", "integrity": "sha512-CCCC" },
        "node_modules/local-kit": { "resolved": "packages/local-kit", "link": true },
        "packages/local-kit": { "name": "local-kit", "version": "0.0.1" }
      }
    }
    """

    @Test func version3CountsDirectSourcesPinningAndLicences() throws {
        let s = try #require(read(Self.v3, "package-lock.json"))
        #expect(s.ecosystem == .npm && s.formatVersion == "3")
        #expect(s.totalPackages == 6 && s.packages.count == 6)
        #expect(s.directCount == 3)
        #expect(s.packages.filter { $0.isDirect == true }.map(\.name) == ["acme-notes", "harbor-utils", "tiny-lint"])
        #expect(source(s, .registry, "registry.npmjs.org") == 3)
        #expect(source(s, .registry, "npm.example.com") == 1)
        #expect(source(s, .git, "github.com") == 1)
        #expect(source(s, .path, nil) == 1)
        #expect(s.sources.first?.host == "registry.npmjs.org")
        #expect(s.pinning == pins(exact: 1, integrity: 3, gitCommit: 1, unpinned: 1))
        #expect(s.pinning.total == s.totalPackages)
        #expect(s.licences == ["MIT": 2, "Apache-2.0": 1, "ISC": 1])
        #expect(!s.truncated)
    }

    @Test func credentialsInAResolvedURLNeverReachTheSummary() throws {
        let s = try #require(read(Self.v3, "package-lock.json"))
        #expect(!String(describing: s).contains("hunter2"))
        #expect(!String(describing: s).contains("deploy"))
        #expect(s.packages.first { $0.name == "tiny-lint" }?.source == "npm.example.com")
    }

    @Test func version1WalksNestedDependenciesAndCarriesNoLicences() throws {
        let v1 = """
        { "name": "old-app", "version": "1.0.0", "lockfileVersion": 1, "requires": true,
          "dependencies": {
            "acme-notes": { "version": "1.2.0", "resolved": "https://registry.npmjs.org/acme-notes/-/acme-notes-1.2.0.tgz", "integrity": "sha512-AAAA",
              "dependencies": { "left-pad-lite": { "version": "1.0.0", "resolved": "https://registry.npmjs.org/left-pad-lite/-/left-pad-lite-1.0.0.tgz", "integrity": "sha1-DDDD" } } },
            "harbor-utils": { "version": "github:acme/harbor-utils#\(sha)", "from": "github:acme/harbor-utils" },
            "left-pad-lite": { "version": "2.0.1", "resolved": "https://registry.npmjs.org/left-pad-lite/-/left-pad-lite-2.0.1.tgz" }
          } }
        """
        let s = try #require(read(v1, "npm-shrinkwrap.json"))
        #expect(s.ecosystem == .npm && s.formatVersion == "1")
        #expect(s.totalPackages == 4)
        #expect(s.directCount == nil && s.packages.allSatisfy { $0.isDirect == nil })
        #expect(source(s, .registry, "registry.npmjs.org") == 3 && source(s, .git, "github.com") == 1)
        #expect(s.pinning == pins(exact: 1, integrity: 2, gitCommit: 1))
        #expect(s.licences == nil)
    }

    @Test func malformedJSONGivesNilOrAPartialSummary() throws {
        #expect(read("not json at all", "package-lock.json") == nil)
        #expect(read("[1, 2, 3]", "package-lock.json") == nil)
        #expect(read("{\"name\": \"acme\"}", "package-lock.json") == nil)
        let cut = """
        {"lockfileVersion": 3, "packages": {"": {"dependencies": {"acme-notes": "1"}},
         "node_modules/acme-notes": {"version": "1.2.0", "integrity": "sha512-A"},
         "node_modules/harbor-utils": {"version": "0.
        """
        let s = try #require(read(cut, "package-lock.json"))
        #expect(s.truncated && s.totalPackages >= 1 && s.directCount == 1)
        // Deep nesting stops at the depth bound instead of recursing without end.
        let deep = "{\"lockfileVersion\": 1, \"dependencies\": " + String(repeating: "[", count: 50_000)
        let d = read(deep, "package-lock.json")
        #expect(d == nil || d?.truncated == true)
    }
}

// MARK: - yarn

@Suite("yarn lockfiles")
struct YarnLockfileTests {
    @Test func classicV1() throws {
        let text = """
        # THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.
        # yarn lockfile v1


        "@acme/core@^3.0.0":
          version "3.0.1"
          resolved "https://registry.yarnpkg.com/@acme/core/-/core-3.0.1.tgz#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          integrity sha512-EEEE

        acme-notes@^1.0.0, acme-notes@^1.1.0:
          version "1.2.0"
          resolved "https://registry.yarnpkg.com/acme-notes/-/acme-notes-1.2.0.tgz#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          dependencies:
            "@acme/core" "^3.0.0"

        harbor-utils@acme/harbor-utils#main:
          version "0.4.0"
          resolved "https://codeload.github.com/acme/harbor-utils/tar.gz/\(sha)"

        local-kit@file:./local-kit:
          version "0.0.1"

        tiny-lint@git+https://github.com/acme/tiny-lint.git#main:
          version "0.3.2"
          resolved "git+https://github.com/acme/tiny-lint.git#main"
        """
        let s = try #require(read(text, "yarn.lock"))
        #expect(s.ecosystem == .yarn && s.formatVersion == "1")
        #expect(s.totalPackages == 5)
        #expect(s.packages.map(\.name) == ["@acme/core", "acme-notes", "harbor-utils", "local-kit", "tiny-lint"])
        #expect(s.packages[1].version == "1.2.0")
        #expect(s.directCount == nil)
        #expect(source(s, .registry, "registry.yarnpkg.com") == 2 && source(s, .git, "github.com") == 2 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(integrity: 2, gitCommit: 1, gitNoCommit: 1, unpinned: 1))
        #expect(s.licences == nil)
    }

    @Test func berryWithWorkspaces() throws {
        let text = """
        # This file is generated by running "yarn install" inside your project.
        # Manual changes might be lost - proceed with caution!

        __metadata:
          version: 8
          cacheKey: 10c0

        "@acme/core@npm:^3.0.0":
          version: 3.0.1
          resolution: "@acme/core@npm:3.0.1"
          checksum: 10c0/aaaa
          languageName: node
          linkType: hard

        "acme-app@workspace:.":
          version: 0.0.0-use.local
          resolution: "acme-app@workspace:."
          dependencies:
            acme-notes: "npm:^1.1.0"
            harbor-utils: "https://github.com/acme/harbor-utils.git#commit=\(sha)"
            local-kit: "workspace:packages/local-kit"
          languageName: unknown
          linkType: soft

        "acme-notes@npm:^1.0.0, acme-notes@npm:^1.1.0":
          version: 1.2.0
          resolution: "acme-notes@npm:1.2.0"
          dependencies:
            "@acme/core": "npm:^3.0.0"
          checksum: 10c0/bbbb
          languageName: node
          linkType: hard

        "harbor-utils@https://github.com/acme/harbor-utils.git#commit=\(sha)":
          version: 0.4.0
          resolution: "harbor-utils@https://github.com/acme/harbor-utils.git#commit=\(sha)"
          languageName: node
          linkType: hard

        "local-kit@workspace:packages/local-kit":
          version: 0.0.0-use.local
          resolution: "local-kit@workspace:packages/local-kit"
          languageName: unknown
          linkType: soft
        """
        let s = try #require(read(text, "yarn.lock"))
        #expect(s.ecosystem == .yarn && s.formatVersion == "8")
        #expect(s.totalPackages == 4)                     // the project itself (workspace:.) is not a package
        #expect(s.directCount == 2)
        #expect(s.packages.filter { $0.isDirect == true }.map(\.name) == ["acme-notes", "harbor-utils"])
        #expect(source(s, .registry, nil) == 2 && source(s, .git, "github.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(integrity: 2, gitCommit: 1, unpinned: 1))
    }

    @Test func textThatIsNotAYarnLockIsNil() {
        #expect(read("hello world\nthis is not a lockfile\n", "yarn.lock") == nil)
        #expect(read("", "yarn.lock") == nil)
    }
}

// MARK: - pnpm

@Suite("pnpm lockfiles")
struct PNPMLockfileTests {
    @Test func version9ReadsPackagesAndImporters() throws {
        let text = """
        lockfileVersion: '9.0'

        settings:
          autoInstallPeers: true
          excludeLinksFromLockfile: false

        importers:

          .:
            dependencies:
              acme-notes:
                specifier: ^1.1.0
                version: 1.2.0
              harbor-utils:
                specifier: github:acme/harbor-utils#0123456
                version: https://codeload.github.com/acme/harbor-utils/tar.gz/\(sha)
              react-lite:
                specifier: ^18.0.0
                version: 18.2.0(peer-kit@1.0.0)
            devDependencies:
              local-kit:
                specifier: workspace:*
                version: link:packages/local-kit

          packages/local-kit: {}

        packages:

          '@acme/core@3.0.1':
            resolution: {integrity: sha512-AAAA}

          acme-notes@1.2.0:
            resolution: {integrity: sha512-BBBB}

          harbor-utils@https://codeload.github.com/acme/harbor-utils/tar.gz/\(sha):
            resolution: {tarball: https://codeload.github.com/acme/harbor-utils/tar.gz/\(sha)}
            version: 0.4.0

          peer-kit@1.0.0:
            resolution: {integrity: sha512-CCCC}

          react-lite@18.2.0:
            resolution: {integrity: sha512-DDDD}
            peerDependencies:
              peer-kit: ^1.0.0

          tarball-thing@https://files.example.com/tarball-thing-1.0.0.tgz:
            resolution: {tarball: https://files.example.com/tarball-thing-1.0.0.tgz}
            version: 1.0.0

        snapshots:

          '@acme/core@3.0.1': {}

          acme-notes@1.2.0:
            dependencies:
              '@acme/core': 3.0.1

          react-lite@18.2.0(peer-kit@1.0.0):
            dependencies:
              peer-kit: 1.0.0
        """
        let s = try #require(read(text, "pnpm-lock.yaml"))
        #expect(s.ecosystem == .pnpm && s.formatVersion == "9.0")
        #expect(s.totalPackages == 6)
        #expect(s.packages.map(\.name) == ["@acme/core", "acme-notes", "harbor-utils", "peer-kit", "react-lite", "tarball-thing"])
        #expect(s.packages[2].version == "0.4.0")
        #expect(s.directCount == 3)
        #expect(s.packages.filter { $0.isDirect == true }.map(\.name) == ["acme-notes", "harbor-utils", "react-lite"])
        #expect(source(s, .registry, nil) == 4 && source(s, .git, "github.com") == 1 && source(s, .url, "files.example.com") == 1)
        #expect(s.pinning == pins(integrity: 4, gitCommit: 1, unpinned: 1))
    }

    @Test func version5CollapsesPeerVariants() throws {
        let text = """
        lockfileVersion: 5.4

        specifiers:
          acme-notes: ^1.1.0
          react-lite: ^18.0.0

        dependencies:
          acme-notes: 1.2.0
          react-lite: 18.2.0_peer-kit@1.0.0

        devDependencies:
          harbor-utils: github.com/acme/harbor-utils/\(sha)

        packages:

          /@acme/core/3.0.1:
            resolution: {integrity: sha512-AAAA}
            dev: false

          /acme-notes/1.2.0:
            resolution: {integrity: sha512-BBBB}
            dependencies:
              '@acme/core': 3.0.1
            dev: false

          /react-lite/18.2.0_peer-kit@1.0.0:
            resolution: {integrity: sha512-DDDD}
            dev: false

          /react-lite/18.2.0_peer-kit@2.0.0:
            resolution: {integrity: sha512-DDDD}
            dev: false

          /peer-kit/1.0.0:
            resolution: {integrity: sha512-CCCC}

          github.com/acme/harbor-utils/\(sha):
            resolution: {tarball: https://codeload.github.com/acme/harbor-utils/tar.gz/\(sha)}
            name: harbor-utils
            version: 0.4.0
            dev: true
        """
        let s = try #require(read(text, "pnpm-lock.yaml"))
        #expect(s.formatVersion == "5.4")
        #expect(s.totalPackages == 5)
        #expect(s.packages.map(\.name) == ["@acme/core", "acme-notes", "react-lite", "peer-kit", "harbor-utils"])
        #expect(s.packages[2].version == "18.2.0")
        #expect(s.directCount == 3)
        #expect(source(s, .registry, nil) == 4 && source(s, .git, "github.com") == 1)
        #expect(s.pinning == pins(integrity: 4, gitCommit: 1))
    }

    @Test func version6ReadsSlashKeys() throws {
        let text = """
        lockfileVersion: '6.0'

        dependencies:
          acme-notes:
            specifier: ^1.1.0
            version: 1.2.0

        packages:

          /acme-notes@1.2.0:
            resolution: {integrity: sha512-BBBB}
            dev: false

          /@acme/core@3.0.1(peer-kit@1.0.0):
            resolution:
              integrity: sha512-AAAA
            dev: false
        """
        let s = try #require(read(text, "pnpm-lock.yaml"))
        #expect(s.formatVersion == "6.0" && s.totalPackages == 2 && s.directCount == 1)
        #expect(s.packages.map(\.name) == ["acme-notes", "@acme/core"])
        #expect(s.packages[1].version == "3.0.1")
        #expect(s.pinning == pins(integrity: 2))
    }

    @Test func withoutALockfileVersionItIsNilAndGarbledEntriesArePartial() throws {
        #expect(read("packages:\n  acme@1.0.0:\n    resolution: {}\n", "pnpm-lock.yaml") == nil)
        let s = try #require(read("lockfileVersion: '9.0'\npackages:\n  acme-notes@1.2.0:\n    resolution: {integrity: sha512-A\n  ::::\n\t\t{{{\n", "pnpm-lock.yaml"))
        #expect(s.totalPackages >= 1 && s.packages.first?.name == "acme-notes")
    }
}

// MARK: - bun

@Suite("bun lockfiles")
struct BunLockfileTests {
    static let text = """
    {
      "lockfileVersion": 1,
      "workspaces": {
        "": {
          "name": "acme-app",
          "dependencies": {
            "acme-notes": "^1.1.0",
            "harbor-utils": "github:acme/harbor-utils#0123456",
          },
          "devDependencies": {
            "tiny-lint": "^0.3.0",
          },
        },
        "packages/local-kit": {
          "name": "local-kit",
          "version": "0.0.1",
        },
      },
      // invented packages
      "packages": {
        "@acme/core": ["@acme/core@3.0.1", "", {}, "sha512-AAAA"],
        "acme-notes": ["acme-notes@1.2.0", "", { "dependencies": { "@acme/core": "^3.0.0" } }, "sha512-BBBB"],
        "harbor-utils": ["harbor-utils@github:acme/harbor-utils#0123456", {}, "acme-harbor-utils-0123456"],
        "local-kit": ["local-kit@workspace:packages/local-kit"],
        "tiny-lint": ["tiny-lint@0.3.2", "https://npm.example.com/", {}, "sha512-CCCC"],
        "tiny-lint/@acme/core": ["@acme/core@2.0.0", "", {}, "sha512-DDDD"],
      }
    }
    """

    @Test func textLockfileWithTrailingCommasAndComments() throws {
        let s = try #require(read(Self.text, "bun.lock"))
        #expect(s.ecosystem == .bun && s.formatVersion == "1")
        #expect(s.totalPackages == 6 && !s.truncated)
        #expect(s.directCount == 3)
        #expect(s.packages.filter { $0.isDirect == true }.map(\.name) == ["acme-notes", "harbor-utils", "tiny-lint"])
        #expect(source(s, .registry, nil) == 3 && source(s, .registry, "npm.example.com") == 1)
        #expect(source(s, .git, "github.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(integrity: 4, gitCommit: 1, unpinned: 1))
    }

    @Test func binaryBunLockbIsNotRead() {
        #expect(LockfileReader.read(data: Data([0x23, 0x21, 0x2F, 0x00, 0x01, 0x02, 0xFF]), fileName: "bun.lockb") == nil)
        #expect(LockfileReader.read(data: Data(Self.text.utf8), fileName: "bun.lockb") == nil)
        #expect(!LockfileReader.knownFileNames.contains("bun.lockb"))
        #expect(LockfileReader.read(data: Data([0x7B, 0x00, 0x7D]), fileName: "bun.lock") == nil)
    }
}

// MARK: - TOML formats

@Suite("Cargo, poetry and uv lockfiles")
struct TOMLLockfileTests {
    @Test func cargo() throws {
        let text = """
        # This file is automatically @generated by Cargo.
        # It is not intended for manual editing.
        version = 4

        [[package]]
        name = "acme-cli"
        version = "0.1.0"
        dependencies = [
         "acme-notes",
         "harbor-utils",
         "serde-lite 1.0.2",
        ]

        [[package]]
        name = "acme-notes"
        version = "1.2.0"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        checksum = "aaaa"
        dependencies = [
         "serde-lite 0.9.1",
        ]

        [[package]]
        name = "harbor-utils"
        version = "0.4.0"
        source = "git+https://github.com/acme/harbor-utils?branch=main#\(sha)"

        [[package]]
        name = "serde-lite"
        version = "0.9.1"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        checksum = "bbbb"

        [[package]]
        name = "serde-lite"
        version = "1.0.2"
        source = "sparse+https://index.crates.io/"
        checksum = "cccc"

        [[package]]
        name = "vendored-kit"
        version = "0.2.0"
        source = "registry+https://crates.example.com/index"
        """
        let s = try #require(read(text, "Cargo.lock"))
        #expect(s.ecosystem == .cargo && s.formatVersion == "4")
        #expect(s.totalPackages == 6)
        #expect(s.directCount == 3)
        #expect(s.packages.filter { $0.isDirect == true }.map { "\($0.name) \($0.version ?? "")" } == ["acme-notes 1.2.0", "harbor-utils 0.4.0", "serde-lite 1.0.2"])
        #expect(source(s, .registry, "crates.io") == 3 && source(s, .git, "github.com") == 1)
        #expect(source(s, .path, nil) == 1 && source(s, .registry, "crates.example.com") == 1)
        #expect(s.pinning == pins(exact: 1, integrity: 3, gitCommit: 1, unpinned: 1))
        #expect(s.licences == nil)
    }

    @Test func poetry() throws {
        let text = """
        # This file is automatically @generated by Poetry 1.8.3 and should not be changed by hand.

        [[package]]
        name = "acme-notes"
        version = "1.2.0"
        description = "Invented notes library"
        optional = false
        python-versions = ">=3.9"
        files = [
            {file = "acme_notes-1.2.0-py3-none-any.whl", hash = "sha256:aaaa"},
            {file = "acme_notes-1.2.0.tar.gz", hash = "sha256:bbbb"},
        ]

        [package.dependencies]
        tiny-dep = ">=0.1"

        [[package]]
        name = "harbor-utils"
        version = "0.4.0"
        description = ""
        optional = false
        python-versions = "*"
        files = []
        develop = false

        [package.source]
        type = "git"
        url = "https://github.com/acme/harbor-utils.git"
        reference = "main"
        resolved_reference = "\(sha)"

        [[package]]
        name = "private-kit"
        version = "2.0.0"
        description = "Invented"
        optional = false
        python-versions = "*"
        files = [
            {file = "private_kit-2.0.0.tar.gz", hash = "sha256:cccc"},
        ]

        [package.source]
        type = "legacy"
        url = "https://pypi.example.com/simple"
        reference = "internal"

        [[package]]
        name = "local-kit"
        version = "0.0.1"
        description = ""
        optional = false
        python-versions = "*"
        files = []
        develop = true

        [package.source]
        type = "directory"
        url = "libs/local-kit"

        [metadata]
        lock-version = "2.0"
        python-versions = "^3.9"
        content-hash = "dddd"
        """
        let s = try #require(read(text, "poetry.lock"))
        #expect(s.ecosystem == .poetry && s.formatVersion == "2.0")
        #expect(s.totalPackages == 4 && s.directCount == nil)
        #expect(source(s, .registry, nil) == 1 && source(s, .git, "github.com") == 1)
        #expect(source(s, .registry, "pypi.example.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(integrity: 2, gitCommit: 1, unpinned: 1))
    }

    @Test func uv() throws {
        let text = """
        version = 1
        revision = 2
        requires-python = ">=3.12"

        [[package]]
        name = "acme-app"
        version = "0.1.0"
        source = { virtual = "." }
        dependencies = [
            { name = "acme-notes" },
            { name = "harbor-utils" },
        ]

        [package.dev-dependencies]
        dev = [
            { name = "tiny-lint" },
        ]

        [package.metadata]
        requires-dist = [
            { name = "acme-notes", specifier = ">=1.1" },
        ]

        [[package]]
        name = "acme-notes"
        version = "1.2.0"
        source = { registry = "https://pypi.org/simple" }
        dependencies = [
            { name = "tiny-dep" },
        ]
        sdist = { url = "https://files.pythonhosted.org/packages/acme_notes-1.2.0.tar.gz", hash = "sha256:aaaa", size = 1234 }
        wheels = [
            { url = "https://files.pythonhosted.org/packages/acme_notes-1.2.0-py3-none-any.whl", hash = "sha256:bbbb", size = 999 },
        ]

        [[package]]
        name = "harbor-utils"
        version = "0.4.0"
        source = { git = "https://github.com/acme/harbor-utils?rev=main#\(sha)" }

        [[package]]
        name = "tiny-dep"
        version = "0.1.4"
        source = { registry = "https://pypi.org/simple" }
        wheels = [
            { url = "https://files.pythonhosted.org/packages/tiny_dep-0.1.4-py3-none-any.whl", hash = "sha256:cccc", size = 10 },
        ]

        [[package]]
        name = "tiny-lint"
        version = "0.3.2"
        source = { url = "https://files.example.com/tiny_lint-0.3.2.tar.gz" }
        """
        let s = try #require(read(text, "uv.lock"))
        #expect(s.ecosystem == .uv && s.formatVersion == "1")
        #expect(s.totalPackages == 4)                     // the project itself (virtual = ".") is not a package
        #expect(s.directCount == 3)
        #expect(s.packages.filter { $0.isDirect == true }.map(\.name) == ["acme-notes", "harbor-utils", "tiny-lint"])
        #expect(source(s, .registry, "pypi.org") == 2 && source(s, .git, "github.com") == 1 && source(s, .url, "files.example.com") == 1)
        #expect(s.pinning == pins(integrity: 2, gitCommit: 1, unpinned: 1))
    }

    @Test func malformedTOMLGivesNilOrAPartialSummary() throws {
        #expect(read("[[package]\nname = \"acme", "Cargo.lock") == nil)
        #expect(read("just some words", "poetry.lock") == nil)
        let partial = "version = 3\n[[package]]\nname = \"acme-notes\"\nversion = \"1.2.0\"\nchecksum = \"aa\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n[[package]]\nname = \"broken\nversion = [1, 2\n= = =\n"
        let s = try #require(read(partial, "Cargo.lock"))
        #expect(s.packages.first?.name == "acme-notes" && s.pinning.withIntegrity == 1)
        let deep = "version = 1\nx = " + String(repeating: "[", count: 20_000) + "\n[[package]]\nname = \"acme-notes\"\n"
        let d = try #require(read(deep, "uv.lock"))
        #expect(d.totalPackages == 1)
    }
}

// MARK: - Ruby, CocoaPods

@Suite("Gemfile.lock and Podfile.lock")
struct IndentedLockfileTests {
    @Test func bundler() throws {
        let text = """
        GIT
          remote: https://github.com/acme/harbor-utils.git
          revision: \(sha)
          branch: main
          specs:
            harbor-utils (0.4.0)
              acme-notes (>= 1.0)

        PATH
          remote: engines/local_kit
          specs:
            local_kit (0.0.1)

        GEM
          remote: https://rubygems.org/
          specs:
            acme-notes (1.2.0)
              tiny-dep (~> 0.1)
            nokogiri-lite (1.15.0-arm64-darwin)
            nokogiri-lite (1.15.0-x86_64-linux)
            tiny-dep (0.1.4)

        PLATFORMS
          arm64-darwin
          x86_64-linux

        DEPENDENCIES
          acme-notes (~> 1.2)
          harbor-utils!
          local_kit!
          nokogiri-lite

        CHECKSUMS
          acme-notes (1.2.0) sha256=aaaa
          tiny-dep (0.1.4) sha256=bbbb

        BUNDLED WITH
           2.6.2
        """
        let s = try #require(read(text, "Gemfile.lock"))
        #expect(s.ecosystem == .bundler && s.formatVersion == nil)
        #expect(s.totalPackages == 6)
        #expect(s.directCount == 5)
        #expect(s.packages.first { $0.name == "tiny-dep" }?.isDirect == false)
        #expect(source(s, .registry, "rubygems.org") == 4 && source(s, .git, "github.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(exact: 2, integrity: 2, gitCommit: 1, unpinned: 1))
        #expect(s.packages.first { $0.name == "local_kit" }?.source == "engines/local_kit")
    }

    @Test func cocoapods() throws {
        let text = """
        PODS:
          - AcmeKit (1.2.0):
            - AcmeKit/Core (= 1.2.0)
          - AcmeKit/Core (1.2.0)
          - HarborUtils (0.4.0)
          - LocalKit (0.0.1)
          - TinyLog (2.1.0)

        DEPENDENCIES:
          - AcmeKit (~> 1.2)
          - HarborUtils (from `https://github.com/acme/harbor-utils.git`, branch `main`)
          - LocalKit (from `../LocalKit`)

        SPEC REPOS:
          trunk:
            - AcmeKit
            - TinyLog

        EXTERNAL SOURCES:
          HarborUtils:
            :branch: main
            :git: https://github.com/acme/harbor-utils.git
          LocalKit:
            :path: "../LocalKit"

        CHECKOUT OPTIONS:
          HarborUtils:
            :commit: \(sha)
            :git: https://github.com/acme/harbor-utils.git

        SPEC CHECKSUMS:
          AcmeKit: aaaa
          HarborUtils: bbbb
          LocalKit: cccc
          TinyLog: dddd

        PODFILE CHECKSUM: eeee

        COCOAPODS: 1.15.2
        """
        let s = try #require(read(text, "Podfile.lock"))
        #expect(s.ecosystem == .cocoapods && s.formatVersion == nil)
        #expect(s.totalPackages == 4)                     // AcmeKit/Core is part of AcmeKit
        #expect(s.packages.map(\.name) == ["AcmeKit", "HarborUtils", "LocalKit", "TinyLog"])
        #expect(s.directCount == 3)
        #expect(source(s, .registry, "trunk") == 2 && source(s, .git, "github.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(integrity: 2, gitCommit: 1, unpinned: 1))
    }

    @Test func malformedIndentedFilesAreNil() {
        #expect(read("nothing here\n  at all\n", "Gemfile.lock") == nil)
        #expect(read("DEPENDENCIES:\n  - AcmeKit\n", "Podfile.lock") == nil)
        #expect(read("PODS:\n  - \n  -\n  : :\n", "Podfile.lock")?.totalPackages ?? 0 <= 1)
    }
}

// MARK: - JSON and line formats

@Suite("Pipfile.lock, go.sum, Package.resolved and composer.lock")
struct OtherLockfileTests {
    @Test func pipenv() throws {
        let text = """
        {
            "_meta": {
                "hash": {"sha256": "eeee"},
                "pipfile-spec": 6,
                "requires": {"python_version": "3.12"},
                "sources": [
                    {"name": "pypi", "url": "https://pypi.org/simple", "verify_ssl": true},
                    {"name": "internal", "url": "https://pypi.example.com/simple", "verify_ssl": true}
                ]
            },
            "default": {
                "acme-notes": {"hashes": ["sha256:aaaa"], "index": "pypi", "version": "==1.2.0"},
                "harbor-utils": {"git": "https://github.com/acme/harbor-utils.git", "ref": "\(sha)"},
                "private-kit": {"hashes": ["sha256:cccc"], "index": "internal", "version": "==2.0.0"}
            },
            "develop": {
                "acme-notes": {"hashes": ["sha256:aaaa"], "index": "pypi", "version": "==1.2.0"},
                "local-kit": {"editable": true, "path": "./libs/local-kit"},
                "tiny-lint": {"index": "pypi", "version": "==0.3.2"}
            }
        }
        """
        let s = try #require(read(text, "Pipfile.lock"))
        #expect(s.ecosystem == .pipenv && s.formatVersion == "6")
        #expect(s.totalPackages == 5 && s.directCount == nil)
        #expect(s.packages.first?.version == "1.2.0")
        #expect(source(s, .registry, "pypi.org") == 2 && source(s, .registry, "pypi.example.com") == 1)
        #expect(source(s, .git, "github.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(exact: 1, integrity: 2, gitCommit: 1, unpinned: 1))
        #expect(read("[]", "Pipfile.lock") == nil)
    }

    @Test func goSum() throws {
        let text = """
        github.com/acme/notes v1.2.0 h1:aaaa=
        github.com/acme/notes v1.2.0/go.mod h1:bbbb=
        github.com/acme/harbor v0.4.0 h1:cccc=
        github.com/acme/harbor v0.4.0/go.mod h1:dddd=
        golang.org/x/acme-text v0.3.0/go.mod h1:eeee=
        gopkg.in/acme-yaml.v3 v3.0.1 h1:ffff=
        gopkg.in/acme-yaml.v3 v3.0.1 h1:ffff=
        """
        let s = try #require(read(text, "go.sum"))
        #expect(s.ecosystem == .goModules && s.formatVersion == nil)
        #expect(s.totalPackages == 3 && s.directCount == nil)
        #expect(source(s, .registry, "github.com") == 2 && source(s, .registry, "gopkg.in") == 1)
        #expect(s.pinning == pins(integrity: 3))
        #expect(read("this is\nnot a go.sum file\n", "go.sum") == nil)
        #expect(read("", "go.sum")?.totalPackages == 0)
    }

    @Test func packageResolvedVersions1And3() throws {
        let v3 = """
        {
          "originHash" : "abcd",
          "pins" : [
            { "identity" : "acme-notes", "kind" : "remoteSourceControl", "location" : "https://github.com/acme/acme-notes.git",
              "state" : { "revision" : "\(sha)", "version" : "1.2.0" } },
            { "identity" : "harbor-utils", "kind" : "remoteSourceControl", "location" : "git@gitlab.com:acme/harbor-utils.git",
              "state" : { "branch" : "main", "revision" : "89abcdef0123456789abcdef0123456789abcdef" } },
            { "identity" : "local-kit", "kind" : "localSourceControl", "location" : "/Users/example/local-kit",
              "state" : { "revision" : "fedcba9876543210fedcba9876543210fedcba98" } },
            { "identity" : "acme.registry-kit", "kind" : "registry", "location" : "", "state" : { "version" : "2.0.0" } }
          ],
          "version" : 3
        }
        """
        let s = try #require(read(v3, "Package.resolved"))
        #expect(s.ecosystem == .swiftPM && s.formatVersion == "3")
        #expect(s.totalPackages == 4)
        #expect(source(s, .git, "github.com") == 1 && source(s, .git, "gitlab.com") == 1)
        #expect(source(s, .path, nil) == 1 && source(s, .registry, nil) == 1)
        #expect(s.pinning == pins(exact: 1, gitCommit: 2, unpinned: 1))
        #expect(s.packages[1].version == "main")

        let v1 = """
        { "object": { "pins": [ { "package": "AcmeNotes", "repositoryURL": "https://github.com/acme/acme-notes",
          "state": { "branch": null, "revision": "\(sha)", "version": "1.2.0" } } ] }, "version": 1 }
        """
        let o = try #require(read(v1, "Package.resolved"))
        #expect(o.formatVersion == "1" && o.totalPackages == 1 && o.packages.first?.name == "AcmeNotes")
        #expect(o.pinning == pins(gitCommit: 1))
        #expect(read("{\"version\": 2}", "Package.resolved") == nil)
    }

    @Test func composerCarriesLicences() throws {
        let text = """
        {
            "_readme": ["This file locks the dependencies of your project to a known state"],
            "content-hash": "abcd",
            "packages": [
                {"name": "acme/notes", "version": "1.2.0",
                 "source": {"type": "git", "url": "https://github.com/acme/notes.git", "reference": "\(sha)"},
                 "dist": {"type": "zip", "url": "https://api.github.com/repos/acme/notes/zipball/\(sha)", "reference": "\(sha)", "shasum": ""},
                 "license": ["MIT"], "notification-url": "https://packagist.org/downloads/"},
                {"name": "acme/harbor", "version": "dev-main",
                 "source": {"type": "git", "url": "https://github.com/acme/harbor.git", "reference": "89abcdef0123456789abcdef0123456789abcdef"},
                 "license": ["Apache-2.0", "MIT"], "notification-url": "https://packagist.org/downloads/"},
                {"name": "acme/local-kit", "version": "dev-main", "dist": {"type": "path", "url": "./packages/local-kit", "reference": "x"}, "license": ["MIT"]}
            ],
            "packages-dev": [
                {"name": "acme/tiny-lint", "version": "v0.3.2",
                 "dist": {"type": "zip", "url": "https://repo.example.com/tiny-lint.zip", "shasum": "cccc"},
                 "license": ["MIT"], "notification-url": "https://packagist.org/downloads/"}
            ],
            "plugin-api-version": "2.6.0"
        }
        """
        let s = try #require(read(text, "composer.lock"))
        #expect(s.ecosystem == .composer && s.formatVersion == nil)
        #expect(s.totalPackages == 4 && s.directCount == nil)
        #expect(source(s, .registry, "packagist.org") == 2 && source(s, .git, "github.com") == 1 && source(s, .path, nil) == 1)
        #expect(s.pinning == pins(exact: 1, integrity: 1, gitCommit: 1, unpinned: 1))
        #expect(s.licences == ["MIT": 3, "Apache-2.0 OR MIT": 1])
        #expect(s.packages[1].licence == "Apache-2.0 OR MIT")
        #expect(read("{\"content-hash\": \"x\"}", "composer.lock") == nil)
    }
}

// MARK: - Routing and limits

@Suite("Lockfile routing and limits")
struct LockfileLimitTests {
    @Test func namesRouteCaseInsensitivelyAndUnknownContentIsNil() throws {
        for name in ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "cargo.lock",
                     "gemfile.lock", "poetry.lock", "uv.lock", "pipfile.lock", "go.sum", "package.resolved", "composer.lock", "podfile.lock"] {
            #expect(LockfileReader.knownFileNames.contains(name))
        }
        #expect(LockfileReader.knownFileNames.allSatisfy { $0 == $0.lowercased() })
        let cargo = "version = 3\n[[package]]\nname = \"acme-notes\"\nversion = \"1.2.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"aa\"\n"
        #expect(LockfileReader.read(data: Data(cargo.utf8), fileName: "/tmp/acme/CARGO.LOCK")?.ecosystem == .cargo)
        #expect(LockfileReader.read(data: Data(cargo.utf8), fileName: "vendored.lock")?.ecosystem == .cargo)    // by content
        #expect(LockfileReader.read(data: Data("{\"a\": 1}".utf8), fileName: "settings.json") == nil)
        #expect(LockfileReader.read(data: Data("title = \"x\"\n".utf8), fileName: "config.toml") == nil)
        #expect(LockfileReader.read(data: Data("name: acme\n".utf8), fileName: "config.yaml") == nil)
        #expect(LockfileReader.read(data: Data(NPMLockfileTests.v3.utf8), fileName: "lock.json")?.ecosystem == .npm)
        #expect(LockfileReader.read(data: Data(BunLockfileTests.text.utf8), fileName: "lock.jsonc")?.ecosystem == .bun)
    }

    @Test func packagesPastTheCapAreCountedNotKept() throws {
        var text = "version = 4\n"
        for n in 0..<6_000 {
            text += "[[package]]\nname = \"acme-crate-\(n)\"\nversion = \"1.0.\(n)\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"aa\"\n"
        }
        let s = try #require(read(text, "Cargo.lock"))
        #expect(s.packages.count == LockfileReader.maxPackages && s.totalPackages == 6_000)
        #expect(s.truncated && s.pinning.withIntegrity == 6_000 && source(s, .registry, "crates.io") == 6_000)
    }

    @Test func inputPastEightMegabytesIsReadPartially() throws {
        var lines: [String] = []
        let hash = String(repeating: "A", count: 43)
        for n in 0..<110_000 { lines.append("example.com/acme/module\(n) v1.0.0 h1:\(hash)=") }
        let data = Data(lines.joined(separator: "\n").utf8)
        #expect(data.count > LockfileReader.maxBytes)
        let s = try #require(LockfileReader.read(data: data, fileName: "go.sum"))
        #expect(s.truncated)
        #expect(s.totalPackages > 50_000 && s.totalPackages < 110_000)
        #expect(s.packages.count == LockfileReader.maxPackages)
        #expect(s.packages.last?.name.hasPrefix("example.com/acme/module") == true)
    }

    @Test func aLargePackageLockCutAtEightMegabytesStillGivesAPartialSummary() throws {
        var text = "{\"lockfileVersion\": 3, \"packages\": {\"\": {\"name\": \"acme-app\"},\n"
        let entry = "\"version\": \"1.0.0\", \"resolved\": \"https://registry.npmjs.org/acme/-/acme-1.0.0.tgz\", \"integrity\": \"sha512-\(String(repeating: "B", count: 60))\", \"license\": \"MIT\"}"
        var n = 0
        while text.utf8.count < LockfileReader.maxBytes + 100_000 {
            text += "\"node_modules/acme-\(n)\": {\(entry),\n"
            n += 1
        }
        text += "}}"
        let s = try #require(read(text, "package-lock.json"))
        #expect(s.truncated && s.totalPackages > 1_000 && s.totalPackages < n)
        #expect(s.directCount == 0 && (s.licences?["MIT"] ?? 0) >= s.totalPackages - 1)
    }
}

// MARK: - Robustness

@Suite("Lockfile reader on damaged input")
struct LockfileDamageTests {
    static let samples: [String] = [
        NPMLockfileTests.v3,
        BunLockfileTests.text,
        "# yarn lockfile v1\n\nacme-notes@^1.0.0:\n  version \"1.2.0\"\n  resolved \"https://registry.yarnpkg.com/acme-notes/-/acme-notes-1.2.0.tgz\"\n",
        "__metadata:\n  version: 8\n\n\"acme-notes@npm:^1.0.0\":\n  version: 1.2.0\n  resolution: \"acme-notes@npm:1.2.0\"\n  checksum: 10c0/aa\n",
        "lockfileVersion: '9.0'\nimporters:\n  .:\n    dependencies:\n      acme-notes:\n        specifier: ^1\n        version: 1.2.0\npackages:\n  acme-notes@1.2.0:\n    resolution: {integrity: sha512-A}\n",
        "version = 1\n[[package]]\nname = \"acme-notes\"\nversion = \"1.2.0\"\nsource = { registry = \"https://pypi.org/simple\" }\nwheels = [\n  { url = \"https://x.example/a.whl\", hash = \"sha256:aa\" },\n]\n",
        "GEM\n  remote: https://rubygems.org/\n  specs:\n    acme-notes (1.2.0)\n\nDEPENDENCIES\n  acme-notes\n",
        "PODS:\n  - AcmeKit (1.2.0)\n\nDEPENDENCIES:\n  - AcmeKit\n\nSPEC REPOS:\n  trunk:\n    - AcmeKit\n",
        "{\"pins\": [{\"identity\": \"acme\", \"location\": \"https://github.com/acme/acme.git\", \"state\": {\"revision\": \"\(sha)\"}}], \"version\": 2}",
        "{\"_meta\": {\"pipfile-spec\": 6, \"sources\": [{\"name\": \"pypi\", \"url\": \"https://pypi.org/simple\"}]}, \"default\": {\"acme\": {\"version\": \"==1.0\", \"hashes\": [\"sha256:a\"]}}}",
        "github.com/acme/notes v1.2.0 h1:aaaa=\ngithub.com/acme/notes v1.2.0/go.mod h1:bbbb=\n",
    ]

    /// Every prefix of every sample, read under every known name: never a crash, and the counts always add up.
    @Test func everyPrefixUnderEveryNameIsSafe() {
        for sample in Self.samples {
            let bytes = Array(sample.utf8)
            for cut in stride(from: 0, through: bytes.count, by: 3) {
                let data = Data(bytes[0..<cut])
                for name in LockfileReader.knownFileNames.sorted() + ["unknown.lock"] {
                    if let s = LockfileReader.read(data: data, fileName: name) {
                        #expect(s.pinning.total == s.totalPackages)
                        #expect(s.sources.reduce(0) { $0 + $1.count } == s.totalPackages)
                    }
                }
            }
        }
    }

    /// Bytes flipped at pseudo-random places (a fixed seed, so every run is the same) never crash the reader.
    @Test func flippedBytesAreSafe() {
        var seed: UInt64 = 0x5EED_1234
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let noise: [UInt8] = Array("{}[]\"':,#\n -_/@=()".utf8) + [0xFF, 0xC3]
        for sample in Self.samples {
            for _ in 0..<40 {
                var bytes = Array(sample.utf8)
                for _ in 0..<4 where !bytes.isEmpty {
                    bytes[Int(next() % UInt64(bytes.count))] = noise[Int(next() % UInt64(noise.count))]
                }
                for name in ["package-lock.json", "bun.lock", "yarn.lock", "pnpm-lock.yaml", "uv.lock", "Gemfile.lock",
                             "Podfile.lock", "Package.resolved", "Pipfile.lock", "go.sum", "composer.lock", "x.lock"] {
                    if let s = LockfileReader.read(data: Data(bytes), fileName: name) {
                        #expect(s.pinning.total == s.totalPackages)
                    }
                }
            }
        }
    }
}
