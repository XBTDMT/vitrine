import CryptoKit
import Foundation
import Testing
@testable import VitrineEngineering

/// Certificates and keys (T-10). Every key and certificate is made here, at test time, with invented names, so no
/// private key is ever committed. roadmap: S-22
@Suite struct KeyMaterialTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args; p.currentDirectoryURL = dir
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(tool) \(args)")
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func read(_ name: String, as fileName: String? = nil) throws -> KeyMaterial? {
        KeyMaterial.read(data: try Data(contentsOf: dir.appendingPathComponent(name)), fileName: fileName ?? name)
    }

    func makeChain() throws {
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "3650",
                                     "-subj", "/CN=Acme Test Root CA/O=Acme Invented"])
        try run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr",
                                     "-subj", "/CN=notes.acme.example/O=Acme Invented"])
        try run("/usr/bin/openssl", ["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "7", "-days", "30", "-out", "leaf.pem"])
        let bundle = try String(contentsOf: dir.appendingPathComponent("leaf.pem"), encoding: .utf8) + String(contentsOf: dir.appendingPathComponent("ca.pem"), encoding: .utf8)
        try bundle.write(to: dir.appendingPathComponent("bundle.pem"), atomically: true, encoding: .utf8)
    }

    @Test func aChainReadsLeafFirstWithItsKeysAndExpiry() throws {
        try makeChain()
        let m = try #require(try read("bundle.pem"))
        #expect(m.container == .pem)
        #expect(m.certificates.map(\.commonName) == ["notes.acme.example", "Acme Test Root CA"])
        #expect(m.certificates.first?.issuerCommonName == "Acme Test Root CA")
        #expect(m.chainIsOrdered)
        guard case .certificate(_, let key) = m.items[0] else { Issue.record("not a certificate"); return }
        #expect(key == .init(algorithm: "RSA", bits: 2048))
        let days = m.certificates[0].notValidAfter.map { $0.timeIntervalSinceNow / 86_400 } ?? 0
        #expect(days > 28 && days < 31)
        // Reversed, the chain no longer runs leaf to root.
        let reversed = try String(contentsOf: dir.appendingPathComponent("ca.pem"), encoding: .utf8) + String(contentsOf: dir.appendingPathComponent("leaf.pem"), encoding: .utf8)
        #expect(KeyMaterial.read(data: Data(reversed.utf8), fileName: "r.pem")?.chainIsOrdered == false)
    }

    @Test func derCertificatesAndSigningRequests() throws {
        try makeChain()
        try run("/usr/bin/openssl", ["x509", "-in", "leaf.pem", "-outform", "der", "-out", "leaf.der"])
        let der = try #require(try read("leaf.der", as: "leaf.cer"))
        #expect(der.container == .der && der.certificates.first?.commonName == "notes.acme.example")
        #expect(try read("leaf.csr")?.items == [.signingRequest])
    }

    @Test func privateKeysAreDescribedNeverKept() throws {
        try makeChain()
        let rsa = try #require(try read("leaf.key"))
        guard case .privateKey(let p) = rsa.items.first else { Issue.record("not a private key"); return }
        #expect(p.encrypted == false && p.algorithm == "RSA")
        // LibreSSL cannot make Ed25519 keys: wrap a fresh CryptoKit key in PKCS#8 (RFC 8410) by hand.
        let raw = [UInt8](Curve25519.Signing.PrivateKey().rawRepresentation)
        let pkcs8 = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20] + raw)
        try "-----BEGIN PRIVATE KEY-----\n\(pkcs8.base64EncodedString(options: .lineLength64Characters))\n-----END PRIVATE KEY-----\n"
            .write(to: dir.appendingPathComponent("ed.key"), atomically: true, encoding: .utf8)
        guard case .privateKey(let ed) = try read("ed.key")?.items.first else { Issue.record("not a private key"); return }
        #expect(ed.format == "PKCS#8" && ed.algorithm == "Ed25519")
        // Nothing of the key's text survives in what the reader returns.
        let body = try String(contentsOf: dir.appendingPathComponent("ed.key"), encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        #expect(!String(describing: try read("ed.key")!).contains(body.prefix(24)))
    }

    @Test func sshKeysTheirFingerprintsAndPassphrases() throws {
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "dev@acme.example", "-f", "plain"])
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "3072", "-N", "invented passphrase", "-C", "ci@acme.example", "-f", "locked"])
        let expected = try run("/usr/bin/ssh-keygen", ["-l", "-f", "plain.pub"]).split(separator: " ")[1]
        guard case .sshPublicKey(let pub) = try read("plain.pub")?.items.first else { Issue.record("not an SSH key"); return }
        #expect(pub.type == "ssh-ed25519" && pub.bits == 256 && pub.comment == "dev@acme.example")
        #expect(pub.fingerprint == String(expected))
        guard case .sshPublicKey(let rsa) = try read("locked.pub")?.items.first else { Issue.record("not an SSH key"); return }
        #expect(rsa.bits == 3072)
        guard case .privateKey(let open) = try read("plain", as: "id_ed25519")?.items.first,
              case .privateKey(let locked) = try read("locked", as: "id_rsa")?.items.first else { Issue.record("not private keys"); return }
        #expect(open.format == "OpenSSH" && open.encrypted == false && open.algorithm == "ssh-ed25519")
        #expect(open.publicFingerprint == String(expected), "the clear public half's fingerprint")
        #expect(locked.encrypted && locked.algorithm == "ssh-rsa")
    }

    @Test func authorizedKeysAndKnownHosts() throws {
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "deploy@acme.example", "-f", "k"])
        let pub = try String(contentsOf: dir.appendingPathComponent("k.pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = pub.split(separator: " ")
        let authorized = "# invented\ncommand=\"/usr/local/bin/backup\",no-pty \(pub)\n\(pub)\nnot a key line\n"
        let a = try #require(KeyMaterial.read(data: Data(authorized.utf8), fileName: "authorized_keys"))
        #expect(a.container == .authorizedKeys && a.items.count == 2 && a.unreadable == 1)
        guard case .sshPublicKey(let first) = a.items[0] else { Issue.record("not an SSH key"); return }
        #expect(first.options == "command=\"/usr/local/bin/backup\",no-pty")
        let known = "notes.acme.example,192.0.2.10 \(parts[0]) \(parts[1])\n|1|aW52ZW50ZWQ=|aGFzaA== \(parts[0]) \(parts[1])\n"
        let k = try #require(KeyMaterial.read(data: Data(known.utf8), fileName: "known_hosts"))
        #expect(k.container == .knownHosts && k.items.count == 2)
        guard case .sshPublicKey(let hashed) = k.items[1] else { Issue.record("not an SSH key"); return }
        #expect(hashed.hashedHost)
    }

    @Test func otherTextIsNotKeyMaterial() {
        #expect(KeyMaterial.read(data: Data("hello world\n".utf8), fileName: "notes.txt") == nil)
        #expect(KeyMaterial.read(data: Data([0x30, 0x03, 0x02, 0x01, 0x00]), fileName: "x.der") == nil)
        #expect(KeyMaterial.read(data: Data("-----BEGIN CERTIFICATE-----\n!!!\n".utf8), fileName: "cut.pem")?.unreadable == 1)
    }
}
