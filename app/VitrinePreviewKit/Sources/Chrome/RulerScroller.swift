import AppKit
import VitrineUI

/// The shared ruler (C-8, B-7) for the natively drawn previews: a 12 pt vertical scroller in the design's look,
/// with the find matches marked where they sit in the whole document (the current one stronger) over a thumb for
/// what is in view. The web previews draw the same ruler in their pages; this is its AppKit twin, so every preview
/// scrolls and maps its matches the same way. roadmap: S-24
@MainActor
final class RulerScroller: NSScroller {
    enum Kind { case match, current }

    /// Each mark's place in the document, 0 at the top and 1 at the bottom.
    var marks: [(at: Double, kind: Kind)] = [] { didSet { needsDisplay = true } }

    static let width: CGFloat = 12

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { width }
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    /// Gives `scroll` the ruler as its vertical scroller (always shown, never an overlay); returns it.
    @discardableResult
    static func install(on scroll: NSScrollView) -> RulerScroller {
        if let existing = scroll.verticalScroller as? RulerScroller { return existing }
        let ruler = RulerScroller()
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.verticalScroller = ruler
        scroll.tile()
        return ruler
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) {
        NSColor.token("page").setFill()
        bounds.fill()
        NSColor.token("sep").setFill()
        NSRect(x: 0, y: 0, width: 0.5, height: bounds.height).fill()
        for mark in marks {
            let height: CGFloat = mark.kind == .current ? 4 : 3
            let y = (bounds.height - height) * CGFloat(min(max(mark.at, 0), 1))
            NSColor.token("find-cur").withAlphaComponent(mark.kind == .current ? 1 : 0.75).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: y, width: bounds.width - 4, height: height), xRadius: 1, yRadius: 1).fill()
        }
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0, knobProportion < 1 else { return }
        NSColor.token("fill2").setFill()
        NSBezierPath(roundedRect: knob.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    // Flipped like the document view, so `at` 0 is the top.
    override var isFlipped: Bool { true }
}
