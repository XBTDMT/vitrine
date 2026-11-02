// vitrine-release — the release Mac's half of G-21's signed update feed (ported from Obscura's `obscura release`).
// A maintainer's tool: never shipped inside Vitrine.app. roadmap: S-13
//
//   vitrine-release keygen --key-item <name> [--backup-to <path>] [--dry-run]
//       Creates the Ed25519 update key ONCE, straight into a login-Keychain item, and prints its public half.
//       --backup-to writes the private key (base64) to a NEW 0600 file the maintainer names (for an encrypted backup).
//   vitrine-release public-key --key-item <name>
//       Prints the public key for the VITRINE_UPDATE_PUBLIC_KEY build setting.
//   vitrine-release feed --app <Vitrine.app> --dmg <dmg> --url <https dmg url> [--notes-url <https>] --key-item <name> --out <file>
//       Reads bundle id, version, build and minimum macOS from the app in the disk image, hashes the disk image, signs
//       the manifest with the Keychain key, verifies it back with the public key, and writes the feed.
//   vitrine-release verify --feed <file> --public-key <base64>
//       Checks a feed's signature offline and prints its manifest.
// The private key is never printed, logged or passed on a command line. The Keychain item may also be named by the
// VITRINE_UPDATE_KEY_ITEM environment variable.
import CryptoKit
import Darwin
import Foundation
import Security
import VitrineUpdate

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// `--name value` pairs and `--flag`s after the subcommand.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, flags known: Set<String>) throws {
        var i = args.startIndex
        while i < args.endIndex {
            let arg = args[i]
            guard arg.hasPrefix("--") else { throw Failure("unexpected argument \(arg)") }
            let name = String(arg.dropFirst(2))
            if known.contains(name) { flags.insert(name); i += 1; continue }
            guard i + 1 < args.endIndex else { throw Failure("\(arg) needs a value") }
            values[name] = args[i + 1]
            i += 2
        }
    }

    func required(_ name: String) throws -> String {
        guard let v = values[name], !v.isEmpty else { throw Failure("--\(name) is required") }
        return v
    }

    func keyItem() throws -> String {
        if let name = values["key-item"], !name.isEmpty { return name }
        if let env = ProcessInfo.processInfo.environment["VITRINE_UPDATE_KEY_ITEM"], !env.isEmpty { return env }
        throw Failure("name the Keychain item with --key-item or VITRINE_UPDATE_KEY_ITEM")
    }
}

/// The update key's one home: a generic-password item in the login Keychain, holding the raw 32-byte private key.
enum UpdateKeychain {
    static let account = "vitrine-update-ed25519"

    static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name, kSecAttrAccount as String: account]
    }

    static func exists(_ name: String) -> Bool { SecItemCopyMatching(query(name) as CFDictionary, nil) == errSecSuccess }

    static func store(_ key: Curve25519.Signing.PrivateKey, name: String) throws {
        var attributes = query(name)
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrLabel as String] = name
        attributes[kSecAttrDescription as String] = "Vitrine update signing key (Ed25519)"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure("the Keychain refused to store the key (OSStatus \(status))") }
    }

    static func load(_ name: String) throws -> Curve25519.Signing.PrivateKey {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure("no update key in the Keychain item \"\(name)\" (OSStatus \(status))")
        }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw Failure("the Keychain item \"\(name)\" does not hold a 32-byte Ed25519 key")
        }
        return key
    }
}

func keygen(_ o: Options) throws {
    let name = try o.keyItem()
    let backup = o.values["backup-to"]
    if let backup, FileManager.default.fileExists(atPath: backup) { throw Failure("\(backup) already exists; the backup is never overwritten") }
    if o.flags.contains("dry-run") {
        // A dry run does not even read the Keychain.
        print("dry run: would refuse if the login Keychain already holds an item \"\(name)\" (account \(UpdateKeychain.account))")
        print("dry run: would create an Ed25519 key in that Keychain item")
        if let backup { print("dry run: would write the private key backup to \(backup) (new file, mode 0600)") }
        print("dry run: would print the public key for VITRINE_UPDATE_PUBLIC_KEY; nothing was created or read")
        return
    }
    if UpdateKeychain.exists(name) { throw Failure("the Keychain item \"\(name)\" already exists; a second key would orphan every installed copy") }
    let key = Curve25519.Signing.PrivateKey()
    if let backup {
        let fd = open(backup, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure("could not create \(backup) (errno \(errno))") }
        let text = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        let written = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == text.count else { throw Failure("could not write the backup to \(backup)") }
    }
    try UpdateKeychain.store(key, name: name)
    print("created the update key in the Keychain item \"\(name)\"")
    if let backup { print("private key backup written to \(backup) (0600); keep it offline") }
    print("public key (VITRINE_UPDATE_PUBLIC_KEY): \(key.publicKey.rawRepresentation.base64EncodedString())")
}

