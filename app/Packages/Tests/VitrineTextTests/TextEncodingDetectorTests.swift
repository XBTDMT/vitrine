import XCTest
@testable import VitrineText

/// Reading text in the right encoding (S-5, code state 3). All content is invented here. roadmap: S-5
final class TextEncodingDetectorTests: XCTestCase {
    private let owner = "# Owner: Zoë Martín – platform team — notes\n"

    func testUTF8IsReadAsUTF8() {
        let d = TextEncodingDetector.decode(Data(owner.utf8))
        XCTAssertEqual(d.name, "UTF-8")
        XCTAssertFalse(d.detected)
        XCTAssertEqual(d.text, owner)
    }

    func testWindows1252IsDetectedAndItsCharactersSurvive() throws {
        let bytes = try XCTUnwrap(owner.data(using: .windowsCP1252))
        let d = TextEncodingDetector.decode(bytes)
        XCTAssertEqual(d.name, "Windows-1252")
        XCTAssertTrue(d.detected)
        XCTAssertEqual(d.text, owner)
        XCTAssertEqual(d.samples, ["ë", "í", "–", "—"])
        XCTAssertFalse(d.lossy)
    }

    func testByteOrderMarksAreHonouredAndDropped() throws {
        let bom8 = Data([0xEF, 0xBB, 0xBF]) + Data("lumen".utf8)
        XCTAssertEqual(TextEncodingDetector.decode(bom8).text, "lumen")
        XCTAssertTrue(TextEncodingDetector.decode(bom8).hadBOM)
        let le = Data([0xFF, 0xFE]) + (try XCTUnwrap("Zoë".data(using: .utf16LittleEndian)))
        let d = TextEncodingDetector.decode(le)
        XCTAssertEqual(d.name, "UTF-16LE")
        XCTAssertEqual(d.text, "Zoë")
    }

    func testUTF16WithoutAMarkIsRecognised() throws {
        let d = TextEncodingDetector.decode(try XCTUnwrap("set -euo pipefail\nlog done\n".data(using: .utf16LittleEndian)))
        XCTAssertEqual(d.name, "UTF-16LE")
        XCTAssertEqual(d.text, "set -euo pipefail\nlog done\n")
    }

    func testAPartialReadMayEndInsideACharacter() {
        let cut = Data("Zoë Martí".utf8).dropLast(1) // the last "í" is two bytes; one is left
        XCTAssertEqual(TextEncodingDetector.decode(Data(cut), partial: true).name, "UTF-8")
        XCTAssertNotEqual(TextEncodingDetector.decode(Data(cut), partial: false).name, "UTF-8")
    }

    func testAChosenEncodingIsUsed() throws {
        let bytes = try XCTUnwrap(owner.data(using: .windowsCP1252))
        let d = TextEncodingDetector.decode(bytes, as: .macOSRoman)
        XCTAssertEqual(d.name, "Mac OS Roman")
        XCTAssertFalse(d.detected)
        XCTAssertNotEqual(d.text, owner)
    }
}
