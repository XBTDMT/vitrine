import Foundation
import VitrineDocument
import VitrineSupport

/// The metadata strip (I-13, settings r3-a, chrome r3-b): the facts the capsule's pill shows, in the person's order,
/// and how loud it is. Settings › General › Metadata strip writes three keys; every extension reads them through
/// its layered defaults (G-19). roadmap: S-24
public enum MetadataStrip {
    public enum Show: String, Sendable, CaseIterable {
        /// Quiet until the pointer is over the pill (the design's default).
        case hover
        case always
        /// The state dot only.
        case never
    }

    /// The facts the strip can show, in the default order.
    public enum Item: String, Sendable, CaseIterable, Identifiable {
        case kind, lines, size, encoding, tokens, git, dimensions, modified, owner
        public var id: String { rawValue }

        /// The chip's name in Settings.
        public var title: String {
            switch self {
            case .kind: String(localized: "Kind", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): the file's kind, such as Markdown.")
            case .lines: String(localized: "Lines / rows", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): line count of text, or rows and columns of a table.")
            case .size: String(localized: "Size", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): the file's size.")
            case .encoding: String(localized: "Encoding", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): the text encoding, such as UTF-8.")
            case .tokens: String(localized: "Tokens", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): the approximate language-model token count.")
            case .git: String(localized: "Git status", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): a repository's branch.")
            case .dimensions: String(localized: "Dimensions", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): a picture's width and height.")
            case .modified: String(localized: "Modified", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): when the file last changed.")
            case .owner: String(localized: "Owner app", bundle: .previewKit, comment: "Metadata strip fact (Settings chip): the app that opens the file by default.")
            }
        }
    }

    public static let showKey = "strip.show"
    public static let orderKey = "strip.order"
    public static let hiddenKey = "strip.hidden"
    /// Shown until the person changes it: the five the design draws on, the other four off.
    public static let defaultHidden: Set<Item> = [.git, .dimensions, .modified, .owner]

    public struct Settings: Sendable, Equatable {
        public var show: Show
        public var order: [Item]
        public var hidden: Set<Item>

        public static let standard = Settings(show: .hover, order: Item.allCases, hidden: MetadataStrip.defaultHidden)

        /// What the strip shows, in order.
        public var visible: [Item] { order.filter { !hidden.contains($0) } }

        /// From stored values; unknown names are dropped and facts missing from a stored order (a newer build added
        /// one) keep their default place at the end, so the list is always complete.
        public static func read(_ defaults: UserDefaults) -> Settings {
            let show = (defaults.string(forKey: showKey)).flatMap(Show.init(rawValue:)) ?? .hover
            var order = (defaults.stringArray(forKey: orderKey) ?? []).compactMap(Item.init(rawValue:))
            order = order.reduce(into: [Item]()) { if !$0.contains($1) { $0.append($1) } }
            order += Item.allCases.filter { !order.contains($0) }
            let hidden = defaults.stringArray(forKey: hiddenKey).map { Set($0.compactMap(Item.init(rawValue:))) } ?? defaultHidden
            return Settings(show: show, order: order, hidden: hidden)
        }

        public func write(_ defaults: UserDefaults) {
            defaults.set(show.rawValue, forKey: showKey)
            defaults.set(order.map(\.rawValue), forKey: orderKey)
            defaults.set(Item.allCases.filter { hidden.contains($0) }.map(\.rawValue), forKey: hiddenKey)
        }
    }

    /// What the host knows about the file that is not in the document.
    public struct FileFacts: Sendable, Equatable {
        public var modified: Date?
        public var owner: String?
        public init(modified: Date? = nil, owner: String? = nil) { self.modified = modified; self.owner = owner }
    }

    /// The pill's pieces for a document, in the strip's order; a fact the file does not have is skipped.
    public static func parts(_ d: PreviewDocument, settings: Settings, file: FileFacts = FileFacts()) -> [String] {
        settings.visible.compactMap { item -> String? in
            switch item {
            case .kind: return d.fact("kindName")?.value ?? d.kind.displayName
            case .lines:
                if let headline = d.fact("headline")?.value { return headline }
                // Text without a family headline says its line count with its unit ("227 lines", code at rest).
                if let value = d.fact("lines")?.value, let n = Int(value.filter(\.isNumber)) {
                    return String(localized: "\(n) lines", bundle: .previewKit, comment: "Capsule pill: a text file's line count.")
                }
                return d.fact("rows")?.value
            case .size: return d.fact("size")?.value
            case .encoding: return d.fact("encoding")?.value
            case .tokens:
                return d.fact("tokens").map {
                    String(localized: "\($0.value) tok", bundle: .previewKit,
                           comment: "Capsule pill: an approximate token count, e.g. '≈ 890 tok'. The value arrives formatted.")
                }
            case .git: return d.fact("branch")?.value
            case .dimensions:
                // A picture that already says its size as its headline is not told twice.
                guard let value = d.fact("dimensions")?.value, d.fact("headline")?.value != value || settings.hidden.contains(.lines) else { return nil }
                return value
            case .modified: return file.modified?.formatted(date: .abbreviated, time: .shortened)
            case .owner: return file.owner
            }
        }
    }
}
