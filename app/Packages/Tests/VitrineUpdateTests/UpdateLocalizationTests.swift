import Foundation
import Testing
@testable import VitrineUpdate

// The updater's messages resolve from VitrineUpdate's own String Catalog (H-6): they used to be looked up in the main
// bundle while their translations sat in this package's bundle, so every language showed English. roadmap: S-13

@Suite("Update messages are translated")
struct UpdateLocalizationTests {
    func text(_ key: String, in language: String) -> String? {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test func everyLanguageHasTheMessages() {
        let key = "A file step of the update failed."
        #expect(text(key, in: "de") == "Ein Dateischritt des Updates ist fehlgeschlagen.")
        for language in ["fr", "ja", "ko"] {
            let found = text(key, in: language)
            #expect(found != nil && found != key, "\(language) has its own words")
        }
    }

    @Test func anInterpolatedMessageKeepsItsPlaceholder() {
        let key = "The update server answered with error %lld."
        let german = text(key, in: "de") ?? ""
        #expect(german.contains("%lld") && german != key)
    }
}
