import AppKit
import Foundation

/// A Finder tag on an item: its name and Finder's colour number (0 none, 1 grey, 2 green, 3 purple, 4 blue,
/// 5 yellow, 6 red, 7 orange), read from the item's tag list without asking Finder. roadmap: S-9
struct FinderTag: Sendable, Equatable {
    let name: String
    let color: Int

    /// The tag dot's colour (`.tag`); nil = no colour (the dot is not drawn).
    var nsColor: NSColor? {
        switch color {
        case 1: .systemGray
        case 2: .systemGreen
        case 3: .systemPurple
        case 4: .systemBlue
        case 5: .systemYellow
        case 6: .systemRed
        case 7: .systemOrange
        default: nil
        }
    }

    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// The item's tags with their colours: the tag list attribute holds "Name\nN" strings in a property list. When
    /// it cannot be read, the names from `URLResourceValues.tagNames` come back without colours.
    /// The attribute is read first: `tagNames` comes from a resource-value cache that can lag a fresh write.
    static func read(_ url: URL, names: [String]?) -> [FinderTag] {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        if size > 0, size < 64 << 10 {
            var bytes = [UInt8](repeating: 0, count: size)
            let read = getxattr(url.path, attribute, &bytes, size, 0, XATTR_NOFOLLOW)
            if read == size, let tags = parse(Data(bytes)), !tags.isEmpty { return tags }
        }
        return (names ?? []).map { FinderTag(name: $0, color: 0) }
    }

