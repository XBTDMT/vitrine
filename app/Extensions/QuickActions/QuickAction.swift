import Foundation

/// Finder Quick Actions (X-5): Open in Vitrine, Export as PDF, Export as HTML and Copy as Prompt.
///
/// Each action is its own UI-less Action extension (`com.apple.services`), because one extension is one entry in
/// Finder's Quick Actions menu and the preview pane. The four bundles share one principal class
/// (`QuickActionRequestHandler`) and tell it which action they are with the `VitrineQuickAction` key in their
/// Info.plist.
///
/// The extensions are sandboxed and read-only. Copy as Prompt runs inside the extension: it only reads the files and
/// writes the clipboard. Opening a window and writing a PDF or HTML file next to the document need the app, which is
/// not sandboxed. Those actions pass the selection to the app's matching Services entry (`NSServices` in
/// `Vitrine/Info.plist`) through `NSPerformService`. Services launch the app if it is not running.
///
/// Foundation only: compiled into the extensions, the app and the tests. roadmap: S-10 (X-5)
enum QuickAction: String, CaseIterable, Sendable {
    case open
    case exportPDF
    case exportHTML
    case copyPrompt

    /// The Info.plist key that names which action an extension bundle is.
    static let infoKey = "VitrineQuickAction"

    /// The action this extension bundle was built as; nil outside a Quick Action bundle.
    static func current(in bundle: Bundle = .main) -> QuickAction? {
        (bundle.object(forInfoDictionaryKey: infoKey) as? String).flatMap(QuickAction.init(rawValue:))
    }

    /// The app's Services entry that does the work (its `NSMenuItem` default title, the name `NSPerformService`
    /// takes); nil when the extension does the work itself.
    var serviceName: String? {
        switch self {
        case .open: return "Open in Vitrine"
        case .exportPDF: return "Export as PDF with Vitrine"
        case .exportHTML: return "Export as HTML with Vitrine"
        case .copyPrompt: return nil
        }
    }

    /// The `NSMessage` of that Services entry: the selector the app's services provider implements.
    var serviceMessage: String? {
        switch self {
        case .open: return "quickActionOpen"
        case .exportPDF: return "quickActionExportPDF"
        case .exportHTML: return "quickActionExportHTML"
        case .copyPrompt: return nil
        }
    }

    /// The most files one action takes, the same cap as a `vitrine://` request (VitrineRequest.maxFiles).
    static let maxFiles = 50

    /// Content types the PDF and HTML export take: the Markdown family, whose page holds the whole document
    /// (PreviewExport offers PDF and HTML only there). It is the Markdown extension's list without SVG.
    static let exportableTypes = [
        "net.daringfireball.markdown", "public.markdown",
        "io.github.xbtdmt.vitrine.mdx", "io.github.xbtdmt.vitrine.mdc", "io.github.xbtdmt.vitrine.qmd", "io.github.xbtdmt.vitrine.rmd",
        "org.textbundle.package", "org.python.restructuredtext", "org.asciidoc.asciidoc", "org.orgmode.org",
    ]
}
