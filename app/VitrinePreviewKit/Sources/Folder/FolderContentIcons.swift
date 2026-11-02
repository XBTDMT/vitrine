import AppKit
import CoreServices

/// Folder contents on Finder's icon, for folders a person chooses (O-3, G-18 ruled B): Quick Look never asks a
/// thumbnail extension for folders, so Vitrine sets a custom folder icon — the system folder with the newest items
/// drawn on its front (FolderThumbnail) — refreshes it when what the icon shows has changed, and puts the plain icon
/// back on Remove. Only folders on the chosen list are ever written to; the write is macOS's own custom-icon file
/// (`Icon\r`, invisible), which synced folders carry along. Runs in the Vitrine app, never in an extension (the
/// sandbox forbids writing into folders). roadmap: S-9
@MainActor
public enum FolderContentIcons {
    /// Chosen folders, kept in Vitrine's settings.
    static let listKey = "folders.contentIcons"
    /// What each chosen folder's icon was drawn from (names and dates of the items shown), to skip a redraw.
    static let signatureKey = "folders.contentIconSignatures"
    /// The look (FolderThumbnail.Style's raw value); fan unless set — the maintainer's pick, 2026-10-30 (G-18).
    static let styleKey = "folders.contentIconStyle"
    /// The file macOS keeps a folder's custom icon in.
    public static let iconFileName = "Icon\r"
    /// Posted when the chosen list changes, so the watcher follows it.
    public static let listChanged = Notification.Name("io.github.xbtdmt.vitrine.folderIconsChanged")

    // MARK: Drawing

    /// The icon at the sizes Finder draws (16 to 1024 pixels): the plain folder at 16, the cards from 32 up.
    public static func style(_ defaults: UserDefaults = VitrineDefaults.shared) -> FolderThumbnail.Style {
        defaults.string(forKey: styleKey).flatMap(FolderThumbnail.Style.init(rawValue:)) ?? .fan
    }

    public static func image(for folder: URL, style: FolderThumbnail.Style = style()) -> NSImage {
        let items = FolderThumbnail.items(in: folder, limit: style.itemCount, pixelSize: 512)
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            FolderThumbnail.draw(items, in: context.cgContext, size: CGSize(width: pixels, height: pixels), style: style)
            rep.size = NSSize(width: 512, height: 512)
            image.addRepresentation(rep)
        }
        return image
    }

    // MARK: One folder

    public enum Failure: Error, Equatable, LocalizedError {
        case notAFolder(String), notWritable(String), refused(String)
        public var errorDescription: String? {
            switch self {
            case .notAFolder(let p): String(localized: "\(p) is not a folder.", bundle: .previewKit, comment: "Error when choosing a folder icon; the argument is a path.")
            case .notWritable(let p): String(localized: "\(p) cannot be written to, so its icon cannot change.", bundle: .previewKit, comment: "Error when choosing a folder icon; the argument is a path.")
            case .refused(let p): String(localized: "macOS did not set the icon on \(p).", bundle: .previewKit, comment: "Error when choosing a folder icon; the argument is a path.")
            }
        }
    }

    /// Draws and sets the folder's icon now.
    public static func apply(to folder: URL, style: FolderThumbnail.Style = style()) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.notAFolder(folder.path)
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw Failure.notWritable(folder.path) }
        guard NSWorkspace.shared.setIcon(image(for: folder, style: style), forFile: folder.path, options: []) else { throw Failure.refused(folder.path) }
    }

    /// The plain folder icon again (the `Icon\r` file goes).
    public static func remove(from folder: URL) {
        NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: [])
    }

    public static func hasCustomIcon(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(iconFileName).path)
    }

    /// The names and dates of the items an icon shows: a different signature means the icon is out of date.
    static func signature(of folder: URL, style: FolderThumbnail.Style = .fan) -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dated = urls.prefix(500).filter { $0.lastPathComponent != iconFileName }.map { url in
            (url.lastPathComponent, (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }.sorted { $0.1 > $1.1 }.prefix(style.itemCount)
        // The look is part of what the icon was drawn from: a new look redraws every chosen folder.
        return style.rawValue + ":" + dated.map { "\($0.0)@\(Int($0.1))" }.joined(separator: "|")
    }

    // MARK: The chosen list

    public static func chosen(_ defaults: UserDefaults = VitrineDefaults.shared) -> [URL] {
        (defaults.stringArray(forKey: listKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Adds the folder to the list and draws its icon.
    public static func choose(_ folder: URL, defaults: UserDefaults = VitrineDefaults.shared) throws {
        try apply(to: folder, style: style(defaults))
        var list = defaults.stringArray(forKey: listKey) ?? []
        if !list.contains(folder.path) { list.append(folder.path) }
        defaults.set(list, forKey: listKey)
        var signatures = defaults.dictionary(forKey: signatureKey) as? [String: String] ?? [:]
        signatures[folder.path] = signature(of: folder, style: style(defaults))
        defaults.set(signatures, forKey: signatureKey)
        NotificationCenter.default.post(name: listChanged, object: nil)
    }

    /// Takes the folder off the list and puts its plain icon back.
    public static func unchoose(_ folder: URL, defaults: UserDefaults = VitrineDefaults.shared) {
        remove(from: folder)
        defaults.set((defaults.stringArray(forKey: listKey) ?? []).filter { $0 != folder.path }, forKey: listKey)
        var signatures = defaults.dictionary(forKey: signatureKey) as? [String: String] ?? [:]
        signatures[folder.path] = nil
        defaults.set(signatures, forKey: signatureKey)
        NotificationCenter.default.post(name: listChanged, object: nil)
    }

    /// Redraws every chosen folder whose newest items changed (or whose icon was removed outside Vitrine); a folder
    /// that no longer exists stays on the list until it is unchosen. Returns the folders redrawn.
    @discardableResult
    public static func refresh(defaults: UserDefaults = VitrineDefaults.shared) -> [URL] {
        var signatures = defaults.dictionary(forKey: signatureKey) as? [String: String] ?? [:]
        var redrawn: [URL] = []
        for folder in chosen(defaults) where FileManager.default.fileExists(atPath: folder.path) {
            let now = signature(of: folder, style: style(defaults))
            guard now != signatures[folder.path] || !hasCustomIcon(folder) else { continue }
            if (try? apply(to: folder, style: style(defaults))) != nil {
                signatures[folder.path] = now
                redrawn.append(folder)
            }
        }
        defaults.set(signatures, forKey: signatureKey)
        return redrawn
    }
}

/// Watches the chosen folders while Vitrine runs and refreshes their icons a moment after their contents change
/// (FSEvents, latency 2 s; the icon's own write is ignored by the signature check). roadmap: S-9
@MainActor
public final class FolderIconWatcher {
    private var stream: FSEventStreamRef?
    private let defaults: UserDefaults

    private var observer: NSObjectProtocol?

    public init(defaults: UserDefaults = VitrineDefaults.shared) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: FolderContentIcons.listChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.stream != nil || !FolderContentIcons.chosen(self?.defaults ?? .standard).isEmpty { self?.start() } }
        }
    }

    public func start() {
        stop()
        let paths = FolderContentIcons.chosen(defaults).map(\.path) as CFArray
        guard CFArrayGetCount(paths) > 0 else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderIconWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in FolderContentIcons.refresh(defaults: watcher.defaults) }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
