import Foundation

/// Settings › File Types › "Finder thumbnails" (S-18): one switch, read from the app group the extensions share.
/// roadmap: S-18
public enum ThumbnailSettings {
    public static let key = "thumbnails.enabled"
    public static let suite = "MPD7MLYSRW.io.github.xbtdmt.vitrine"

    /// On unless the person switched it off.
    public static var isOn: Bool { (UserDefaults(suiteName: suite)?.object(forKey: key) as? Bool) ?? true }
}
