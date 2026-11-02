import Accelerate
import AppKit
import AVFoundation
import ImageIO
import VitrineFormats
import VitrineUI

/// Format view F3, option A (formats/decisions.html, picked by the maintainer): the audio file's cover art, title, artist and
/// a few chips on the lit stage, with a playable waveform along the bottom (play button, elapsed time, the waveform as
/// the seek bar, time left). Bars left of the playhead are drawn in `series-1`, the rest in `fill2`, and a bar whose
/// peak reaches 0 dBFS in `caution`. The waveform is read from the local file with AVFoundation on a background task
/// (about 600 peak buckets); a calm flat placeholder stands in until it arrives. Playback is the local file through
/// `AVAudioPlayer` and stops when the view leaves its window. Nothing is fetched and nothing is written.
/// roadmap: S-23
@MainActor
final class AudioStageView: NSView {
    /// How many peak buckets the file is read into; the drawn bars are these merged to fit the width.
    static let bucketCount = 600
    /// A sample at or above this magnitude counts as reaching 0 dBFS (a clipped peak).
    static let clipLevel: Float = 0.999

    let summary: MediaAudioSummary
    let fileURL: URL

    /// The peak buckets (0…1, one per `bucketCount` slice of the file); nil until the background read finishes,
    /// empty when the file could not be read.
    private(set) var peaks: [Float]?
    /// Called on the main actor once `peaks` is set (tests wait on it; the card can too).
    var onWaveformReady: (() -> Void)?

    private let waveform = AudioWaveformView()
    private let playButton = AudioPlayButton()
    private let elapsedLabel: NSTextField
    private let remainingLabel: NSTextField
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private var chipViews: [ChipView] = []
    private var coverImage: CGImage?

    private var player: AVAudioPlayer?
    private var tick: Timer?
    private var loadTask: Task<Void, Never>?
    private var coverTask: Task<Void, Never>?
    /// The file's length in seconds: the tags' figure, or AVFoundation's once the waveform read has it.
    private(set) var duration: Double
    /// Where the playhead sits, in seconds.
    private(set) var position: Double = 0 { didSet { positionChanged() } }

    var isPlaying: Bool { player?.isPlaying ?? false }

