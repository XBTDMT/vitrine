// The signed update feed (G-21). One HTTPS file holds two fields: `manifest`, the exact bytes of a small JSON manifest
// (base64), and `signature`, a detached Ed25519 signature over those bytes (base64). The app verifies the signature
// with the public key compiled into it BEFORE it parses the manifest, so nothing unsigned is ever interpreted.
//
// Why one envelope file rather than `feed.json` + `feed.json.sig`: the two are published together and read together,
// so a cache or a half-finished publish can never pair one release's manifest with another's signature.
//
//   feed:     {"format":1,"manifest":"<base64 manifest bytes>","signature":"<base64 64-byte Ed25519 signature>"}
//   manifest: {"format":1,"bundleIdentifier":"io.github.xbtdmt.vitrine","version":"1.1.0","build":"7",
//              "url":"https://…/Vitrine-1.1.0_7.dmg","size":12345678,"sha256":"<64 hex>",
//              "minimumSystemVersion":"15.0","releaseNotesURL":"https://…"}
public import CryptoKit
public import Foundation

/// A version as Vitrine compares them: the marketing version's numbers, then the build number.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let marketing: [Int]
    public let build: Int
    public let marketingString: String

    /// `marketing` is digits and dots ("1.2" or "1.2.3"); `build` is a whole number. Anything else is refused (nil),
    /// so a malformed version can never compare as newer.
    public init?(marketing: String, build: String) {
        let parts = marketing.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        guard !build.isEmpty, build.count <= 9, build.allSatisfy(\.isASCII), build.allSatisfy(\.isNumber), let b = Int(build) else { return nil }
        self.marketing = numbers
        self.build = b
        self.marketingString = marketing
    }

    public var description: String { "\(marketingString) (\(build))" }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.marketing.count, b.marketing.count)
        for i in 0..<n {
            let x = i < a.marketing.count ? a.marketing[i] : 0
            let y = i < b.marketing.count ? b.marketing[i] : 0
            if x != y { return x < y }
        }
        return a.build < b.build
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// What the signed manifest says about one release.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var bundleIdentifier: String
    /// CFBundleShortVersionString of the app in the disk image.
    public var version: String
    /// CFBundleVersion of the app in the disk image.
    public var build: String
    /// The disk image (HTTPS).
    public var url: URL
    /// The disk image's exact size in bytes.
    public var size: Int64
    /// The disk image's SHA-256, lowercase hex.
    public var sha256: String
    /// LSMinimumSystemVersion of the app in the disk image ("15.0").
    public var minimumSystemVersion: String
    public var releaseNotesURL: URL?

    public init(bundleIdentifier: String, version: String, build: String, url: URL, size: Int64, sha256: String,
                minimumSystemVersion: String, releaseNotesURL: URL? = nil) {
        self.format = Self.currentFormat
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesURL = releaseNotesURL
    }

    public var appVersion: AppVersion? { AppVersion(marketing: version, build: build) }
}

/// The file published at the feed address.
public struct SignedFeed: Codable, Equatable, Sendable {
    public static let currentFormat = 1
    public var format: Int
    /// The manifest's exact bytes, base64.
    public var manifest: String
    /// Ed25519 over the manifest's exact bytes, base64.
    public var signature: String

    public init(manifestBytes: Data, signature: Data) {
        format = Self.currentFormat
        manifest = manifestBytes.base64EncodedString()
        self.signature = signature.base64EncodedString()
    }

    /// The feed as published: compact, sorted keys, one trailing newline.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// The public half of Vitrine's update key, compiled into the app (G-21).
public struct UpdateTrust: Sendable {
    /// The value project.yml ships until the maintainer creates the release key (B-8). A build holding it never checks for updates,
    /// and `Scripts/check-app-signature.sh --release` refuses it.
    public static let placeholder = "REPLACE_WITH_OBSCURA_UPDATE_PUBLIC_KEY"

    public let keys: [Curve25519.Signing.PublicKey]

    public init(keys: [Curve25519.Signing.PublicKey]) { self.keys = keys }

