// VitrineDetect — the plain-words name of each category, shared by the Settings tiles and the search labels (G-24),
// so a category reads the same in Detectors, in Spotlight and on a Finder tag.
import Foundation

extension Detector.Category {
    public var displayTitle: String {
        switch self {
        case .ai: return String(localized: "AI providers", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .cloud: return String(localized: "Cloud", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .payments: return String(localized: "Payments", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .scm: return String(localized: "Source control & packages", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .messaging: return String(localized: "Messaging & email", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .databases: return String(localized: "Databases", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .tokens: return String(localized: "Tokens & private keys", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .config: return String(localized: "Config files", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .personal: return String(localized: "Personal info", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .network: return String(localized: "Network", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        case .custom: return String(localized: "Your rules", bundle: .module, comment: "A kind of secret the detectors find, as a heading (Settings tiles, search labels).")
        }
    }
}