    init(summary: MediaAudioSummary, fileURL: URL) {
        self.summary = summary
        self.fileURL = fileURL
        duration = summary.stream.durationSeconds ?? 0
        let numbers = tabularFigures(tokenFont("fs-control"))
        elapsedLabel = cardLabel("0:00", font: numbers, color: "t2")
        remainingLabel = cardLabel("", font: numbers, color: "t2")
        titleLabel = cardLabel(summary.tags.title ?? summary.headline, font: tokenFont("fs-title1", weight: 650), color: "t1")
        let byline = [summary.tags.artist, summary.tags.album].compactMap { $0 }.filter { !$0.isEmpty }
        subtitleLabel = cardLabel(byline.joined(separator: " · "), font: tokenFont("fs-headline", weight: 400), color: "t2")
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 300))

        for label in [elapsedLabel, remainingLabel] {
            label.translatesAutoresizingMaskIntoConstraints = true
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        elapsedLabel.alignment = .right
        for label in [titleLabel, subtitleLabel] { label.translatesAutoresizingMaskIntoConstraints = true }
        subtitleLabel.isHidden = byline.isEmpty

        // Chips are placed by frame; each starts at its own fitting size so its inner constraints never see zero.
        chipViews = Self.chips(summary).map { text in
            let chip = ChipView(text: text, symbol: nil, fill: "fill", textColor: "t2")
            chip.translatesAutoresizingMaskIntoConstraints = true
            chip.frame = NSRect(origin: .zero, size: chip.fittingSize)
            return chip
        }

        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.setAccessibilityLabel(String(localized: "Play", bundle: .previewKit, comment: "The audio view's play button (accessibility)."))

        waveform.onSeek = { [weak self] fraction in self?.seek(toFraction: fraction) }
        waveform.setAccessibilityElement(true)
        waveform.setAccessibilityRole(.slider)
        waveform.setAccessibilityLabel(String(localized: "Waveform", bundle: .previewKit, comment: "The audio view's waveform, which is also the seek bar (accessibility)."))

        for v in [waveform, playButton, elapsedLabel, remainingLabel, titleLabel, subtitleLabel] + chipViews as [NSView] { addSubview(v) }
        positionChanged()
        startReading()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        // Playback and the timer stop when the view leaves its window; the reads stop here.
        loadTask?.cancel()
        coverTask?.cancel()
    }

    /// The chips beside the title known from the tags: genre, track of total (`.chip.noicon`).
    static func chips(_ s: MediaAudioSummary) -> [String] {
        var out: [String] = []
        if let g = s.tags.genre, !g.isEmpty { out.append(g) }
        if let n = s.tags.track {
            out.append(s.tags.trackTotal.map { String(localized: "Track \(n) of \($0)", bundle: .previewKit, comment: "A chip on the audio view: track number of a total.") }
                       ?? String(localized: "Track \(n)", bundle: .previewKit, comment: "A chip on the audio view: track number."))
        }
        // The third chip is the cover's size once it is decoded (see `coverArrived`); without a cover, the year.
        if s.cover == nil, let y = s.tags.year, !y.isEmpty { out.append(y) }
        return Array(out.prefix(3))
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 300) }

    // MARK: Layout (formats/decisions.html F3 A: cover 176 at 40, 28; the waveform row 40 from each side, 20 from the bottom)

    private var coverRect: NSRect = .zero

    override func layout() {
        super.layout()
        let side: CGFloat = 40, rowHeight: CGFloat = 58
        let rowY = bounds.height - 20 - rowHeight
        let button: CGFloat = 30
        playButton.frame = NSRect(x: side, y: rowY + (rowHeight - button) / 2, width: button, height: button)
        let timeWidth: CGFloat = 44
        elapsedLabel.frame = NSRect(x: playButton.frame.maxX + 4, y: rowY + (rowHeight - 16) / 2, width: timeWidth - 4, height: 16)
        remainingLabel.frame = NSRect(x: bounds.width - side - timeWidth, y: elapsedLabel.frame.minY, width: timeWidth, height: 16)
        let waveX = elapsedLabel.frame.maxX + 12
        waveform.frame = NSRect(x: waveX, y: rowY, width: max(0, remainingLabel.frame.minX - 12 - waveX), height: rowHeight)

        // The cover keeps 176 pt at the design's 300 pt stage and grows or shrinks with the room above the row.
        let room = rowY
        let size = min(max(room - 46, 96), 240)
        coverRect = NSRect(x: side, y: max(12, (room - size) / 2 + 2), width: size, height: size)

        let textX = coverRect.maxX + 26, textWidth = max(0, bounds.width - side - textX)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let subHeight = subtitleLabel.isHidden ? 0 : ceil(subtitleLabel.intrinsicContentSize.height)
        let chipsHeight: CGFloat = chipViews.isEmpty ? 0 : Metric.value("h-chip")
        let block = titleHeight + (subHeight > 0 ? 3 + subHeight : 0) + (chipsHeight > 0 ? 12 + chipsHeight : 0)
        var y = coverRect.midY - block / 2
        titleLabel.frame = NSRect(x: textX - 2, y: y, width: textWidth, height: titleHeight)
        y += titleHeight
        if subHeight > 0 {
            subtitleLabel.frame = NSRect(x: textX - 2, y: y + 3, width: textWidth, height: subHeight)
            y += 3 + subHeight
        }
        var chipX = textX
        for chip in chipViews {
            let width = chip.fittingSize.width
            // A chip that would run past the edge is left out rather than squeezed.
            chip.isHidden = chipX + width > textX + textWidth
            chip.frame = NSRect(x: chipX, y: y + 12, width: width, height: chipsHeight)
            chipX += width + 6
        }
    }

    // MARK: Drawing: the cover (its shadow is drawn here, outside the image's rounded clip)

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        waveform.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard coverRect.intersects(dirtyRect.insetBy(dx: -40, dy: -40)) else { return }
        let path = NSBezierPath(roundedRect: coverRect, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 13
        shadow.shadowOffset = NSSize(width: 0, height: -10) // flipped view: a negative height falls downwards
        shadow.set()
        NSColor.token("card").setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let coverImage, let context = NSGraphicsContext.current?.cgContext {
            // Aspect-fill the square, drawn upright in the flipped view.
            let w = CGFloat(coverImage.width), h = CGFloat(coverImage.height)
            let scale = max(coverRect.width / w, coverRect.height / h)
            let drawn = NSRect(x: coverRect.midX - w * scale / 2, y: coverRect.midY - h * scale / 2, width: w * scale, height: h * scale)
            context.saveGState()
            context.translateBy(x: 0, y: drawn.maxY + drawn.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(coverImage, in: drawn)
            context.restoreGState()
        } else {
            // No cover in the file (or still decoding): a quiet tile with a note.
            NSColor.token("fill2").setFill()
            path.fill()
            let config = NSImage.SymbolConfiguration(pointSize: coverRect.width * 0.32, weight: .regular)
                .applying(.init(paletteColors: [NSColor.token("t3")]))
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                note.draw(in: NSRect(x: coverRect.midX - note.size.width / 2, y: coverRect.midY - note.size.height / 2,
                                     width: note.size.width, height: note.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        // The cover's hairline edge (`inset 0 0 0 .5px rgba(0,0,0,.12)`).
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(roundedRect: coverRect.insetBy(dx: 0.25, dy: 0.25), xRadius: 8, yRadius: 8)
        edge.lineWidth = 0.5
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Reading the waveform and the cover, off the main thread

    private func startReading() {
        let url = fileURL, buckets = Self.bucketCount
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.readPeaks(url: url, buckets: buckets)
            await self?.waveformArrived(result)
        }
        if let data = summary.cover?.data {
            let pixels = 480
            coverTask = Task.detached(priority: .userInitiated) { [weak self] in
                let image = Self.decodeCover(data, maxPixels: pixels)
                await self?.coverArrived(image?.image, pixels: image?.pixels)
            }
        }
    }

    private func waveformArrived(_ result: (peaks: [Float], seconds: Double)?) {
        peaks = result?.peaks ?? []
        if duration <= 0, let seconds = result?.seconds, seconds > 0 { duration = seconds }
        waveform.peaks = peaks
        positionChanged()
        onWaveformReady?()
    }

    private func coverArrived(_ image: CGImage?, pixels: Int?) {
        coverImage = image
        if let pixels, pixels > 0, chipViews.count < 3 {
            let chip = ChipView(text: String(localized: "Cover art \(pixels) px", bundle: .previewKit,
                                             comment: "A chip on the audio view: the embedded cover's size in pixels (its long side)."),
                                symbol: nil, fill: "fill", textColor: "t2")
            chip.translatesAutoresizingMaskIntoConstraints = true
            chip.frame = NSRect(origin: .zero, size: chip.fittingSize)
            chipViews.append(chip)
            addSubview(chip)
            needsLayout = true
        }
        needsDisplay = true
    }

    /// A downsampled thumbnail of the cover bytes (ImageIO), at most `maxPixels` on the long side, and the long
    /// side of the picture as stored.
    nonisolated static func decodeCover(_ data: Data, maxPixels: Int) -> (image: CGImage, pixels: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let stored = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, stored)
    }

    /// The file's peak magnitude in `buckets` equal slices (0…1, the loudest channel), and its length in seconds;
    /// nil when AVFoundation cannot read it. Reads in chunks, checks for cancellation between them.
    nonisolated static func readPeaks(url: URL, buckets: Int) -> (peaks: [Float], seconds: Double)? {
        guard buckets > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return ([], 0) }
        let framesPerBucket = max(1, Int((Double(total) / Double(buckets)).rounded(.up)))
        var peaks = [Float](repeating: 0, count: buckets)
        var frame: Int64 = 0
        while frame < total {
            if Task.isCancelled { return nil }
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            var offset = 0
            while offset < n {
                let bucket = Int((frame + Int64(offset)) / Int64(framesPerBucket))
                guard bucket < buckets else { break }
                let bucketEnd = Int64(bucket + 1) * Int64(framesPerBucket) - frame
                let count = min(n - offset, Int(bucketEnd) - offset)
                var peak = peaks[bucket]
                for c in 0..<Int(format.channelCount) {
                    var m: Float = 0
                    vDSP_maxmgv(channels[c] + offset, 1, &m, vDSP_Length(count))
                    peak = max(peak, m)
                }
                peaks[bucket] = min(peak, 1)
                offset += count
            }
            frame += Int64(n)
        }
        return (peaks, Double(total) / format.sampleRate)
    }

    // MARK: Playback (local file only; stops when the view leaves its window)

    @objc func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    private func play() {
        if player == nil {
            guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { NSSound.beep(); return }
            p.prepareToPlay()
            player = p
            if duration <= 0 { duration = p.duration }
        }
        guard let player else { return }
        if position >= duration - 0.05 { position = 0 }
        player.currentTime = position
        player.play()
        playButton.playing = true
        playButton.setAccessibilityLabel(String(localized: "Pause", bundle: .previewKit, comment: "The audio view's pause button (accessibility)."))
        startTicking()
    }

    func pause() {
        player?.pause()
        stopTicking()
        playButton.playing = false
        playButton.setAccessibilityLabel(String(localized: "Play", bundle: .previewKit, comment: "The audio view's play button (accessibility)."))
    }

    func stop() {
        player?.stop()
        pause()
    }

    private func startTicking() {
        stopTicking()
        // The timer holds the view while it plays; leaving the window or pausing invalidates it.
        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(ticked), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
    }

    @objc private func ticked() {
        guard let player else { return }
        if player.isPlaying {
            position = player.currentTime
        } else {
            // It reached the end: back to the start, paused.
            position = 0
            pause()
        }
    }

    /// Moves the playhead to a share of the file (0…1): a click or drag on the waveform.
    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        position = min(max(fraction, 0), 1) * duration
        player?.currentTime = position
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private func positionChanged() {
        let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
        waveform.progress = progress
        waveform.setAccessibilityValue(Self.clock(position))
        elapsedLabel.stringValue = Self.clock(position)
        remainingLabel.stringValue = duration > 0 ? "−" + Self.clock(max(0, duration - position)) : ""
    }

    /// `m:ss`, or `h:mm:ss` from an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The waveform as a seek bar (SoundCloud-style, formats F3 A): rounded 3.5 pt bars on a ~4.9 pt pitch, centred on
/// the row, played bars in `series-1`, the rest in `fill2`, clipped bars full height in `caution`, and a 1.5 pt
/// playhead in `t1`. Until the peaks arrive it draws a flat row of short bars. roadmap: S-23
@MainActor
final class AudioWaveformView: NSView {
    var peaks: [Float]? { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    var onSeek: ((Double) -> Void)?

    static let barWidth: CGFloat = 3.5
    static let pitch: CGFloat = 4.875

    override var isFlipped: Bool { true }

    /// The bars to draw for a width: each the loudest of its buckets, and whether any of them clipped.
    static func bars(_ peaks: [Float], count: Int) -> [(level: Float, clipped: Bool)] {
        guard count > 0, !peaks.isEmpty else { return [] }
        return (0..<count).map { i in
            let a = i * peaks.count / count, b = max(a + 1, (i + 1) * peaks.count / count)
            let slice = peaks[a..<min(b, peaks.count)]
            let level = slice.max() ?? 0
            return (level, level >= AudioStageView.clipLevel)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = max(1, Int((bounds.width + Self.pitch - Self.barWidth) / Self.pitch))
        let mid = bounds.midY, maxHeight = bounds.height - 4
        let playX = bounds.width * progress
        let played = NSColor.token("series-1"), rest = NSColor.token("fill2"), clip = NSColor.token("caution")
        if let peaks, !peaks.isEmpty {
            for (i, bar) in Self.bars(peaks, count: count).enumerated() {
                let x = CGFloat(i) * Self.pitch + 0.6
                let h = bar.clipped ? maxHeight : max(2, CGFloat(bar.level) * maxHeight)
                (bar.clipped ? clip : (x + Self.barWidth / 2 <= playX ? played : rest)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: mid - h / 2, width: Self.barWidth, height: h), xRadius: 1, yRadius: 1).fill()
            }
        } else {
            // The calm placeholder: a flat row of short bars, the quiet colour.
            rest.setFill()
            for i in 0..<count {
                let x = CGFloat(i) * Self.pitch + 0.6
                NSBezierPath(roundedRect: NSRect(x: x, y: mid - 1.5, width: Self.barWidth, height: 3), xRadius: 1, yRadius: 1).fill()
            }
        }
        // The playhead, once there is a waveform to stand on.
        guard let peaks, !peaks.isEmpty else { return }
        NSColor.token("t1").setFill()
        NSRect(x: min(max(0, playX - 0.75), bounds.width - 1.5), y: 0, width: 1.5, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        guard bounds.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        onSeek?(Double(x / bounds.width))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The 30 pt round play button (`.playb`): the accent colour with a white play or pause glyph.
@MainActor
final class AudioPlayButton: NSButton {
    var playing = false { didSet { updateGlyph() } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        updateGlyph()
    }

    required init?(coder: NSCoder) { nil }

    private func updateGlyph() {
        image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        contentTintColor = NSColor.token("on-accent")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = bounds.height / 2
            layer?.backgroundColor = NSColor.token("accent").cgColor
        }
    }
}
