import Combine
import Foundation
import VitrineEngineering

/// Vulnerability hints' databases (G-26): on Update Now (or weekly, if the person turned that on) the app downloads
/// OSV's public `<ECOSYSTEM>/all.zip` for each ecosystem the person picked in Settings › Privacy, builds VitrineEngineering's
/// compact AdvisoryIndex from its records and writes it to the app group, where the previews read it. Whole files
/// only: no package name or version is ever sent. roadmap: S-22
@MainActor
final class AdvisoryUpdater: ObservableObject {
    static let shared = AdvisoryUpdater()

    enum Phase: Equatable {
        case idle
        case downloading(OSVEcosystem, Double)
        case building(OSVEcosystem)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var installed: [OSVEcosystem: AdvisoryIndex.Meta] = [:]
    private var work: Task<Void, Never>?

    static let base = URL(string: "https://storage.googleapis.com/osv-vulnerabilities/")!
    static let weekly: TimeInterval = 7 * 24 * 3600

    init() { refreshInstalled() }

    func refreshInstalled() {
        var found: [OSVEcosystem: AdvisoryIndex.Meta] = [:]
        for e in AdvisoryStore.offered {
            if let url = AdvisoryStore.indexURL(e), let index = try? AdvisoryIndex.read(from: url) { found[e] = index.meta }
        }
        installed = found
    }

    var isBusy: Bool { work != nil }

    /// Downloads and indexes every chosen ecosystem, one after another; removes the indexes of ecosystems no longer chosen.
    func updateNow() {
        guard work == nil, AdvisoryStore.isEnabled else { return }
        let chosen = AdvisoryStore.offered.filter(AdvisoryStore.isChosen)
        for e in AdvisoryStore.offered where !chosen.contains(e) { remove(e) }
        work = Task {
            defer { work = nil; if case .failed = phase {} else { phase = .idle }; refreshInstalled() }
            for e in chosen {
                if Task.isCancelled { return }
                do { try await update(e) } catch is CancellationError { return } catch {
                    phase = .failed(String(localized: "\(e.rawValue): \(error.localizedDescription)", comment: "Settings › Privacy: a vulnerability database update failed; the ecosystem, then the reason."))
                    return
                }
            }
        }
    }

    func cancel() { work?.cancel() }

    func remove(_ e: OSVEcosystem) {
        if let url = AdvisoryStore.indexURL(e) { try? FileManager.default.removeItem(at: url) }
        installed[e] = nil
    }

    /// At launch: a weekly refresh, when the person asked for one and the oldest chosen database is a week old.
    func runWeeklyIfDue() {
        let defaults = UserDefaults(suiteName: AdvisoryStore.suite)
        guard AdvisoryStore.isEnabled, defaults?.bool(forKey: AdvisoryStore.weeklyKey) == true else { return }
        let chosen = AdvisoryStore.offered.filter(AdvisoryStore.isChosen)
        let due = chosen.contains { installed[$0].map { Date().timeIntervalSince($0.builtAt) > Self.weekly } ?? true }
        if due { updateNow() }
    }

    private func update(_ e: OSVEcosystem) async throws {
        guard let destination = AdvisoryStore.indexURL(e) else { throw CocoaError(.fileNoSuchFile) }
        phase = .downloading(e, 0)
        let url = Self.base.appendingPathComponent(e.rawValue).appendingPathComponent("all.zip")
        let (zip, lastModified) = try await Download.run(url) { [weak self] fraction in
            Task { @MainActor in if case .downloading(e, _) = self?.phase { self?.phase = .downloading(e, fraction) } }
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        phase = .building(e)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let index = try Self.buildIndex(e, zip: zip, lastModified: lastModified)
            try index.write(to: destination)
        }.value
    }

    nonisolated static func buildIndex(_ e: OSVEcosystem, zip: URL, lastModified: Date?) throws -> AdvisoryIndex {
        try AdvisoryStore.buildIndex(e, zip: zip, lastModified: lastModified)
    }
}

/// One file download with progress, kept outside the main actor; the file is moved out of URLSession's temporary
/// location before the delegate returns. roadmap: S-22
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<(URL, Date?), Error>?
    private let progress: @Sendable (Double) -> Void
    private var lastReported = -1.0

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func run(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, Date?) {
        let delegate = Download(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.01 { lastReported = fraction; progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            continuation?.resume(throwing: URLError(.badServerResponse)); continuation = nil; return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-advisories-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            let modified = (response.value(forHTTPHeaderField: "Last-Modified")).flatMap { Self.httpDate.date(from: $0) }
            continuation?.resume(returning: (kept, modified))
        } catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        continuation = nil
    }

    static let httpDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f
    }()
}
