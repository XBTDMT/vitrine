import XCTest
@testable import VitrineSupport

final class FileSnifferTests: XCTestCase {
    private func temp(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testMarkdownByExtension() throws {
        let url = try temp("notes.md", Array("# hi".utf8))
        XCTAssertEqual(FileSniffer.kind(of: url), .markdown(.commonMark))
    }

    func testQuartoAndMDXDialects() throws {
        XCTAssertEqual(FileSniffer.kind(of: try temp("a.qmd", [])), .markdown(.quarto))
        XCTAssertEqual(FileSniffer.kind(of: try temp("a.mdx", [])), .markdown(.mdx))
    }

    func testCSVAndTSVDelimiters() throws {
        XCTAssertEqual(FileSniffer.kind(of: try temp("a.csv", [])), .csv(delimiter: ","))
        XCTAssertEqual(FileSniffer.kind(of: try temp("a.tsv", [])), .csv(delimiter: "\t"))
    }

    func testSQLiteByHeaderWithUnknownExtension() throws {
        var bytes = Array("SQLite format 3".utf8); bytes.append(0); bytes += [UInt8](repeating: 0, count: 100)
        XCTAssertEqual(FileSniffer.kind(of: try temp("data.blob", bytes)), .sqlite)
    }

    /// Column files (B-4): by extension, and Parquet and Arrow files by their magic under any name. roadmap: S-21
    func testDatasetsByExtensionAndMagic() throws {
        XCTAssertEqual(FileSniffer.kind(of: try temp("trips.parquet", [])), .dataset(.parquet))
        XCTAssertEqual(FileSniffer.kind(of: try temp("t.arrow", [])), .dataset(.arrow))
        XCTAssertEqual(FileSniffer.kind(of: try temp("t.arrows", [])), .dataset(.arrowStream))
        XCTAssertEqual(FileSniffer.kind(of: try temp("t.feather", [])), .dataset(.feather))
        XCTAssertEqual(FileSniffer.kind(of: try temp("book.xlsx", [])), .dataset(.xlsx))
        XCTAssertEqual(FileSniffer.kind(of: try temp("part-0001", Array("PAR1".utf8) + [0, 0, 0])), .dataset(.parquet))
        XCTAssertEqual(FileSniffer.kind(of: try temp("frame.bin2", Array("ARROW1".utf8) + [0, 0])), .dataset(.arrow))
        XCTAssertEqual(FileKind.dataset(.xlsx).displayName, "Excel workbook")
    }

    func testBinaryByNulByte() throws {
        XCTAssertEqual(FileSniffer.kind(of: try temp("thing.bin", [0x4D, 0x5A, 0x00, 0x01])), .binary)
    }

    func testShebangPython() throws {
        let url = try temp("script", Array("#!/usr/bin/env python3\nprint(1)\n".utf8))
        XCTAssertEqual(FileSniffer.kind(of: url), .code(language: "python"))
    }

    func testShebangBash() throws {
        let url = try temp("run", Array("#!/bin/bash\necho hi\n".utf8))
        XCTAssertEqual(FileSniffer.kind(of: url), .code(language: "shell"))
    }

    func testSwiftSourceByExtension() throws {
        XCTAssertEqual(FileSniffer.kind(of: try temp("Main.swift", Array("let x = 1".utf8))), .code(language: "swift"))
    }

    func testFolderAndAppBundle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Thing.app"), withIntermediateDirectories: true)
        XCTAssertEqual(FileSniffer.kind(of: dir), .folder)
        XCTAssertEqual(FileSniffer.kind(of: dir.appendingPathComponent("Thing.app")), .appBundle)
    }

    /// S-23: pictures and fonts by their system type, and the web fonts and `.apng` macOS has no type for by their
    /// extension. SVG stays the SVG renderer's; a PDF is not an image.
    func testImagesAndFontsByTypeAndExtension() throws {
        let cases: [(String, FileKind)] = [
            ("a.jpg", .image), ("a.JPEG", .image), ("a.heic", .image), ("a.heics", .image), ("a.png", .image), ("a.apng", .image),
            ("a.webp", .image), ("a.gif", .image), ("a.tiff", .image), ("a.avif", .image), ("a.dng", .image), ("a.cr3", .image),
            ("a.ttf", .font), ("a.otf", .font), ("a.ttc", .font), ("a.woff", .font), ("a.woff2", .font),
            ("a.svg", .svg), ("a.pdf", .binary),
        ]
        for (name, kind) in cases { XCTAssertEqual(FileSniffer.kind(of: try temp(name, [0])), kind, name) }
    }

