import Foundation
import SQLite3
import Testing
@testable import VitrineSpotlight

// What Spotlight is given for the formats it cannot read (X-8, S-19). Every file is invented: the database, the zip and
// the notebook are made here; the workbook (Fixtures/sales-2026.xlsx) was written by Vitrine's own sample writer.
// roadmap: S-19

@Suite("Spotlight text (X-8)")
struct SpotlightTextTests {
    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-spotlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aDatabaseGivesItsTablesColumnsAndFirstRows() throws {
        let url = try Self.folder().appendingPathComponent("harbor.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE moorings (berth TEXT, vessel TEXT, length_m REAL);
        INSERT INTO moorings VALUES ('A12', 'Sea Glass', 11.5), ('B03', 'Kittiwake', 8.0);
        CREATE VIEW long_boats AS SELECT vessel FROM moorings WHERE length_m > 10;
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let record = try #require(SpotlightText.record(for: url))
        #expect(record.keywords.contains("moorings") && record.keywords.contains("vessel") && record.keywords.contains("long_boats"))
        #expect(record.text.contains("moorings: berth, vessel, length_m"))
        #expect(record.text.contains("A12\tSea Glass\t11.5"))
        #expect(record.text.contains("Kittiwake"))
    }

    @Test func aWorkbookGivesItsColumnsAndValues() throws {
        let url = try #require(Bundle.module.url(forResource: "sales-2026", withExtension: "xlsx", subdirectory: "Fixtures"))
        let record = try #require(SpotlightText.record(for: url))
        #expect(record.keywords.contains("Region"), "\(record.keywords)")
        #expect(!record.text.isEmpty)
    }

    @Test func aNotebookGivesEveryCellAndItsTitle() throws {
        let url = try Self.folder().appendingPathComponent("tides.ipynb")
        let notebook = #"""
        {"nbformat": 4, "nbformat_minor": 5, "metadata": {},
         "cells": [
          {"cell_type": "markdown", "metadata": {}, "source": ["# Tide heights at Cascais\n", "Readings after dusk are estimates."]},
          {"cell_type": "code", "metadata": {}, "execution_count": 1, "outputs": [], "source": ["import pandas as pd\n", "tides = pd.read_csv('cascais.csv')"]}
         ]}
        """#
        try Data(notebook.utf8).write(to: url)
        let record = try #require(SpotlightText.record(for: url))
        #expect(record.text.contains("Readings after dusk are estimates."))
        #expect(record.text.contains("pd.read_csv('cascais.csv')"))
    }

    @Test func anArchiveGivesItsMembersPaths() throws {
        let url = try Self.folder().appendingPathComponent("orbit-sdk.zip")
        try Data(Self.storedZip([("orbit/README.md", "Orbit SDK"), ("orbit/Sources/Telemetry.swift", "struct Telemetry {}")])).write(to: url)
        let record = try #require(SpotlightText.record(for: url))
        #expect(record.text.contains("orbit/Sources/Telemetry.swift"))
        #expect(!record.text.contains("struct Telemetry"), "member contents are never read, only names")
    }

    @Test func textFilesAndOtherKindsAreLeftToSpotlight() throws {
        let dir = try Self.folder()
        let md = dir.appendingPathComponent("notes.md"); try Data("# Notes".utf8).write(to: md)
        #expect(SpotlightText.record(for: md) == nil)
        let junk = dir.appendingPathComponent("broken.sqlite"); try Data("not a database".utf8).write(to: junk)
        #expect(SpotlightText.record(for: junk) == nil)
    }

    @Test func theCharacterCapHolds() throws {
        let url = try Self.folder().appendingPathComponent("many.zip")
        let entries = (0..<500).map { ("folder/file-\($0)-with-a-longer-name.txt", "x") }
        try Data(Self.storedZip(entries)).write(to: url)
        var limits = SpotlightText.Limits(); limits.maxCharacters = 1_000
        let record = try #require(SpotlightText.record(for: url, limits: limits))
        #expect(record.text.count <= 1_001)
    }

    /// A zip with stored (uncompressed) members: local headers, the central directory and its end record.
    static func storedZip(_ files: [(String, String)]) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) } }
            return ~c
        }
        var out: [UInt8] = [], central: [UInt8] = []
        for (name, text) in files {
            let n = Array(name.utf8), d = Array(text.utf8), crc = crc32(d), offset = UInt32(out.count)
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(d.count)) + le32(UInt32(d.count))
                + le16(n.count) + le16(0) + n + d
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(crc) + le32(UInt32(d.count))
                + le32(UInt32(d.count)) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + n
        }
        let start = UInt32(out.count)
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(UInt32(central.count)) + le32(start) + le16(0)
        return out
    }
}
