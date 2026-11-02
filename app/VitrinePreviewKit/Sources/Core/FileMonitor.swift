import Foundation

/// Watches the previewed file and reports changes, debounced. Editors save by writing a temp file and renaming it
/// over the original, so a plain vnode watch on the open descriptor goes stale after the first save; this monitor
/// watches the parent directory for the rename and re-arms on the new inode. Runs its callbacks on the main actor.
@MainActor
public final class FileMonitor {
    public typealias Handler = @MainActor () -> Void

    private let url: URL
    private let debounce: TimeInterval
    private let handler: Handler
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var lastModification: Date?

    public init(url: URL, debounce: TimeInterval = 0.08, handler: @escaping Handler) {
        self.url = url
        self.debounce = debounce
        self.handler = handler
        self.lastModification = Self.modificationDate(url)
        armFile()
        armDirectory()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    public func stop() {
        fileSource?.cancel(); fileSource = nil
        directorySource?.cancel(); directorySource = nil
        pending?.cancel(); pending = nil
    }

    private func armFile() {
        fileSource?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { fileSource = nil; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                // The editor replaced the file; re-arm on whatever now lives at the path.
                self.armFile()
            }
            self.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func armDirectory() {
        let dir = url.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Directory contents changed: a temp-and-rename save lands here. Re-arm if the inode moved.
            self.armFile()
            self.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Self.modificationDate(self.url)
            guard now != self.lastModification else { return }
            self.lastModification = now
            self.handler()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
