import AppKit
import VitrineFormats
import VitrineUI

/// Format view F4, option A (formats/decisions.html, picked by the maintainer): the current cue drawn the way a viewer sees it,
/// white with a dark halo near the bottom of a neutral drawn frame (Vitrine has no video), its timing and number in
/// the frame's corner, one glass chip saying the frame is a drawing, and the whole episode as a timeline underneath:
/// every cue a tick in `series-5`, a cue that goes by faster than 20 characters a second a `caution` mark, the
/// current cue an accent playhead, times along the bottom. Clicking or dragging on the timeline moves the current
/// cue. The cue list itself stays in the card's rows. roadmap: S-23
@MainActor
final class SubtitleStageView: NSView {
    let summary: SubtitleSummary
    /// Positions in `summary.cues` of the cues read too fast (characters a second over the threshold).
    let fastCues: [Int]
    /// The cue on the frame: a position in `summary.cues`, nil when the file has none.
    private(set) var currentCue: Int? { didSet { if currentCue != oldValue { needsDisplay = true; onCueChange?(currentCue) } } }
    /// Called when a click on the timeline moves the current cue (the card can follow it in its rows).
    var onCueChange: ((Int?) -> Void)?

    private let chip: ChipView
    private var frameRect: NSRect = .zero
    private(set) var timelineRect: NSRect = .zero

