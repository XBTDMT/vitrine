import Foundation
import XCTest
@testable import VitrineBinary

final class CodeSignatureTests: XCTestCase {
    // MARK: - The static layer

    func testAdhocSignatureWithEntitlementsParsedStatically() throws {
        let fx = try SharedFixtures.get()
        let slice = try XCTUnwrap(try MachOReader.read(contentsOf: fx.signed).slices.first)
        let signature = try XCTUnwrap(slice.codeSignature, slice.codeSignatureProblem ?? "")
        XCTAssertTrue(signature.notes.isEmpty, "\(signature.notes)")
        XCTAssertEqual(signature.identifier, "com.example.signed")
        XCTAssertNil(signature.teamIdentifier)
        XCTAssertTrue(signature.isAdhoc)
        XCTAssertEqual(signature.cmsSize, 0)
        let cd = try XCTUnwrap(signature.primary)
        XCTAssertTrue(cd.flags.contains(.adhoc))
        XCTAssertTrue(cd.flags.isHardenedRuntime)
        XCTAssertFalse(cd.flags.contains(.linkerSigned))
        XCTAssertEqual(cd.flags.names, ["adhoc", "runtime"])
        XCTAssertEqual(cd.hashType.name, "SHA-256")
        XCTAssertEqual(cd.hashSize, 32)
        XCTAssertTrue([4096, 16384].contains(cd.pageSize))
        XCTAssertNotNil(cd.runtimeVersion)
        XCTAssertEqual(signature.requirementCount, 0)
        XCTAssertFalse(signature.hasTicketSlot)
        XCTAssertEqual(signature.slots.first?.name, "code directory")

        // Entitlements: the XML and the DER blobs both decode, to the same dictionary, equal to what was signed in.
        XCTAssertEqual(signature.entitlementsSource, .xml)
        XCTAssertEqual(signature.entitlements, fx.entitlements)
        XCTAssertEqual(signature.derEntitlements, fx.entitlements)
        XCTAssertEqual(signature.entitlements?["com.example.count"], .integer(42))
        XCTAssertEqual(signature.entitlements?["com.example.nested"]?.dictionaryValue?["name"], .string("inner"))

        // The code directory hash and fields agree with codesign's own display.
        let shown = try fx.folder.run("/usr/bin/codesign", ["-dvvv", fx.signed.path])
        let cdHashLine = try XCTUnwrap(shown.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
        XCTAssertEqual(cd.cdHash, String(cdHashLine.dropFirst("CDHash=".count)))
        XCTAssertTrue(shown.contains("v=\(cd.versionString)"))
        XCTAssertTrue(shown.contains("hashes=\(cd.codeSlotCount)+\(cd.specialSlotCount)"), shown)  // code+special
    }

    func testSuperBlobHostileCases() throws {
        func blob(_ magic: UInt32, _ body: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []; out.be32(magic); out.be32(UInt32(8 + body.count)); return out + body
        }
        func superBlob(_ entries: [(UInt32, [UInt8])], offsets: [UInt32]? = nil, count: UInt32? = nil) -> [UInt8] {
            var index: [UInt8] = [], data: [UInt8] = []
            let start = 12 + entries.count * 8
            for (i, (type, b)) in entries.enumerated() {
                index.be32(type); index.be32(offsets?[i] ?? UInt32(start + data.count)); data += b
            }
            var out: [UInt8] = []
            out.be32(0xFADE_0CC0); out.be32(UInt32(start + data.count)); out.be32(count ?? UInt32(entries.count))
            return out + index + data
        }

        assertBinaryError(try EmbeddedSignature.parse([]))
        assertBinaryError(try EmbeddedSignature.parse([0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 12, 0, 0, 0, 0]), matching: {
            if case .malformed = $0 { true } else { false }
        })
        assertBinaryError(try EmbeddedSignature.parse(superBlob([], count: 0xFFFF_FFFF)))
        assertBinaryError(try EmbeddedSignature.parse(superBlob([], count: 40)))

        // Blobs that lie outside, or claim impossible lengths, are noted and skipped.
        var bad = superBlob([(0, blob(0xFADE_0C02, [1, 2, 3])), (5, blob(0xFADE_7171, []))], offsets: [0xFFFF, 4])
        var parsed = try EmbeddedSignature.parse(bad)
        XCTAssertTrue(parsed.slots.isEmpty)
        XCTAssertEqual(parsed.notes.count, 2)
        bad = superBlob([(5, [0xFA, 0xDE, 0x71, 0x71, 0xFF, 0xFF, 0xFF, 0xFF])])
        parsed = try EmbeddedSignature.parse(bad)
        XCTAssertTrue(parsed.notes.contains { $0.contains("impossible length") })

        // A code directory too short for its fields; entitlements that are not a plist; DER that lies.
        parsed = try EmbeddedSignature.parse(superBlob([
            (0, blob(0xFADE_0C02, [0, 2, 5, 0])),
            (5, blob(0xFADE_7171, Array("<plist><dict><key>".utf8))),
            (7, blob(0xFADE_7172, [0x70, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])),
            (0x10002, blob(0x0000_0001, [])),
        ]))
        XCTAssertTrue(parsed.codeDirectories.isEmpty)
        XCTAssertNil(parsed.entitlements)
        XCTAssertEqual(parsed.notes.count, 3, "\(parsed.notes)")
        XCTAssertTrue(parsed.hasTicketSlot)
        XCTAssertEqual(parsed.slots.last?.name, "notarization ticket")

        // A code directory whose identifier offset points outside it.
        var cd = [UInt8](repeating: 0, count: 44)
        cd.replaceSubrange(0..<4, with: [0, 2, 0, 0x01])          // version 0x20001
        cd.replaceSubrange(12..<16, with: [0, 0, 0xFF, 0xFF])     // identOffset
        parsed = try EmbeddedSignature.parse(superBlob([(0, blob(0xFADE_0C02, cd))]))
        XCTAssertTrue(parsed.codeDirectories.isEmpty)
        XCTAssertTrue(parsed.notes.first?.contains("identifier") == true)
    }

    func testDEREntitlementsDecoderBounds() throws {
        // Booleans, integers (negative too), strings, arrays and nested dictionaries.
        func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            precondition(content.count < 0x10000)
            if content.count < 0x80 { return [tag, UInt8(content.count)] + content }
            return [tag, 0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] + content
        }
        func pair(_ key: String, _ value: [UInt8]) -> [UInt8] { tlv(0x30, tlv(0x0C, Array(key.utf8)) + value) }
        let dict = tlv(0xB0, pair("a", tlv(0x01, [0xFF])) + pair("n", tlv(0x02, [0xFF, 0x38]))
                         + pair("s", tlv(0x0C, Array("x".utf8))) + pair("arr", tlv(0x30, tlv(0x02, [5]) + tlv(0x01, [0])))
                         + pair("d", tlv(0xB0, pair("k", tlv(0x0C, Array("v".utf8))))))
        let decoded = try DEREntitlements.decode(tlv(0x70, tlv(0x02, [1]) + dict))
        XCTAssertEqual(decoded, ["a": .bool(true), "n": .integer(-200), "s": .string("x"),
                                 "arr": .array([.integer(5), .bool(false)]), "d": .dictionary(["k": .string("v")])])

        // Nesting deeper than the cap is refused, not recursed into.
        var deep = tlv(0x01, [0xFF])
        for _ in 0..<40 { deep = tlv(0x30, deep) }
        assertBinaryError(try DEREntitlements.decode(tlv(0x70, tlv(0x02, [1]) + tlv(0xB0, pair("x", deep)))))
        // Wrong outer tag, lengths past the parent, wide integers, unknown tags.
        assertBinaryError(try DEREntitlements.decode(tlv(0x30, [])))
        assertBinaryError(try DEREntitlements.decode([0x70, 0x10, 0x02]))
        assertBinaryError(try DEREntitlements.decode(tlv(0x70, tlv(0x02, [1]) + tlv(0xB0, pair("w", tlv(0x02, [UInt8](repeating: 1, count: 9)))))))
        assertBinaryError(try DEREntitlements.decode(tlv(0x70, tlv(0x02, [1]) + tlv(0xB0, pair("u", tlv(0x13, [1]))))))
    }

