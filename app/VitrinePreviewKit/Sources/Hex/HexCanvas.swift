import AppKit
import CoreText
import VitrineUI

/// Which half of a row a point or a selection belongs to. roadmap: S-5
public enum HexColumn: Sendable, Equatable { case hex, ascii }

/// Where everything in a row sits (code design state 13, `.c-hr`): 10 pt padding, the offset column, 14 pt gaps,
/// 21 pt byte cells in two groups of eight with an 8 pt gap, then the ASCII column. A narrow pane (Finder's) shows
/// eight or four bytes a row instead of sixteen, so nothing is cut off and nothing scrolls sideways. roadmap: S-5
struct HexLayout: Equatable {
    var bytesPerRow: Int
    var offsetDigits: Int
    var charWidth: CGFloat
    static let rowHeight: CGFloat = 20
    static let headerHeight: CGFloat = 22
    static let topPad: CGFloat = 4
    static let bottomPad: CGFloat = 24
    static let padding: CGFloat = 10
    static let gap: CGFloat = 14
    static let cellWidth: CGFloat = 21
    static let groupGap: CGFloat = 8

    var offsetWidth: CGFloat { ceil(CGFloat(offsetDigits) * charWidth) }
    var hexX: CGFloat { Self.padding + offsetWidth + Self.gap }
    func hexCellX(_ i: Int) -> CGFloat { hexX + CGFloat(i) * Self.cellWidth + (bytesPerRow > 8 && i >= 8 ? Self.groupGap : 0) }
    var hexWidth: CGFloat { CGFloat(bytesPerRow) * Self.cellWidth + (bytesPerRow > 8 ? Self.groupGap : 0) }
    /// The ASCII column's letter spacing is half a point, as `.c-ha`.
    var asciiCell: CGFloat { charWidth + 0.5 }
    var asciiX: CGFloat { hexX + hexWidth + Self.gap }
    func asciiCellX(_ i: Int) -> CGFloat { asciiX + CGFloat(i) * asciiCell }
    var width: CGFloat { asciiX + CGFloat(bytesPerRow) * asciiCell + Self.padding }

    /// Sixteen bytes a row when they fit `available`, else eight, else four.
    static func fitting(_ available: CGFloat, offsetDigits: Int, charWidth: CGFloat) -> HexLayout {
        for n in [16, 8] {
            let l = HexLayout(bytesPerRow: n, offsetDigits: offsetDigits, charWidth: charWidth)
            if l.width <= available { return l }
        }
        return HexLayout(bytesPerRow: 4, offsetDigits: offsetDigits, charWidth: charWidth)
    }

    /// The byte cell under `x` in a row: its column and index, clamped to the row's ends.
    func hit(x: CGFloat) -> (column: HexColumn, index: Int) {
        if x >= asciiX - Self.gap / 2 {
            return (.ascii, min(bytesPerRow - 1, max(0, Int((x - asciiX) / asciiCell))))
        }
        var i = Int((x - hexX) / Self.cellWidth)
        if bytesPerRow > 8, x - hexX > 8 * Self.cellWidth { i = Int((x - hexX - Self.groupGap) / Self.cellWidth) }
        return (.hex, min(bytesPerRow - 1, max(0, i)))
    }
}

/// The scroll range for any number of rows. Up to `maxHeight` points a row is a row (1:1); a larger file maps the
/// scroll position onto rows in proportion, so even a file of many gigabytes has a scroll view of sane size and its
/// last row is reachable. roadmap: S-5
struct HexScrollMap: Equatable {
    var rows: Int64
    var viewport: CGFloat
    static let maxHeight: Double = 50_000_000

    var naturalHeight: Double { Double(rows) * Double(HexLayout.rowHeight) + Double(HexLayout.topPad + HexLayout.bottomPad) }
    var contentHeight: Double { min(naturalHeight, max(Self.maxHeight, Double(viewport))) }
    var isScaled: Bool { naturalHeight > contentHeight }
    var maxY: Double { max(0, contentHeight - Double(viewport)) }
    /// The top row (fractional) when scrolled to the very end.
    var maxTopRow: Double { max(0, (naturalHeight - Double(viewport)) / Double(HexLayout.rowHeight)) }

    func topRow(forY y: Double) -> Double { maxY > 0 ? min(1, max(0, y / maxY)) * maxTopRow : 0 }
    func y(forTopRow t: Double) -> Double { maxTopRow > 0 ? min(1, max(0, t / maxTopRow)) * maxY : 0 }
}

/// Glyphs for the hex digits and every byte's ASCII cell (non-printables as a middle dot), drawn with Core Text in
/// one call per cell. roadmap: S-5
@MainActor
struct HexGlyphs {
    let font: CTFont
    let hex: [CGGlyph]
    let ascii: [CGGlyph]
    let ascent: CGFloat
    let descent: CGFloat
    let advance: CGFloat

