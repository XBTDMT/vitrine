import XCTest
@testable import VitrineSupport

final class FileKindIdentifierTests: XCTestCase {
    private let every: [FileKind] = [
        .markdown(.commonMark), .markdown(.mdx), .markdown(.quarto), .markdown(.rMarkdown),
        .markdown(.reStructuredText), .markdown(.asciiDoc), .markdown(.org), .code(language: "objective-cpp"),
        .plainText, .csv(delimiter: ","), .csv(delimiter: "\t"), .csv(delimiter: ";"), .csv(delimiter: "\u{1F}"),
        .sqlite, .svg, .diff, .archive(.zip), .archive(.tar), .archive(.gzip), .archive(.bzip2), .archive(.ipa),
        .archive(.apk), .appBundle, .installerPackage, .diskImage, .torrent, .provisioningProfile, .folder, .binary,
        .archive(.jar), .archive(.rar), .archive(.sevenZip), .archive(.xz), .archive(.zstd), .archive(.lz4),
        .archive(.lzma), .archive(.lzip), .archive(.compress), .archive(.iso), .archive(.cpio), .archive(.rpm),
        .archive(.deb), .archive(.xar), .archive(.cab), .archive(.lha), .configurationProfile, .image, .font,
        .dataset(.parquet), .dataset(.arrow), .dataset(.arrowStream), .dataset(.feather), .dataset(.xlsx),
    ]

    func testEveryKindRoundTripsThroughItsIdentifier() {
        for kind in every {
            XCTAssertEqual(FileKind(identifier: kind.identifier), kind, kind.identifier)
        }
        XCTAssertEqual(Set(every.map(\.identifier)).count, every.count, "identifiers are unique")
    }

    func testReadableIdentifiers() {
        XCTAssertEqual(FileKind.markdown(.commonMark).identifier, "markdown.commonMark")
        XCTAssertEqual(FileKind.code(language: "python").identifier, "code.python")
        XCTAssertEqual(FileKind.csv(delimiter: "\t").identifier, "csv.tab")
        XCTAssertEqual(FileKind.csv(delimiter: "\u{1F}").identifier, "csv.u31")
    }

    func testUnknownIdentifiersAreRefused() throws {
        for bad in ["", "markdown", "markdown.wiki", "sqlite.x", "csv.", "archive.arj", "nope"] {
            XCTAssertNil(FileKind(identifier: bad), bad)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(FileKind.self, from: Data(#""markdown.wiki""#.utf8)))
    }

    func testJSONIsTheIdentifier() throws {
        let data = try JSONEncoder().encode([FileKind.code(language: "swift")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["code.swift"]"#)
        XCTAssertEqual(try JSONDecoder().decode([FileKind].self, from: data), [.code(language: "swift")])
    }
}

final class FileKindDisplayNameTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(FileKind.markdown(.commonMark).displayName, "Markdown")
        XCTAssertEqual(FileKind.code(language: "swift").displayName, "Swift")
        XCTAssertEqual(FileKind.code(language: "objective-c").displayName, "Objective-C")
        XCTAssertEqual(FileKind.csv(delimiter: "\t").displayName, "TSV")
        XCTAssertEqual(FileKind.plainText.displayName, "Text")
    }
}