    init(summary: SubtitleSummary) {
        self.summary = summary
        fastCues = Self.fastCues(summary)
        chip = ChipView(text: String(localized: "Drawn as it will look on screen", bundle: .previewKit,
                                     comment: "The glass chip on the subtitle view's stage: the frame is a drawing, the cue is drawn as a viewer sees it."),
                        symbol: "eye", fill: "glass", textColor: "t2", border: "hair")
        chip.translatesAutoresizingMaskIntoConstraints = true
        chip.frame = NSRect(origin: .zero, size: chip.fittingSize)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 340))
        currentCue = summary.cues.isEmpty ? nil : 0
        addSubview(chip)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Subtitle preview and timeline", bundle: .previewKit, comment: "The subtitle view's stage (accessibility)."))
    }

    required init?(coder: NSCoder) { nil }

    /// The cues whose reading speed is over `SubtitleSummary.readableCharactersPerSecond` (none for LRC lyrics,
    /// which are sung rather than read), as positions in `cues`.
    static func fastCues(_ s: SubtitleSummary) -> [Int] {
        guard s.format != .lrc else { return [] }
        return s.cues.indices.filter { i in
            let cue = s.cues[i]
            guard cue.duration > 0 else { return false }
            return Double(cue.text.unicodeScalars.lazy.filter { $0 != "\n" }.count) / cue.duration > SubtitleSummary.readableCharactersPerSecond
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 340) }

    /// The length the timeline spans: the last moment a cue is on screen.
    var span: TimeInterval { max(summary.totalDuration, summary.cues.map(\.end).max() ?? 0, 1) }

    /// Moves the current cue to the one on screen at `time`, or the nearest one when none is.
    func selectCue(at time: TimeInterval) {
        let cues = summary.cues
        guard !cues.isEmpty else { return }
        // Cues are sorted by start (LRC keeps file order, which is time order): the last cue starting at or before.
        var lo = 0, hi = cues.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cues[mid].start <= time { lo = mid } else { hi = mid - 1 }
        }
        var best = lo
        if !(cues[lo].start <= time && time <= cues[lo].end) {
            // In a silence: whichever neighbour is closer in time.
            let before = lo, after = min(lo + 1, cues.count - 1)
            let dBefore = time < cues[before].start ? cues[before].start - time : time - cues[before].end
            let dAfter = abs(cues[after].start - time)
            best = dAfter < dBefore ? after : before
        }
        currentCue = best
    }

    // MARK: Layout (formats/decisions.html F4 A: frame 520 × 262 at the top, timeline 24 from each side, 4 from the bottom)

    override func layout() {
        super.layout()
        let chipSize = chip.fittingSize
        chip.frame = NSRect(x: bounds.width - 12 - chipSize.width, y: 12, width: chipSize.width, height: Metric.value("h-chip"))
        timelineRect = NSRect(x: 24, y: bounds.height - 4 - 40, width: max(0, bounds.width - 48), height: 40)
        // The frame keeps the design's 520:262 and takes the room between the top and the timeline.
        let room = max(60, timelineRect.minY - 18 - 22)
        var height = min(room, 300), width = height * 520 / 262
        let maxWidth = bounds.width - 48
        if width > maxWidth { width = maxWidth; height = width * 262 / 520 }
        // Stay centred and clear of the glass chip: shrink first (down to 380 pt wide), then slide left.
        let limit = chip.frame.minX - 12
        let centredWidth = 2 * (limit - bounds.midX)
        if chip.frame.maxY > 18, width > centredWidth {
            width = max(min(width, 380), centredWidth); height = width * 262 / 520
        }
        var x = (bounds.width - width) / 2
        if chip.frame.maxY > 18, x + width > limit { x = max(24, limit - width) }
        // Centred in the room above the timeline when the frame is smaller than it (the design's stage is exact).
        let top = max(18, 18 + (room - height) / 2)
        frameRect = NSRect(x: x, y: top, width: width, height: height)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawFrame()
        drawTimeline()
    }

    /// The neutral frame: a dusk sky over a darker ground, the same in light and dark (it stands in for video).
    private func drawFrame() {
        guard frameRect.width > 0 else { return }
        let path = NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 20 / 255, green: 30 / 255, blue: 50 / 255, alpha: 0.25)
        shadow.shadowBlurRadius = 15
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor(srgbRed: 0.18, green: 0.22, blue: 0.26, alpha: 1).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let sky = NSGradient(colorsAndLocations:
            (Self.rgb(0x3B4B5E), 0), (Self.rgb(0x5D6B73), 0.55), (Self.rgb(0x2C3640), 1))
        sky?.draw(in: frameRect, angle: 90) // flipped: 90° runs top to bottom
        let ground = NSRect(x: frameRect.minX, y: frameRect.maxY - frameRect.height * 0.46, width: frameRect.width, height: frameRect.height * 0.46)
        NSGradient(starting: Self.rgb(0x26313B), ending: Self.rgb(0x1C252D))?.draw(in: ground, angle: 90)
        // A faint warm light on the horizon so the frame reads as a scene, not a box.
        let glowCenter = NSPoint(x: frameRect.minX + frameRect.width * 0.64, y: ground.minY - frameRect.height * 0.06)
        NSGradient(starting: NSColor(srgbRed: 244 / 255, green: 231 / 255, blue: 176 / 255, alpha: 0.22), ending: .clear)?
            .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: frameRect.height * 0.24, options: [])

        if let index = currentCue {
            let cue = summary.cues[index]
            drawCueText(cue.text)
            var info = "\(Self.timecode(cue.start)) → \(Self.timecode(cue.end)) · #\(cue.identifier ?? String(cue.index))"
            if let who = cue.speaker ?? cue.style, !who.isEmpty { info += " · \(who)" }
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                                                             .foregroundColor: NSColor.white.withAlphaComponent(0.75)]
            (info as NSString).draw(with: NSRect(x: frameRect.minX + 10, y: frameRect.minY + 8, width: frameRect.width - 20, height: 16),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: tokenFont("fs-headline", weight: 500),
                                                             .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
            let text = String(localized: "No cues", bundle: .previewKit, comment: "The subtitle view's frame when the file has no cues.") as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: frameRect.midX - size.width / 2, y: frameRect.midY - size.height / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The cue as a player draws it: white 600, centred lines, a dark halo, its last line 24 pt above the frame's
    /// bottom at the design's size (scaled with the frame).
    private func drawCueText(_ text: String) {
        let scale = frameRect.height / 262
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let size = max(12, (19 * scale).rounded())
        paragraph.minimumLineHeight = (size * 1.3).rounded()
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        let halo = NSShadow()
        halo.shadowColor = NSColor.black.withAlphaComponent(0.85)
        halo.shadowBlurRadius = 3
        halo.shadowOffset = NSSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [.font: systemFont(size, cssWeight: 600), .foregroundColor: NSColor.white,
                                                         .paragraphStyle: paragraph, .shadow: halo]
        let string = NSAttributedString(string: text, attributes: attributes)
        let width = frameRect.width - 40 * scale
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let maxHeight = frameRect.height * 0.6
        let measured = string.boundingRect(with: NSSize(width: width, height: maxHeight), options: options)
        let h = min(ceil(measured.height), maxHeight)
        string.draw(with: NSRect(x: frameRect.minX + 20 * scale, y: frameRect.maxY - 24 * scale - h, width: width, height: h), options: options)
    }

    /// The episode timeline: a 26 pt `fill` track, cue ticks, caution marks, the accent playhead and times below.
    private func drawTimeline() {
        let r = timelineRect
        guard r.width > 0 else { return }
        let track = NSRect(x: r.minX, y: r.minY, width: r.width, height: 26)
        NSColor.token("fill").setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()

        let inner = track.insetBy(dx: 4, dy: 0)
        let span = self.span
        func x(_ t: TimeInterval) -> CGFloat { inner.minX + CGFloat(min(max(t / span, 0), 1)) * inner.width }

        // Cue ticks, merged where they touch at this width, so 20,000 cues draw as a few hundred rectangles.
        let tick = (NSColor.token("series-5").usingColorSpace(.sRGB) ?? .gray)
        tick.withAlphaComponent(tick.alphaComponent * 0.45).setFill()
        var run: (CGFloat, CGFloat)?
        let ticks = NSBezierPath()
        for cue in summary.cues {
            let a = x(cue.start), b = max(x(cue.end), a + 2)
            if let current = run, a <= current.1 + 0.75 {
                run = (current.0, max(current.1, b))
            } else {
                if let current = run { ticks.appendRoundedRect(NSRect(x: current.0, y: track.minY + 5, width: current.1 - current.0, height: 16), xRadius: 1, yRadius: 1) }
                run = (a, b)
            }
        }
        if let current = run { ticks.appendRoundedRect(NSRect(x: current.0, y: track.minY + 5, width: current.1 - current.0, height: 16), xRadius: 1, yRadius: 1) }
        ticks.fill()

        NSColor.token("caution").setFill()
        for i in fastCues {
            let mid = (x(summary.cues[i].start) + x(summary.cues[i].end)) / 2
            NSBezierPath(roundedRect: NSRect(x: mid - 1.5, y: track.minY + 2, width: 3, height: 22), xRadius: 1, yRadius: 1).fill()
        }

        if let index = currentCue {
            NSColor.token("accent").setFill()
            NSRect(x: x(summary.cues[index].start) - 1, y: track.minY, width: 2, height: 26).fill()
        }

        // Times: 0:00 at the left, the end at the right, round steps between that do not crowd the end.
        let attributes: [NSAttributedString.Key: Any] = [.font: tabularFigures(NSFont.systemFont(ofSize: 10)), .foregroundColor: NSColor.token("t2")]
        func label(_ t: TimeInterval, at px: CGFloat, align: NSTextAlignment) {
            let s = SubtitleSummary.clock(t) as NSString
            let w = s.size(withAttributes: attributes).width
            let left = align == .left ? px : align == .right ? px - w : px - w / 2
            s.draw(at: NSPoint(x: left, y: track.maxY + 1), withAttributes: attributes)
        }
        label(0, at: r.minX, align: .left)
        label(span, at: r.maxX, align: .right)
        let step = Self.tickStep(span: span, width: r.width)
        var t = step
        while t < span {
            let px = r.minX + CGFloat(t / span) * r.width
            if px > r.minX + 40, px < r.maxX - 60 { label(t, at: px, align: .center) }
            t += step
        }
    }

    /// A round label step giving roughly one time every 200 pt.
    static func tickStep(span: TimeInterval, width: CGFloat) -> TimeInterval {
        let wanted = span / max(1, Double(width / 200))
        let steps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        return steps.first { $0 >= wanted } ?? 7200
    }

    // MARK: Clicking the timeline moves the current cue

    private var tracking = false

    override func mouseDown(with event: NSEvent) {
        tracking = timelineRect.insetBy(dx: 0, dy: -6).contains(convert(event.locationInWindow, from: nil))
        if tracking { pick(event) } else { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if tracking { pick(event) } else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        tracking = false
        super.mouseUp(with: event)
    }

    private func pick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inner = timelineRect.insetBy(dx: 4, dy: 0)
        guard inner.width > 0 else { return }
        selectCue(at: Double(min(max((point.x - inner.minX) / inner.width, 0), 1)) * span)
    }

    override func resetCursorRects() { addCursorRect(timelineRect, cursor: .pointingHand) }

    // MARK: Helpers

    /// `m:ss.mmm`, or `h:mm:ss.mmm` from an hour (the frame's corner).
    static func timecode(_ seconds: TimeInterval) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return h > 0 ? String(format: "%d:%02d:%02d.%03d", h, m, s, f) : String(format: "%d:%02d.%03d", m, s, f)
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
