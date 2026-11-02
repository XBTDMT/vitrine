import CoreServices
import Foundation
import VitrineSpotlight

/// One file for Spotlight (S-19, X-8): the text VitrineSpotlight reads from a database, column file, notebook or
/// archive goes into the attributes Spotlight searches. Returns false (Spotlight keeps only its own attributes) for
/// anything Vitrine does not read or cannot open. Called from Importer.c on Spotlight's worker; it never writes and
/// never runs anything. roadmap: S-19
@_cdecl("VitrineSpotlightImport")
public func vitrineSpotlightImport(_ attributes: CFMutableDictionary, _ contentType: CFString, _ path: CFString) -> Bool {
    autoreleasepool {
        guard let record = SpotlightText.record(for: URL(fileURLWithPath: path as String)) else { return false }
        let dict = attributes as NSMutableDictionary
        dict[kMDItemTextContent as String] = record.text
        if let title = record.title, !title.isEmpty { dict[kMDItemTitle as String] = title }
        if !record.keywords.isEmpty { dict[kMDItemKeywords as String] = record.keywords }
        return true
    }
}
