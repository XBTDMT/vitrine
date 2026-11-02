import Foundation

/// The framework's own bundle (H-6): every user-facing string in VitrinePreviewKit resolves from its String Catalog
/// (`VitrinePreviewKit/Localizable.xcstrings`), not from the host process's main bundle, which in a Quick Look
/// extension is the `.appex`. Swift strings use `String(localized: "…", bundle: .previewKit, comment: "…")`; SwiftUI
/// literals pass `bundle: .previewKit`. roadmap: S-12
extension Bundle {
    static let previewKit = Bundle(for: PreviewKitBundleMarker.self)
}

/// A class in this framework, so `Bundle(for:)` finds the framework's bundle.
private final class PreviewKitBundleMarker {}
