import Foundation
import Testing
import VitrineSupport
@testable import VitrineEngineering

/// The module exists and links (S-22); each reader has its own suite. roadmap: S-22
@Suite struct VitrineEngineeringTests {
    @Test func moduleLinks() { _ = VitrineEngineering.self }

    /// The kind router (VitrineSupport) and the reader name the same lockfiles (A-12).
    @Test func lockfileNamesAgreeWithTheKindRouter() { #expect(FileSniffer.lockfileNames == LockfileReader.knownFileNames) }

    /// API and schema files route by extension, and JSON/YAML only when the content says it is a spec (E-3).
    @Test func apiSpecRoutingAgreesWithTheReader() throws {
        for ext in APISpecReader.knownExtensions { #expect(FileSniffer.readerKind(URL(fileURLWithPath: "/p/schema.\(ext)")) == "api.spec") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let spec = dir.appendingPathComponent("api.yaml"), plain = dir.appendingPathComponent("settings.yaml")
        try "openapi: 3.1.0\ninfo:\n  title: Acme Notes\n  version: 1.0.0\npaths: {}\n".write(to: spec, atomically: true, encoding: .utf8)
        try "theme: dark\n".write(to: plain, atomically: true, encoding: .utf8)
        #expect(FileSniffer.readerKind(spec) == "api.spec")
        #expect(FileSniffer.readerKind(plain) == nil)
        #expect(APISpecReader.read(data: try Data(contentsOf: spec), fileName: "api.yaml") != nil)
        try? FileManager.default.removeItem(at: dir)
    }

    /// The kind router sends infrastructure files where InfraReader's own name and path rules send them (S-22).
    @Test func infraRoutingAgreesWithTheReader() {
        let paths = ["/p/compose.yaml", "/p/docker-compose.yml", "/p/docker-compose.prod.yaml", "/p/compose.override.yml", "/p/main.tfstate",
                     "/p/main.tfstate.backup", "/p/session.har", "/p/.github/workflows/ci.yml", "/p/Dockerfile", "/p/api.Dockerfile",
                     "/p/Dockerfile.dev", "/p/Dockerfile.md", "/p/Containerfile", "/p/notes.yaml", "/p/README.md", "/p/package.json"]
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let router = FileSniffer.readerKind(url).map { String($0.dropFirst("infra.".count)) }
            #expect(router == InfraReader.kind(fileName: url.lastPathComponent, path: path)?.rawValue, "\(path)")
        }
    }
}