    /// The attribute's property list: an array of "Name" or "Name\nN".
    static func parse(_ data: Data) -> [FinderTag]? {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
        return list.map { entry in
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return FinderTag(name: String(parts[0]), color: parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
    }
}

/// How the folder list is sorted and grouped (O-2): by name, kind, date modified, date added, size or tags, with
/// Finder's group headers ("Today 3", "Yesterday 4"). Pure: the outline asks it for rows. roadmap: S-9
struct FolderArrangement: Equatable {
    enum Key: String, CaseIterable, Sendable {
        case name, kind, modified, added, size, tags

        var title: String {
            switch self {
            case .name: String(localized: "Name", bundle: .previewKit, comment: "Folder list: sort or group by name; also a column header.")
            case .kind: String(localized: "Kind", bundle: .previewKit, comment: "Folder list: sort or group by kind; also a column header.")
            case .modified: String(localized: "Date Modified", bundle: .previewKit, comment: "Folder list: sort or group by date modified; also a column header.")
            case .added: String(localized: "Date Added", bundle: .previewKit, comment: "Folder list: sort or group by date added; also a column header.")
            case .size: String(localized: "Size", bundle: .previewKit, comment: "Folder list: sort or group by size; also a column header.")
            case .tags: String(localized: "Tags", bundle: .previewKit, comment: "Folder list: sort or group by Finder tags.")
            }
        }

        /// Newest and largest first, words A to Z.
        var defaultAscending: Bool { ![.modified, .added, .size].contains(self) }
    }

    enum Row {
        case group(title: String, count: Int)
        case node(FolderNode)
    }

    var sort: Key = .name
    var ascending = true
    var group: Key?

    /// The list's date column follows the arrangement: Date Added when that is what it is sorted or grouped by.
    var dateColumn: Key { sort == .added || group == .added ? .added : .modified }

    /// `nodes` in this order. A folder's size is what `size` says (nil while it is counted); folders stay on top
    /// when sorted by name, as Finder keeps them.
    @MainActor func sorted(_ nodes: [FolderNode], size: (FolderNode) -> Int64?) -> [FolderNode] {
        let byName: (FolderNode, FolderNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func order<T: Comparable>(_ a: T?, _ b: T?, _ x: FolderNode, _ y: FolderNode) -> Bool {
            switch (a, b) {
            case let (a?, b?) where a != b: return ascending ? a < b : a > b
            case (nil, _?): return false             // unknown last, either way
            case (_?, nil): return true
            default: return byName(x, y)
            }
        }
        return nodes.sorted { x, y in
            switch sort {
            case .name:
                if x.isFolder != y.isFolder { return x.isFolder }
                let c = x.name.localizedStandardCompare(y.name)
                return c == .orderedSame ? false : (c == .orderedAscending) == ascending
            case .kind:
                let c = x.kind.localizedStandardCompare(y.kind)
                return c == .orderedSame ? byName(x, y) : (c == .orderedAscending) == ascending
            case .modified: return order(x.modified, y.modified, x, y)
            case .added: return order(x.added, y.added, x, y)
            case .size: return order(size(x), size(y), x, y)
            case .tags:
                switch (x.tags.first?.name, y.tags.first?.name) {
                case let (a?, b?) where a != b: return (a.localizedStandardCompare(b) == .orderedAscending) == ascending
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byName(x, y)
                }
            }
        }
    }

    /// The rows the list shows: the sorted nodes, under group headers when grouped.
    @MainActor func rows(_ nodes: [FolderNode], size: (FolderNode) -> Int64?, now: Date = Date(), calendar: Calendar = .current) -> [Row] {
        let ordered = sorted(nodes, size: size)
        guard let group else { return ordered.map(Row.node) }
        var buckets: [String: (rank: Int, members: [FolderNode])] = [:]
        var titles: [String] = []
        for n in ordered {
            let (rank, title) = Self.bucket(n, key: group, size: size(n), now: now, calendar: calendar)
            if buckets[title] == nil { titles.append(title); buckets[title] = (rank, []) }
            buckets[title]?.members.append(n)
        }
        // Groups in the key's own order (newest, largest, A to Z), turned around when the list is sorted the
        // other way by that same key.
        let reverse = group == sort && ascending != group.defaultAscending
        titles.sort { a, b in
            let ra = buckets[a]!.rank, rb = buckets[b]!.rank
            if ra != rb { return reverse ? ra > rb : ra < rb }
            let c = a.localizedStandardCompare(b) == .orderedAscending
            return reverse ? !c : c
        }
        return titles.flatMap { t in [Row.group(title: t, count: buckets[t]!.members.count)] + buckets[t]!.members.map(Row.node) }
    }

    /// The group a node falls in, with a rank that orders the groups (ties go by title).
    @MainActor static func bucket(_ n: FolderNode, key: Key, size: Int64?, now: Date, calendar: Calendar) -> (Int, String) {
        switch key {
        case .name:
            guard let first = n.name.first, first.isLetter else { return (1, "#") }
            return (0, String(first).uppercased())
        case .kind: return (0, n.kind)
        case .tags: return n.tags.first.map { (0, $0.name) } ?? (1, String(localized: "No Tags", bundle: .previewKit, comment: "Folder list group header: items with no Finder tags."))
        case .size:
            guard let size else { return (5, String(localized: "Size Not Known Yet", bundle: .previewKit, comment: "Folder list group header: items whose size is still being counted.")) }
            let mb: Int64 = 1_000_000
            func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            let kb100 = text(100_000), mb1 = text(mb), mb100 = text(100 * mb), gb1 = text(1_000 * mb)
            if size >= 1_000 * mb { return (0, String(localized: "\(gb1) or More", bundle: .previewKit, comment: "Folder list group header by size; the argument is a size (1 GB).")) }
            if size >= 100 * mb { return (1, String(localized: "\(mb100) to \(gb1)", bundle: .previewKit, comment: "Folder list group header: a size range (100 MB to 1 GB).")) }
            if size >= mb { return (2, String(localized: "\(mb1) to \(mb100)", bundle: .previewKit, comment: "Folder list group header: a size range (1 MB to 100 MB).")) }
            if size >= 100_000 { return (3, String(localized: "\(kb100) to \(mb1)", bundle: .previewKit, comment: "Folder list group header: a size range (100 KB to 1 MB).")) }
            return (4, String(localized: "Less Than \(kb100)", bundle: .previewKit, comment: "Folder list group header by size; the argument is a size (100 KB)."))
        case .modified, .added:
            guard let date = key == .added ? n.added : n.modified else {
                return (Int.max, String(localized: "No Date", bundle: .previewKit, comment: "Folder list group header: items with no date."))
            }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            if days <= 0 { return (0, String(localized: "Today", bundle: .previewKit, comment: "Folder list group header by date.")) }
            if days == 1 { return (1, String(localized: "Yesterday", bundle: .previewKit, comment: "Folder list group header by date.")) }
            if days <= 7 { return (2, String(localized: "Previous 7 Days", bundle: .previewKit, comment: "Folder list group header by date.")) }
            if days <= 30 { return (3, String(localized: "Previous 30 Days", bundle: .previewKit, comment: "Folder list group header by date.")) }
            let year = calendar.component(.year, from: date), thisYear = calendar.component(.year, from: now)
            if year == thisYear {
                let month = calendar.component(.month, from: date)
                return (100 + (12 - month), calendar.standaloneMonthSymbols[month - 1])
            }
            return (1_000 + (thisYear - year), date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).year()))
        }
    }
}