    init(font: NSFont) {
        let ct = font as CTFont
        self.font = ct
        func glyphs(_ chars: [UniChar]) -> [CGGlyph] {
            var out = [CGGlyph](repeating: 0, count: chars.count)
            CTFontGetGlyphsForCharacters(ct, chars, &out, chars.count)
            return out
        }
        hex = glyphs(Array("0123456789ABCDEF".utf16))
        ascii = glyphs((0..<256).map { b in HexFormat.isPrintable(UInt8(b)) ? UniChar(b) : 0x00B7 })
        ascent = CTFontGetAscent(ct)
        descent = CTFontGetDescent(ct)
        var g = hex[0]
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &g, &adv, 1)
        advance = adv.width
    }

    static var cache: [CGFloat: HexGlyphs] = [:]
    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> HexGlyphs {
        let key = size + (weight == .regular ? 0 : 1000)
        if let hit = cache[key] { return hit }
        let made = HexGlyphs(font: NSFont.monospacedSystemFont(ofSize: size, weight: weight))
        cache[key] = made
        return made
    }

    /// Draws at a baseline in a flipped view whose context has the text matrix (1, -1): positions are in text space,
    /// so y is negated there.
    func draw(_ glyphs: [CGGlyph], at origin: CGPoint, in ctx: CGContext) {
        var positions = (0..<glyphs.count).map { CGPoint(x: origin.x + CGFloat($0) * advance, y: -origin.y) }
        CTFontDrawGlyphs(font, glyphs, &positions, glyphs.count, ctx)
    }
}

/// The rows, drawn for the rows in view only; it sits over the scroll view (which only provides the scroll range)
/// and takes the clicks, drags and keys. roadmap: S-5
@MainActor
final class HexCanvas: NSView {
    weak var hex: HexView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        let pan = NSPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        addGestureRecognizer(click)
        addGestureRecognizer(pan)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Hex bytes", bundle: .previewKit, comment: "Accessibility label of the hex view's byte grid."))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let hex, let ctx = NSGraphicsContext.current?.cgContext else { return }
        hex.drawRows(in: ctx, size: bounds.size)
    }

    // MARK: Pointer

    @objc private func clicked(_ g: NSClickGestureRecognizer) {
        window?.makeFirstResponder(self)
        hex?.pointerSelect(at: g.location(in: self), extend: NSEvent.modifierFlags.contains(.shift), dragging: false)
    }

    @objc private func dragged(_ g: NSPanGestureRecognizer) {
        let now = g.location(in: self)
        switch g.state {
        case .began:
            window?.makeFirstResponder(self)
            let t = g.translation(in: self)
            let start = NSPoint(x: now.x - t.x, y: now.y - t.y)
            hex?.pointerSelect(at: start, extend: NSEvent.modifierFlags.contains(.shift), dragging: false)
            hex?.pointerSelect(at: now, extend: true, dragging: true)
        case .changed:
            hex?.pointerSelect(at: now, extend: true, dragging: true)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let hex else { return super.scrollWheel(with: event) }
        hex.scrollWheel(from: event)
    }

    // MARK: Keys (the standard key bindings)

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    /// Typing does nothing here; the find field is where words go.
    override func insertText(_ insertString: Any) {}

    override func moveLeft(_ sender: Any?) { hex?.moveCursor(by: -1, extend: false) }
    override func moveRight(_ sender: Any?) { hex?.moveCursor(by: 1, extend: false) }
    override func moveUp(_ sender: Any?) { hex?.moveCursor(rows: -1, extend: false) }
    override func moveDown(_ sender: Any?) { hex?.moveCursor(rows: 1, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { hex?.moveCursor(by: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { hex?.moveCursor(by: 1, extend: true) }
    override func moveUpAndModifySelection(_ sender: Any?) { hex?.moveCursor(rows: -1, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { hex?.moveCursor(rows: 1, extend: true) }
    override func pageUp(_ sender: Any?) { hex?.moveCursor(rows: -(hex?.visibleRowCount ?? 1), extend: false) }
    override func pageDown(_ sender: Any?) { hex?.moveCursor(rows: hex?.visibleRowCount ?? 1, extend: false) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func moveToBeginningOfDocument(_ sender: Any?) { hex?.moveCursor(to: 0, extend: false) }
    override func moveToEndOfDocument(_ sender: Any?) { hex?.moveCursor(to: .max, extend: false) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { moveToBeginningOfDocument(sender) }
    override func scrollToEndOfDocument(_ sender: Any?) { moveToEndOfDocument(sender) }
    override func selectAll(_ sender: Any?) { hex?.selectAll() }
    @objc func copy(_ sender: Any?) { hex?.copySelection() }
    override func cancelOperation(_ sender: Any?) {
        if hex?.isSearching == true { hex?.cancelSearch() } else { super.cancelOperation(sender) }
    }
}

/// The column heads above the rows: Offset, 00 … 0F, ASCII, on a hairline. roadmap: S-5
@MainActor
final class HexHeaderView: NSView {
    var layout: HexLayout? { didSet { if layout != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.token("sep").setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        guard let layout else { return }
        let font = NSFont.monospacedSystemFont(ofSize: Metric.value("fs-micro"), weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.token("t2")]
        let y = (bounds.height - font.ascender + font.descender) / 2 - 0.5
        (String(localized: "Offset", bundle: .previewKit, comment: "Hex view column header: the byte offset of each row.") as NSString).draw(at: NSPoint(x: HexLayout.padding, y: y), withAttributes: attrs)
        for i in 0..<layout.bytesPerRow {
            let label = HexFormat.hexByte(UInt8(i)) as NSString
            let w = label.size(withAttributes: attrs).width
            label.draw(at: NSPoint(x: layout.hexCellX(i) + (HexLayout.cellWidth - w) / 2, y: y), withAttributes: attrs)
        }
        ("ASCII" as NSString).draw(at: NSPoint(x: layout.asciiX, y: y), withAttributes: attrs)
    }
}