    /// The compiled-in value: a base64 raw 32-byte Ed25519 public key. Nil for the placeholder or anything malformed.
    public init?(base64PublicKey: String) {
        let text = base64PublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != Self.placeholder, let raw = Data(base64Encoded: text), raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        keys = [key]
    }
}

/// What a check found.
public enum UpdateCheckOutcome: Equatable, Sendable {
    /// Nothing newer: the feed's release is this one or older (an older one is a refused downgrade, never offered).
    case upToDate(latest: String)
    /// A newer release this Mac can run.
    case available(UpdateManifest)
}

/// Turns the bytes of a fetched feed into a decision, with no I/O. Order matters: the signature is checked over the
/// manifest's exact bytes before anything in them is read.
public struct FeedVerifier: Sendable {
    /// Larger than any real feed; a bigger answer is refused before parsing.
    public static let maxFeedBytes = 64 * 1024
    /// Larger than any real Vitrine disk image could be.
    public static let maxDownloadBytes: Int64 = 1 << 30

    public var trust: UpdateTrust
    public var bundleIdentifier: String
    public var current: AppVersion
    public var systemVersion: OperatingSystemVersion

    public init(trust: UpdateTrust, bundleIdentifier: String, current: AppVersion,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.trust = trust
        self.bundleIdentifier = bundleIdentifier
        self.current = current
        self.systemVersion = systemVersion
    }

    public func evaluate(feed data: Data) throws(UpdateError) -> UpdateCheckOutcome {
        let manifest = try verifiedManifest(feed: data)
        guard let offered = manifest.appVersion else { throw .manifestInvalid("version") }
        guard current < offered else { return .upToDate(latest: manifest.version) }
        guard let required = Self.systemVersion(manifest.minimumSystemVersion) else { throw .manifestInvalid("minimum macOS") }
        guard Self.isAtLeast(systemVersion, required) else { throw .systemTooOld(required: manifest.minimumSystemVersion) }
        return .available(manifest)
    }

    /// The manifest, once its signature verifies and every field is well formed. Says nothing about versions.
    public func verifiedManifest(feed data: Data) throws(UpdateError) -> UpdateManifest {
        guard data.count <= Self.maxFeedBytes else { throw .feedTooLarge }
        guard let feed = try? JSONDecoder().decode(SignedFeed.self, from: data), feed.format == SignedFeed.currentFormat,
              let bytes = Data(base64Encoded: feed.manifest), let signature = Data(base64Encoded: feed.signature)
        else { throw .feedMalformed }
        guard signature.count == 64, trust.keys.contains(where: { $0.isValidSignature(signature, for: bytes) }) else {
            throw .badSignature
        }
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: bytes) else { throw .manifestInvalid("layout") }
        guard manifest.format == UpdateManifest.currentFormat else { throw .manifestInvalid("format") }
        guard manifest.bundleIdentifier == bundleIdentifier else { throw .wrongApp(manifest.bundleIdentifier) }
        guard manifest.url.scheme?.lowercased() == "https", manifest.url.host() != nil else {
            throw .insecureURL(manifest.url.absoluteString)
        }
        if let notes = manifest.releaseNotesURL, notes.scheme?.lowercased() != "https" { throw .insecureURL(notes.absoluteString) }
        guard manifest.size > 0, manifest.size <= Self.maxDownloadBytes else { throw .manifestInvalid("size") }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw .manifestInvalid("SHA-256")
        }
        return manifest
    }

    static func systemVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let n = parts.map { $0! }
        return OperatingSystemVersion(majorVersion: n[0], minorVersion: n.count > 1 ? n[1] : 0, patchVersion: n.count > 2 ? n[2] : 0)
    }

    static func isAtLeast(_ have: OperatingSystemVersion, _ need: OperatingSystemVersion) -> Bool {
        (have.majorVersion, have.minorVersion, have.patchVersion) >= (need.majorVersion, need.minorVersion, need.patchVersion)
    }
}

/// Builds and signs a feed: used by `vitrine release` and by the tests' round trip. Takes a key object; where the key
/// comes from (the Keychain item the release step names) is the caller's business.
public enum FeedSigner {
    /// The manifest's bytes exactly as signed: sorted keys, no escaped slashes.
    public static func manifestBytes(_ manifest: UpdateManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    public static func sign(_ manifest: UpdateManifest, with key: Curve25519.Signing.PrivateKey) throws -> SignedFeed {
        let bytes = try manifestBytes(manifest)
        return SignedFeed(manifestBytes: bytes, signature: try key.signature(for: bytes))
    }

    /// Size and SHA-256 of a file, read in chunks.
    public static func digest(of file: URL) throws -> (size: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (size, hex(hasher.finalize()))
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
