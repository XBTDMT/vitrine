import Foundation
import Testing
@testable import VitrineEngineering

/// G-26: the app's index build reads an OSV-style `all.zip` member by member; made here from invented records with
/// ditto, so no network is involved. roadmap: S-22
@Suite struct AdvisoryStoreTests {
    @Test func buildsAnIndexFromAnOSVStyleZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("osv-\(UUID().uuidString)")
        let records = dir.appendingPathComponent("npm")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try #"{"id":"GHSA-zip1-invented","summary":"Invented","affected":[{"package":{"ecosystem":"npm","name":"lumen-md"},"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"4.0.2"}]}]}]}"#
            .write(to: records.appendingPathComponent("GHSA-zip1-invented.json"), atomically: true, encoding: .utf8)
        try #"{"id":"MAL-zip2-invented","affected":[{"package":{"ecosystem":"npm","name":"harbor-utils"},"versions":["2.1.3"]}]}"#
            .write(to: records.appendingPathComponent("MAL-zip2-invented.json"), atomically: true, encoding: .utf8)
        try "not a record".write(to: records.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("all.zip")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", records.path, zip.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let index = try AdvisoryStore.buildIndex(.npm, zip: zip, lastModified: Date(timeIntervalSince1970: 1_793_000_000))
        #expect(index.meta.records == 2)
        #expect(index.advisories(name: "lumen-md", version: "4.0.1").map(\.id) == ["GHSA-zip1-invented"])
        #expect(index.advisories(name: "harbor-utils", version: "2.1.3").first?.isMalicious == true)
        try? FileManager.default.removeItem(at: dir)
    }
}