func publicKey(_ o: Options) throws {
    print(try UpdateKeychain.load(try o.keyItem()).publicKey.rawRepresentation.base64EncodedString())
}

func feed(_ o: Options) throws {
    let app = try o.required("app"), dmg = try o.required("dmg"), url = try o.required("url"), out = try o.required("out")
    let info = URL(filePath: app).appending(path: "Contents/Info.plist")
    guard let data = try? Data(contentsOf: info),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let id = plist["CFBundleIdentifier"] as? String, let version = plist["CFBundleShortVersionString"] as? String,
          let build = plist["CFBundleVersion"] as? String, let current = AppVersion(marketing: version, build: build)
    else { throw Failure("\(app) has no readable bundle id and version") }
    let minimum = plist["LSMinimumSystemVersion"] as? String ?? "15.0"
    guard let dmgURL = URL(string: url), dmgURL.scheme == "https", dmgURL.host() != nil else { throw Failure("--url must be https") }
    let notes = try o.values["notes-url"].map { text -> URL in
        guard let u = URL(string: text), u.scheme == "https" else { throw Failure("--notes-url must be https") }
        return u
    }
    let digest = try FeedSigner.digest(of: URL(filePath: dmg))
    let manifest = UpdateManifest(bundleIdentifier: id, version: version, build: build, url: dmgURL, size: digest.size,
                                  sha256: digest.sha256, minimumSystemVersion: minimum, releaseNotesURL: notes)
    let key = try UpdateKeychain.load(try o.keyItem())
    let signed = try FeedSigner.sign(manifest, with: key).encoded()
    // Round trip with the public half, as an installed copy one build older would see it.
    let older = AppVersion(marketing: current.marketingString, build: String(max(current.build - 1, 0)))!
    let verifier = FeedVerifier(trust: UpdateTrust(keys: [key.publicKey]), bundleIdentifier: id, current: older)
    guard try verifier.verifiedManifest(feed: signed) == manifest else { throw Failure("the signed feed did not read back identically") }
    try signed.write(to: URL(filePath: out), options: .atomic)
    print("wrote \(out): \(id) \(version) (\(build)), \(digest.size) bytes, sha256 \(digest.sha256), min macOS \(minimum)")
}

func verify(_ o: Options) throws {
    guard let trust = UpdateTrust(base64PublicKey: try o.required("public-key")) else { throw Failure("--public-key is not a base64 32-byte Ed25519 key") }
    let data = try Data(contentsOf: URL(filePath: try o.required("feed")))
    let signed = try JSONDecoder().decode(SignedFeed.self, from: data)
    let bytes = Data(base64Encoded: signed.manifest) ?? Data()
    let id = (try? JSONDecoder().decode(UpdateManifest.self, from: bytes))?.bundleIdentifier ?? ""
    let manifest: UpdateManifest
    do {
        manifest = try FeedVerifier(trust: trust, bundleIdentifier: id, current: AppVersion(marketing: "0", build: "0")!).verifiedManifest(feed: data)
    } catch {
        throw Failure("FAILED: \(error.reason)")
    }
    print("signature verifies")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(manifest), as: UTF8.self))
}

let args = CommandLine.arguments.dropFirst()
let usage = "usage: vitrine-release keygen|public-key|feed|verify [options]  (see the header of Tools/vitrine-release/main.swift)"
do {
    guard let command = args.first else { print(usage); exit(64) }
    let rest = args.dropFirst()
    switch command {
    case "keygen": try keygen(try Options(rest, flags: ["dry-run"]))
    case "public-key": try publicKey(try Options(rest, flags: []))
    case "feed": try feed(try Options(rest, flags: []))
    case "verify": try verify(try Options(rest, flags: []))
    default: print(usage); exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("vitrine-release: \(error)\n".utf8))
    exit(1)
}
