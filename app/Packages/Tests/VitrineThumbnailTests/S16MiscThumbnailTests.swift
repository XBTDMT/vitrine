import Foundation
import Testing
import VitrineSupport
@testable import VitrineThumbnail

/// S-16 F45: a Finder thumbnail of a key = value file masks a value whose key names a secret, as the Code preview
/// does, even when the value is too plain for the detectors (short, no digit, low entropy). Every sample is invented
/// and passed as bytes; nothing is written to disk. roadmap: S-16
@Suite("S-16 F45: key-name masking in thumbnails")
struct S16MiscThumbnailTests {
    static let config = """
        POSTGRES_PASSWORD=harborharbor
        SMTP_PASSWORD=aaabbbccc
        DB_PWD=tide
        APP_NAME=harbor
        """

    func drawn(_ text: String, kind: FileKind, name: String) -> String {
        let data = Data(text.utf8)
        let page = ThumbnailPage.make(data: data, fileName: name, fileSize: Int64(data.count), kind: kind)
        guard case .text(let lines, _, _) = page.layout else { Issue.record("not text"); return "" }
        return lines.map { $0.map(\.text).joined() }.joined(separator: "\n")
    }

    @Test(arguments: [("dotenv", "app.env"), ("properties", "app.properties"), ("ini", "app.ini"), ("ini", "app.conf")])
    func plainPasswordsUnderSecretKeysAreMasked(language: String, name: String) {
        let text = drawn(Self.config, kind: .code(language: language), name: name)
        for value in ["harborharbor", "aaabbbccc", "tide"] {
            #expect(!text.contains("=\(value)"), "\(name): the value of a secret key is drawn in clear")
        }
        #expect(text.contains("POSTGRES_PASSWORD="), "the key stays")
        #expect(text.contains("APP_NAME=harbor"), "an ordinary value stays")
        #expect(text.contains("•"))
    }

    @Test func otherLanguagesAreLeftToTheDetectors() {
        // Source code is not key = value text: `let token = …` is code, so the key-name pass does not run there.
        let text = drawn("let tokenCount = 3\n", kind: .code(language: "swift"), name: "a.swift")
        #expect(text.contains("tokenCount = 3"))
    }
}
