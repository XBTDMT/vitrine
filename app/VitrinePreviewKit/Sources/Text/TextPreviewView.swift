import AppKit
import VitrineUI

/// A read-only monospaced text view on the page colours: the plain-text preview, and the "Source" view the
/// capsule's viewer switch shows for any document that has one. roadmap: S-4, S-24
@MainActor
enum TextPreviewView {
    static func make(text: String, context: RenderContext) -> (NSScrollView, NSTextView) {
        let p = context.tokens.palette(for: context.appearance)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(css: p.background) ?? .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textColor = NSColor(css: p.text) ?? .textColor
        textView.backgroundColor = NSColor(css: p.background) ?? .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scroll.documentView = textView
        return (scroll, textView)
    }
}