    /// S-8: the E-9 archives by extension, and by their first bytes when the extension says nothing. An ISO is an
    /// archive tree now; a DMG stays a disk image card.
    func testArchivesByExtension() throws {
        let cases: [(String, FileKind)] = [
            ("a.rar", .archive(.rar)), ("a.7z", .archive(.sevenZip)), ("a.tar.xz", .archive(.xz)), ("a.txz", .archive(.xz)),
            ("a.tar.zst", .archive(.zstd)), ("a.lz4", .archive(.lz4)), ("a.lzma", .archive(.lzma)), ("a.Z", .archive(.compress)),
            ("a.iso", .archive(.iso)), ("a.cpio", .archive(.cpio)), ("a.rpm", .archive(.rpm)), ("a.deb", .archive(.deb)),
            ("a.xar", .archive(.xar)), ("a.cab", .archive(.cab)), ("a.lzh", .archive(.lha)), ("a.jar", .archive(.jar)),
            ("a.war", .archive(.jar)), ("a.dmg", .diskImage), ("a.mobileconfig", .configurationProfile),
        ]
        for (name, kind) in cases { XCTAssertEqual(FileSniffer.kind(of: try temp(name, [0])), kind, name) }
    }

    func testArchivesByMagicBytes() throws {
        let cases: [([UInt8], FileKind.ArchiveFormat)] = [
            ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], .rar), ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], .sevenZip),
            ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], .xz), ([0x28, 0xB5, 0x2F, 0xFD], .zstd), ([0x04, 0x22, 0x4D, 0x18], .lz4),
            ([0xED, 0xAB, 0xEE, 0xDB, 3, 0], .rpm), (Array("xar!".utf8) + [0, 0x1C], .xar),
            (Array("MSCF".utf8) + [0, 0, 0, 0], .cab), (Array("!<arch>\ndebian-binary   ".utf8), .deb),
            (Array("BZh91AY&SY".utf8), .bzip2), ([0x1F, 0x9D, 0x90], .compress),
        ]
        for (bytes, format) in cases {
            XCTAssertEqual(FileSniffer.kind(of: try temp("blob", bytes + [0, 0, 0])), .archive(format), "\(format)")
        }
        // ISO 9660: "CD001" at 32,769, after a 32 KB system area.
        var iso = [UInt8](repeating: 0, count: 0x8000)
        iso += [1] + Array("CD001".utf8) + [UInt8](repeating: 0, count: 2042)
        XCTAssertEqual(FileSniffer.kind(of: try temp("disc", iso)), .archive(.iso))
        // A zip under an unknown extension stays what it was: documents are zips too.
        XCTAssertEqual(FileSniffer.kind(of: try temp("thing.bin", [0x50, 0x4B, 0x03, 0x04, 0, 0])), .binary)
    }

    func testUnknownTextIsPlainText() throws {
        XCTAssertEqual(FileSniffer.kind(of: try temp("README", Array("plain words".utf8))), .plainText)
    }

    /// A marimo notebook is a .py file that imports marimo and makes the app (A-8); detection reads the text, never
    /// the extension alone, and every other Python file stays Python. roadmap: S-21
    func testMarimoNotebooksByContentAndPlainPythonStaysPython() throws {
        let marimo = "import marimo\n\n__generated_with = \"0.9.14\"\napp = marimo.App(width=\"medium\")\n\n\n@app.cell\ndef __():\n    x = 1\n    return (x,)\n"
        XCTAssertEqual(FileSniffer.kind(of: try temp("explore.py", Array(marimo.utf8))), .code(language: "marimo"))
        // No __generated_with, any name for the app, Windows line ends.
        let bare = "import marimo\r\nnotebook = marimo.App()\r\n"
        XCTAssertEqual(FileSniffer.kind(of: try temp("bare.py", Array(bare.utf8))), .code(language: "marimo"))
        XCTAssertEqual(FileKind.code(language: "marimo").displayName, "marimo notebook")

        let plain = "import os\n\ndef main():\n    print(os.getcwd())\n"
        XCTAssertEqual(FileSniffer.kind(of: try temp("tool.py", Array(plain.utf8))), .code(language: "python"))
        // Mentions in a docstring, an indented import, or only one of the two markers: still Python.
        let q = "\"\"\""
        let docs = "\(q)How to start:\nimport marimo\napp = marimo.App()\n\(q)\nprint('docs')\n"
        XCTAssertEqual(FileSniffer.kind(of: try temp("docs.py", Array(docs.utf8))), .code(language: "python"))
        let indented = "def make():\n    import marimo\n    app = marimo.App()\n    return app\n"
        XCTAssertEqual(FileSniffer.kind(of: try temp("factory.py", Array(indented.utf8))), .code(language: "python"))
        XCTAssertEqual(FileSniffer.kind(of: try temp("half.py", Array("import marimo\nprint(marimo.__version__)\n".utf8))), .code(language: "python"))
        XCTAssertEqual(FileSniffer.kind(of: try temp("other.py", Array("import marimoish\napp = marimo.App()\n".utf8))), .code(language: "python"))
        // The extension still matters: the same text under another name is not routed as a notebook.
        XCTAssertNotEqual(FileSniffer.kind(of: try temp("explore.txt", Array(marimo.utf8))), .code(language: "marimo"))
    }
}