    // MARK: - The Security framework layer (offline)

    func testSecurityAssessmentOfAdhocUnsignedAndTampered() throws {
        let fx = try SharedFixtures.get()
        let adhoc = SignatureVerifier.assess(url: fx.signed)
        XCTAssertEqual(adhoc.status, .adhoc)
        XCTAssertEqual(adhoc.identifier, "com.example.signed")
        XCTAssertTrue(adhoc.isHardenedRuntime)
        XCTAssertTrue(adhoc.certificates.isEmpty)
        XCTAssertEqual(adhoc.entitlements, fx.entitlements)
        XCTAssertEqual(adhoc.ticketFile, .notApplicable)
        XCTAssertEqual(adhoc.notarization, .none)
        XCTAssertEqual(adhoc.anchor, .none, "ad hoc has no certificate to classify")
        let staticCD = try XCTUnwrap(try MachOReader.read(contentsOf: fx.signed).slices.first?.codeSignature?.primary)
        XCTAssertEqual(adhoc.cdHash, staticCD.cdHash)

        let folder = try FixtureFolder()
        try FileManager.default.copyItem(at: fx.signed, to: folder.path("unsigned"))
        try folder.run("/usr/bin/codesign", ["--remove-signature", "unsigned"])
        XCTAssertEqual(SignatureVerifier.assess(url: folder.path("unsigned")).status, .unsigned)
        XCTAssertNil(try MachOReader.read(contentsOf: folder.path("unsigned")).slices.first?.codeSignatureRange)

        // One byte changed inside __TEXT: the page hash no longer matches.
        var bytes = [UInt8](try Data(contentsOf: fx.signed))
        let text = try XCTUnwrap(try MachOReader.read(contentsOf: fx.signed).slices.first?.segments.first { $0.name == "__TEXT" })
        let target = Int(text.fileOffset) + Int(text.fileSize) - 64
        bytes[target] ^= 0xFF
        try folder.write("tampered", bytes: bytes)
        guard case .invalid(let reason, let code) = SignatureVerifier.assess(url: folder.path("tampered")).status else {
            return XCTFail("a tampered binary must be invalid")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNotEqual(code, 0)

        // Something that is not code at all.
        try folder.write("text.txt", "hello")
        if case .valid = SignatureVerifier.assess(url: folder.path("text.txt")).status { XCTFail("text is not valid code") }
    }

    func testSecurityAssessmentOfASystemApp() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: calculator.path) else { throw XCTSkip("Calculator.app is not here") }
        let clock = ContinuousClock()
        var quick: SignatureAssessment?, full: SignatureAssessment?
        let quickTime = clock.measure { quick = SignatureVerifier.assess(url: calculator, depth: .quick) }
        let fullTime = clock.measure { full = SignatureVerifier.assess(url: calculator, depth: .full) }
        print("VitrineBinary perf: Calculator.app signature quick \(quickTime), full \(fullTime)")
        for assessment in [quick, full].compactMap({ $0 }) {
            XCTAssertEqual(assessment.status, .valid)
            XCTAssertEqual(assessment.identifier, "com.apple.calculator")
            XCTAssertNil(assessment.teamIdentifier)                  // Apple's own code carries no team id
            XCTAssertEqual(assessment.certificates.last?.commonName, "Apple Root CA")
            XCTAssertTrue(assessment.certificates.first?.summary.hasSuffix("Software Signing") == true)
            XCTAssertEqual(assessment.ticketFile, .notStapled)      // system apps are not stapled
            XCTAssertEqual(assessment.anchor, .apple)
            XCTAssertEqual(assessment.notarization, .none)          // Apple's own code is not notarized
        }
        XCTAssertEqual(quick?.depth, .quick)
        XCTAssertLessThan(quickTime, .seconds(5))

