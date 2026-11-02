import Foundation
import Security
import Testing
import UniformTypeIdentifiers
import VitrineHelperKit

/// The helper's name must agree everywhere it is written (X-3, SP-3): the code's constant, the launchd property list
/// that registers the service, and the extensions' scoped mach-lookup exception, without which the sandbox refuses the
/// lookup (error 159, measured 2026-11-01). roadmap: S-10 (X-3)
struct HelperServiceTests {
    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent(path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func theNameSitsUnderTheAppGroup() {
        #expect(HelperService.machServiceName.hasPrefix(HelperService.appGroup + "."))
    }

    @Test func theLaunchAgentRegistersThatName() throws {
        let agent = try Self.plist("Helper/\(HelperService.launchAgentPlistName)")
        let services = try #require(agent["MachServices"] as? [String: Bool])
        #expect(services == [HelperService.machServiceName: true])
        #expect(agent["BundleProgram"] as? String == "Contents/Helpers/VitrineHelper")
    }

    @Test(arguments: ["Config/Extension.entitlements", "Config/WebExtension.entitlements"])
    func everyExtensionMayLookUpExactlyTheHelper(_ path: String) throws {
        let entitlements = try Self.plist(path)
        let names = entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String]
        #expect(names == [HelperService.machServiceName], "only the helper, nothing wider")
        #expect((entitlements["com.apple.security.application-groups"] as? [String])?.contains(HelperService.appGroup) == true)
    }

