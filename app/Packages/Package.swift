// swift-tools-version: 6.0
// Vitrine's libraries (ARCHITECTURE §3, G-7). XcodeGen links these products into VitrinePreviewKit; each library
// keeps its own tests here, run by `swift test` and by the Vitrine scheme. roadmap: S-14
import PackageDescription

let package = Package(
    name: "VitrineKit",
    // English is the source language; each library with words people see keeps its own String Catalog (H-6, S-12).
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VitrineSupport", targets: ["VitrineSupport"]),
        .library(name: "VitrineDocument", targets: ["VitrineDocument"]),
        .library(name: "VitrineData", targets: ["VitrineData"]),
        .library(name: "VitrineArchive", targets: ["VitrineArchive"]),
        .library(name: "VitrineBinary", targets: ["VitrineBinary"]),
        .library(name: "VitrineText", targets: ["VitrineText"]),
        .library(name: "VitrineUI", targets: ["VitrineUI"]),
        .library(name: "VitrineGit", targets: ["VitrineGit"]),
        .library(name: "VitrineCompare", targets: ["VitrineCompare"]),
        .library(name: "VitrineUpdate", targets: ["VitrineUpdate"]),
        .library(name: "VitrineDetect", targets: ["VitrineDetect"]),
        .library(name: "VitrineMCP", targets: ["VitrineMCP"]),
        .library(name: "VitrineHelperKit", targets: ["VitrineHelperKit"]),
        .library(name: "VitrineTokenizers", targets: ["VitrineTokenizers"]),
        .library(name: "VitrineConnector", targets: ["VitrineConnector"]),
        .library(name: "VitrineSpotlight", targets: ["VitrineSpotlight"]),
        .library(name: "VitrineTrust", targets: ["VitrineTrust"]),
        .library(name: "VitrineThumbnail", targets: ["VitrineThumbnail"]),
        .library(name: "VitrineEngineering", targets: ["VitrineEngineering"]),
        .library(name: "VitrineFormats", targets: ["VitrineFormats"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", branch: "gfm"),
    ],
    targets: [
        .target(name: "VitrineSupport", resources: [.process("Localizable.xcstrings")]),
        .target(name: "VitrineDocument", dependencies: ["VitrineSupport"], resources: [.process("Localizable.xcstrings")]),
        // The column-file readers (B-4, G-20) use the vendored Zstandard and LZ4 decoders and read xlsx parts through
        // VitrineArchive's zip reader.
        .target(name: "VitrineData", dependencies: ["VitrineSupport", "VitrineArchive", "CZstd", "CLZ4"],
                resources: [.process("Localizable.xcstrings")]),
        // The system libarchive behind the formats the Swift readers do not cover (G-15): our own declarations of its
        // read API in a system-library module, linked against /usr/lib/libarchive.2.dylib through the SDK's .tbd.
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        // Zstandard and LZ4 decoders, vendored from their releases (G-15 correction, the maintainer's go 2026-10-30): this Mac's
        // libarchive would start an outside program for them, so VitrineArchive decodes them itself
        // (VENDORED.md in each folder: source, version, SHA-256, what was copied).
        .target(name: "CZstd", exclude: ["LICENSE", "VENDORED.md"], publicHeadersPath: "include",
                cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0"), .define("ZSTD_TRACE", to: "0")]),
        .target(name: "CLZ4", exclude: ["LICENSE", "VENDORED.md"], publicHeadersPath: "include",
                cSettings: [.define("XXH_NAMESPACE", to: "LZ4_")]),
        .target(name: "VitrineArchive", dependencies: ["VitrineSupport", "CArchive", "CZstd", "CLZ4"],
                resources: [.process("Localizable.xcstrings")],
                linkerSettings: [.linkedLibrary("archive")]),
        // VitrineArchive reads the zip around an .ipa or .apk (Info.plist, the manifest, the profile) in memory.
        .target(name: "VitrineBinary", dependencies: ["VitrineSupport", "VitrineArchive"], resources: [.process("Localizable.xcstrings")]),
        .target(name: "VitrineText", dependencies: [
            "VitrineDocument",
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ], resources: [.process("Localizable.xcstrings")]),
        .target(name: "VitrineUI", dependencies: ["VitrineSupport"]),
        .target(name: "VitrineGit", dependencies: ["VitrineSupport"], resources: [.process("Localizable.xcstrings")]),
        // The two-file compare engines beyond plain text (S-7, G-16): structural JSON, prose, notebooks, images.
        .target(name: "VitrineCompare", dependencies: ["VitrineSupport", "VitrineText", "VitrineData"], resources: [.process("Localizable.xcstrings")]),
        // G-21: Vitrine's own signed update check and verified install, ported from Obscura's (no third-party framework).
        .target(name: "VitrineUpdate", resources: [.process("Localizable.xcstrings")]),
        // G-22: Obscura's secret detectors (84, with fixtures), ported for the Claude connector and the T-4 banner.
        .target(name: "VitrineDetect", exclude: ["README.md"], resources: [.process("Localizable.xcstrings")]),
        // G-22: the Claude connector's protocol (MCP over stdio) and its worker contract; `vitrine mcp` serves it.
        .target(name: "VitrineMCP"),
        // X-3: the helper's XPC protocol and names, shared by the helper, the app and the extensions.
        .target(name: "VitrineHelperKit"),
        // A-4, G-29: exact token counts on this Mac — OpenAI's o200k_base, tiktoken's file bundled verbatim.
        .target(name: "VitrineTokenizers", dependencies: ["VitrineDocument"],
                resources: [.copy("Resources/o200k_base.tiktoken"), .copy("Resources/tiktoken-LICENSE.txt"), .process("Localizable.xcstrings")]),
        // What the connector's tools say, made from the previews' documents (the worker in the app links it).
        .target(name: "VitrineConnector", dependencies: ["VitrineMCP", "VitrineSupport", "VitrineDocument", "VitrineDetect"]),
        // S-19, X-8: the text Spotlight is given for SQLite, column files, notebooks and archives (the importer links it).
        .target(name: "VitrineSpotlight", dependencies: ["VitrineSupport", "VitrineData", "VitrineArchive", "VitrineCompare"]),
        // S-20: the trust and safety lens: dangerous scripts and links, hidden Unicode, the secrets banner (counts only).
        .target(name: "VitrineTrust", dependencies: ["VitrineDetect", "VitrineSupport"], resources: [.process("Localizable.xcstrings")]),
        // Finder thumbnails (S-18, thumbnails r3-a): Core Graphics drawings of a file's first lines, with the trust lens's marks.
        // Engineering formats (S-22): lockfiles, certificates and keys, API specs, infrastructure, Apple development files.
        .target(name: "VitrineEngineering", dependencies: ["VitrineSupport", "VitrineBinary", "VitrineData", "VitrineArchive"], resources: [.process("Localizable.xcstrings")]),
        // AI-era and everyday formats (S-21, S-23): rules and skills, MCP configs, models, pickles, JSONL, chat exports, traces, subtitles, cards, email, maps, 3D, audio, images.
        .target(name: "VitrineFormats", dependencies: ["VitrineSupport", "VitrineData", "VitrineArchive", "VitrineBinary"], resources: [.process("Localizable.xcstrings")]),
        .target(name: "VitrineThumbnail", dependencies: ["VitrineSupport", "VitrineUI", "VitrineText", "VitrineTrust"], resources: [.process("Localizable.xcstrings")]),
        // The maintainer's release tool (keygen, public key, signed feed); never shipped in the app.
        .executableTarget(name: "vitrine-release", dependencies: ["VitrineUpdate"], path: "Tools/vitrine-release"),
        .testTarget(name: "VitrineSupportTests", dependencies: ["VitrineSupport"]),
        .testTarget(name: "VitrineDocumentTests", dependencies: ["VitrineDocument"]),
        .testTarget(name: "VitrineDataTests", dependencies: ["VitrineData", "CLZ4"]),
        .testTarget(name: "VitrineArchiveTests", dependencies: ["VitrineArchive"]),
        .testTarget(name: "VitrineBinaryTests", dependencies: ["VitrineBinary", "VitrineArchive"]),
        .testTarget(name: "VitrineTextTests", dependencies: ["VitrineText"]),
        .testTarget(name: "VitrineUITests", dependencies: ["VitrineUI"]),
        .testTarget(name: "VitrineGitTests", dependencies: ["VitrineGit", "VitrineSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VitrineCompareTests", dependencies: ["VitrineCompare", "VitrineData"]),
        .testTarget(name: "VitrineUpdateTests", dependencies: ["VitrineUpdate"]),
        .testTarget(name: "VitrineDetectTests", dependencies: ["VitrineDetect"], resources: [.copy("text")]),
        .testTarget(name: "VitrineMCPTests", dependencies: ["VitrineMCP"]),
        .testTarget(name: "VitrineHelperKitTests", dependencies: ["VitrineHelperKit"]),
        .testTarget(name: "VitrineTokenizersTests", dependencies: ["VitrineTokenizers", "VitrineDocument"]),
        .testTarget(name: "VitrineTrustTests", dependencies: ["VitrineTrust", "VitrineDetect", "VitrineSupport"]),
        .testTarget(name: "VitrineThumbnailTests", dependencies: ["VitrineThumbnail", "VitrineSupport"]),
        .testTarget(name: "VitrineEngineeringTests", dependencies: ["VitrineEngineering", "VitrineSupport", "VitrineBinary"]),
        .testTarget(name: "VitrineFormatsTests", dependencies: ["VitrineFormats", "VitrineSupport", "VitrineArchive"]),
        .testTarget(name: "VitrineSpotlightTests", dependencies: ["VitrineSpotlight"], resources: [.copy("Fixtures")]),
        .testTarget(name: "VitrineConnectorTests", dependencies: ["VitrineConnector", "VitrineMCP", "VitrineDocument", "VitrineSupport"]),
    ]
)