        // The static layer reads the same identifier and the CMS certificates without Security's checks.
        let facts = try BundleReader.read(contentsOf: calculator)
        let signature = try XCTUnwrap(facts.signature)
        XCTAssertEqual(signature.identifier, "com.apple.calculator")
        XCTAssertGreaterThan(signature.cmsSize ?? 0, 0)
        XCTAssertFalse(signature.isAdhoc)
        XCTAssertTrue(signature.cmsCertificates.contains { $0.commonName == "Apple Root CA" })
        XCTAssertTrue(signature.codeDirectories.contains { $0.hashType.name == "SHA-256" })
    }

    // MARK: - Notarization tickets

    func testStapledTicketDetection() throws {
        let folder = try FixtureFolder()
        try folder.mkdir("Plain.app/Contents/MacOS")
        XCTAssertEqual(StapledTicket.detect(at: folder.path("Plain.app")), .notStapled)

        var ticket = Array("s8ch".utf8)
        ticket.append(contentsOf: [1, 0, 0, 0] + [UInt8](repeating: 0x30, count: 64))
        try folder.write("Stapled.app/Contents/CodeResources", bytes: ticket)
        XCTAssertEqual(StapledTicket.detect(at: folder.path("Stapled.app")), .present(version: 1, size: Int64(ticket.count)))

        try folder.write("Junk.app/Contents/CodeResources", "<plist/>")
        guard case .unrecognized = StapledTicket.detect(at: folder.path("Junk.app")) else {
            return XCTFail("a CodeResources file that is not a ticket must say so")
        }
        try folder.write("tool", "x")
        XCTAssertEqual(StapledTicket.detect(at: folder.path("tool")), .notApplicable)
    }

    /// Read-only: the first 8 bytes of `Contents/CodeResources` in apps installed in /Applications, the evidence
    /// for where `stapler` puts the ticket and what it starts with. Skipped on a machine with no stapled app.
    func testStapledTicketsOnThisMachineStartWithTheMagic() throws {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        var stapled = 0
        for name in apps where name.hasSuffix(".app") {
            let app = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/CodeResources").path) else { continue }
            let result = StapledTicket.detect(at: app)
            XCTAssertTrue(result.isPresent, "\(name): \(result)")
            if case .present(let version, _) = result { XCTAssertEqual(version, 1) }
            stapled += 1
        }
        if stapled == 0 { throw XCTSkip("no app in /Applications has a stapled ticket to check against") }
        print("VitrineBinary: \(stapled) stapled apps in /Applications all start with the s8ch ticket magic")
    }
}
