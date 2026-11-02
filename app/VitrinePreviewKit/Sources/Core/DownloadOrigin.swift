import Darwin
import Foundation
import VitrineDocument

/// Where a downloaded file came from (T-1, trust r3-a's Details: "downloaded from · downloaded with"): macOS writes
/// the address into `com.apple.metadata:kMDItemWhereFroms` and the app that downloaded it into `com.apple.quarantine`.
/// Read-only, from the file's own attributes; nothing is looked up. roadmap: S-20
public enum DownloadOrigin {
    public struct Origin: Sendable, Equatable {
        /// The address the file was downloaded from (the first of `kMDItemWhereFroms`).
        public var url: String?
        /// The app that downloaded it ("Safari", "Google Chrome").
        public var agent: String?
        /// macOS marked it as downloaded (`com.apple.quarantine`): Gatekeeper checks it the first time it opens.
        public var quarantined = false
    }

    public static func read(_ url: URL) -> Origin? {
        let fromData = attribute("com.apple.metadata:kMDItemWhereFroms", of: url)
        let froms = fromData.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String] }
        let quarantine = attribute("com.apple.quarantine", of: url).map { String(decoding: $0, as: UTF8.self) }
        // "0083;6543a1b2;Safari;0A1B2C3D-…": flags, date, agent, event id.
        let agent = quarantine.flatMap { q -> String? in
            let fields = q.split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count > 2, !fields[2].isEmpty else { return nil }
            return String(fields[2])
        }
        let origin = Origin(url: froms?.first(where: { !$0.isEmpty }), agent: agent, quarantined: quarantine != nil)
        return origin.url == nil && !origin.quarantined ? nil : origin
    }

    /// The facts a card's Details show; none for a file that was not downloaded.
    public static func facts(for url: URL) -> [Fact] {
        guard let origin = read(url) else { return [] }
        var facts: [Fact] = []
        if let address = origin.url {
            let shown = URLComponents(string: address).map { ($0.host ?? "") + $0.path } ?? address
            facts.append(Fact(key: "downloadedFrom", label: String(localized: "Downloaded from", bundle: .previewKit, comment: "Card detail: the address a file was downloaded from."),
                              value: shown.isEmpty ? address : shown))
        }
        if origin.quarantined {
            facts.append(Fact(key: "quarantined", label: String(localized: "Marked as downloaded", bundle: .previewKit, comment: "Card detail: macOS marked the file as downloaded, so Gatekeeper checks it at first open."),
                              value: String(localized: "Yes", bundle: .previewKit, comment: "A fact's value: yes.")))
        }
        if let agent = origin.agent {
            facts.append(Fact(key: "downloadedWith", label: String(localized: "Downloaded with", bundle: .previewKit, comment: "Card detail: the app that downloaded the file."),
                              value: agent))
        }
        return facts
    }

    static func attribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size < 1 << 20 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
    }
}