    @Test func launchReregistersOnlyAnEnabledHelperThatIsStaleOrSilent() {
        #expect(HelperRegistration.launchStep(state: .enabled, answeredFingerprint: "a", bundledFingerprint: "a") == .nothing)
        #expect(HelperRegistration.launchStep(state: .enabled, answeredFingerprint: "a", bundledFingerprint: "b") == .reregister)
        #expect(HelperRegistration.launchStep(state: .enabled, answeredFingerprint: nil, bundledFingerprint: "b") == .reregister)
        #expect(HelperRegistration.launchStep(state: .notRegistered, answeredFingerprint: nil, bundledFingerprint: "b") == .nothing,
                "a helper the person never turned on stays off")
        #expect(HelperRegistration.launchStep(state: .requiresApproval, answeredFingerprint: nil, bundledFingerprint: "b") == .nothing)
    }

    @Test func theFingerprintIsStableAndShort() {
        let a = HelperRegistration.fingerprint(of: Data("helper".utf8))
        #expect(a == HelperRegistration.fingerprint(of: Data("helper".utf8)))
        #expect(a != HelperRegistration.fingerprint(of: Data("helper2".utf8)))
        #expect(a.count == 16)
    }

    // MARK: G-31's rules

    @Test func onlyWebAndMailLinksOpen() {
        #expect(HelperRules.allowedLink("https://example.invalid/page") != nil)
        #expect(HelperRules.allowedLink("mailto:someone@example.invalid") != nil)
        #expect(HelperRules.allowedLink("file:///etc/passwd") == nil)
        #expect(HelperRules.allowedLink("javascript:alert(1)") == nil)
        #expect(HelperRules.allowedLink("vscode://file/tmp/x") == nil)
        #expect(HelperRules.allowedLink("https://") == nil, "a web link needs a host")
    }

    @Test func programsScriptsAndInstallersAreNeverOpened() {
        let doc = URL(fileURLWithPath: "/tmp/notes.md")
        #expect(!HelperRules.isExecutableContent(doc, type: .init(filenameExtension: "md"), isExecutableFile: false, firstBytes: Array("# Hi".utf8)))
        #expect(HelperRules.isExecutableContent(URL(fileURLWithPath: "/tmp/run.command"), type: .init(filenameExtension: "command"), isExecutableFile: false, firstBytes: []))
        #expect(HelperRules.isExecutableContent(URL(fileURLWithPath: "/tmp/setup.pkg"), type: .init(filenameExtension: "pkg"), isExecutableFile: false, firstBytes: []))
        #expect(HelperRules.isExecutableContent(URL(fileURLWithPath: "/tmp/Tool.app"), type: nil, isExecutableFile: false, firstBytes: []))
        #expect(HelperRules.isExecutableContent(URL(fileURLWithPath: "/tmp/install.sh"), type: .init(filenameExtension: "sh"), isExecutableFile: false, firstBytes: []))
        #expect(HelperRules.isExecutableContent(URL(fileURLWithPath: "/tmp/noext"), type: nil, isExecutableFile: true, firstBytes: Array("#!/bin/sh".utf8)),
                "an executable file with a #! line runs")
        #expect(!HelperRules.isExecutableContent(URL(fileURLWithPath: "/tmp/data"), type: nil, isExecutableFile: true, firstBytes: Array("abc".utf8)))
    }

    @Test func memberPathsStayInsideTheArchive() {
        #expect(HelperRules.safeMemberPath("docs/readme.txt") == "docs/readme.txt")
        #expect(HelperRules.safeMemberPath("docs//readme.txt") == "docs/readme.txt")
        #expect(HelperRules.safeMemberPath("/etc/passwd") == nil)
        #expect(HelperRules.safeMemberPath("../../.ssh/id_rsa") == nil)
        #expect(HelperRules.safeMemberPath("a/../b") == nil)
        #expect(HelperRules.safeMemberPath("") == nil)
    }

    @Test func extractionNeverOverwrites() {
        let folder = URL(fileURLWithPath: "/tmp/dl")
        let taken: Set<String> = ["/tmp/dl/report.pdf", "/tmp/dl/report 2.pdf"]
        #expect(HelperRules.uniqueDestination(for: "report.pdf", in: folder) { taken.contains($0.path) }.lastPathComponent == "report 3.pdf")
        #expect(HelperRules.uniqueDestination(for: "Makefile", in: folder) { _ in false }.lastPathComponent == "Makefile")
    }

    @Test func editorsOpenAtTheLine() {
        #expect(HelperRules.Editor.vscode.url(file: "/tmp/a b.swift", line: 12)?.absoluteString == "vscode://file/tmp/a%20b.swift:12")
        #expect(HelperRules.Editor.zed.url(file: "/tmp/x.rs", line: 0)?.absoluteString == "zed://file/tmp/x.rs:1")
        #expect(HelperRules.Editor.xcode.url(file: "/tmp/x.swift", line: 3) == nil, "Xcode takes xed --line")
    }

    @Test func summariesSendCappedText() {
        #expect(HelperRules.summaryInput(String(repeating: "a", count: 30_000)).count == HelperRules.maxSummaryCharacters)
        #expect(HelperRules.summaryInput("short") == "short")
    }

    @Test func refusalsTravelAsCodes() {
        for r in HelperRules.Refusal.allCases { #expect(HelperRules.Refusal.from(r.reply) == r) }
        #expect(HelperRules.Refusal.from("The operation couldn’t be completed.") == nil, "macOS's own errors pass through")
    }

    // MARK: G-33's caller check

    @Test func theRequirementPinsTheSigningCertificate() throws {
        let der = Data((0..<64).map { UInt8($0) })
        let requirement = try #require(HelperService.clientRequirement(leafCertificateDER: der))
        #expect(requirement.hasPrefix("certificate leaf = H\""))
        #expect(requirement.count == "certificate leaf = H\"\"".count + 40, "a SHA-1 in hex")
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, "macOS accepts it")
        #expect(HelperService.clientRequirement(leafCertificateDER: Data((0..<64).map { UInt8(63 - $0) })) != requirement)
    }

    @Test func anAdHocSignatureAnswersNoOne() {
        #expect(HelperService.clientRequirement(leafCertificateDER: nil) == nil)
        #expect(HelperService.clientRequirement(leafCertificateDER: Data()) == nil)
    }
}
