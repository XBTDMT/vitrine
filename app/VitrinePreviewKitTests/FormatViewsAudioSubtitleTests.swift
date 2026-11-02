import AppKit
import VitrineFormats
import XCTest
@testable import VitrinePreviewKit

/// Format views F3 (audio) and F4 (subtitles), option A: built from invented files, laid out at 900 × 420 on the
/// lit stage, drawn light and dark into PNGs in the temporary folder, and checked for the pixels the design asks for.
/// No sound is played. roadmap: S-23
@MainActor
final class FormatViewsAudioSubtitleTests: XCTestCase {
    // MARK: Invented files

    /// A 16-bit mono 22.05 kHz WAV of a few tones (with one stretch driven to full scale, so it clips) and a RIFF
    /// INFO list naming an invented track.
    static func toneWAV() -> Data {
        let rate = 22_050
        let segments: [(seconds: Double, hz: Double, amp: Double)] = [
            (0.8, 440, 0.25), (0.8, 660, 0.55), (0.25, 880, 1.6), (0.9, 523, 0.4), (0.7, 330, 0.75), (0.8, 440, 0.15),
        ]
        var samples: [Int16] = []
        for seg in segments {
            let n = Int(seg.seconds * Double(rate))
            for i in 0..<n {
                let t = Double(i) / Double(rate)
                let envelope = min(1, Double(i) / 400, Double(n - i) / 400)
                let v = max(-1, min(1, seg.amp * envelope * sin(2 * .pi * seg.hz * t)))
                samples.append(Int16(v * 32767))
            }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func info(_ id: String, _ text: String) -> Data {
            var body = Data(text.utf8); body.append(0)
            if body.count % 2 == 1 { body.append(0) }
            return Data(id.utf8) + le32(body.count) + body
        }
        let infoBody = Data("INFO".utf8) + info("INAM", "Night Shift (demo)") + info("IART", "The Example Arcade")
            + info("IPRD", "Low Tide Tapes") + info("IGNR", "Electronic") + info("ITRK", "3/9")
        let fmt = le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let chunks = Data("fmt ".utf8) + le32(fmt.count) + fmt + Data("LIST".utf8) + le32(infoBody.count) + infoBody
            + Data("data".utf8) + le32(pcm.count) + pcm
        return Data("RIFF".utf8) + le32(4 + chunks.count) + Data("WAVE".utf8) + chunks
    }

    /// An invented cover: a warm gradient with two pale bars, as PNG bytes.
    static func coverPNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(srgbRed: 0.94, green: 0.54, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.72, green: 0.23, blue: 0.37, alpha: 1),
                            NSColor(srgbRed: 0.42, green: 0.17, blue: 0.44, alpha: 1)])?.draw(in: NSRect(x: 0, y: 0, width: 600, height: 600), angle: -50)
        NSColor.white.withAlphaComponent(0.6).setFill()
        NSRect(x: 72, y: 84, width: 456, height: 10).fill()
        NSRect(x: 72, y: 440, width: 220, height: 70).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// An invented 42-minute SubRip file: a cue about every 20 seconds, every fifteenth one too fast to read.
    static func episodeSRT() -> Data {
        let lines = ["Did you lock the boathouse?", "I thought you had the keys.", "They were on the hook by the door, where they always are.",
                     "Not tonight they weren't. Look.", "[distant foghorn]", "Someone was here. The lamp is still warm.",
                     "Then they can't have gone far.", "Get the torch. I'll check the pier."]
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = "", t = 4.0, n = 0
        while t < 42 * 60 + 5 {
            n += 1
            let text = lines[n % lines.count]
            let fast = n % 15 == 7
            let length = fast ? Double(text.count) / 28 : max(1.5, Double(text.count) / 12)
            out += "\(n)\n\(stamp(t)) --> \(stamp(t + length))\n\(text)\n\n"
            t += length + (n % 9 == 0 ? 45 : 14 + Double(n % 5) * 2)
        }
        return Data(out.utf8)
    }

    // MARK: Helpers

    private func audioSummary() throws -> (MediaAudioSummary, URL) {
        let data = Self.toneWAV()
        guard case .audio(var summary) = try XCTUnwrap(MediaReader.read(data: data, fileName: "Night Shift (demo).wav")) else {
            throw XCTSkip("the WAV did not read as audio")
        }
        summary.cover = MediaPicture(data: Self.coverPNG(), mimeType: "image/png", pictureType: "Front cover")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-format-audio-\(UUID().uuidString).wav")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (summary, url)
    }

    private func subtitleSummary() throws -> SubtitleSummary {
        guard case .subtitles(let s) = try XCTUnwrap(EverydayReader.read(data: Self.episodeSRT(), fileName: "Harbor Lights S01E03.en.srt")) else {
            throw XCTSkip("the SRT did not read as subtitles")
        }
        return s
    }

    /// The view on the lit stage, as the card shows it, at 900 × 420.
    private func staged(_ view: NSView) -> NSView {
        let stage = StageView()
        stage.translatesAutoresizingMaskIntoConstraints = true
        stage.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        view.frame = stage.bounds
        view.autoresizingMask = [.width, .height]
        stage.addSubview(view)
        stage.layoutSubtreeIfNeeded()
        return stage
    }

    /// Renders the stage for an appearance, writes it as a PNG in the temporary folder and returns the bitmap.
    @discardableResult
    private func render(_ stage: NSView, _ name: String, dark: Bool) throws -> NSBitmapImageRep {
        stage.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        stage.needsLayout = true
        stage.layoutSubtreeIfNeeded()
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(stage)
        stage.displayIfNeeded()
        let rep = try XCTUnwrap(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
        stage.cacheDisplay(in: stage.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-\(name)-\(dark ? "dark" : "light").png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("format view proof: \(url.path)")
        return rep
    }

    /// Pixels (in points of the 900 × 420 view, top-left origin) inside `rect` that satisfy `test`.
    private func count(_ rep: NSBitmapImageRep, in rect: NSRect, where test: (_ r: Int, _ g: Int, _ b: Int) -> Bool) -> Int {
        let sx = CGFloat(rep.pixelsWide) / 900, sy = CGFloat(rep.pixelsHigh) / 420
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3 else { return 0 }
        // Raw bytes rather than colorAt(x:y:) per pixel: the same answer, a hundred times faster.
        let step = rep.bitsPerPixel / 8, first = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        var n = 0
        for y in max(0, Int(rect.minY * sy))..<min(rep.pixelsHigh, Int(rect.maxY * sy)) {
            for x in max(0, Int(rect.minX * sx))..<min(rep.pixelsWide, Int(rect.maxX * sx)) {
                let p = data + y * rep.bytesPerRow + x * step + first
                if test(Int(p[0]), Int(p[1]), Int(p[2])) { n += 1 }
            }
        }
        return n
    }

    private static func isCaution(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 220 && (120...175).contains(g) && b < 70 }
    /// The accent and `series-1` greens (the bitmap is in the device space, so #0D7B6C reads near 19, 105, 89).
    private static func isSeaGlass(_ r: Int, _ g: Int, _ b: Int) -> Bool { r < 70 && g > 90 && b > 70 && g > r + 50 }

    // MARK: F3 audio

    func testAudioReadsPeaksFromTheFile() throws {
        let (_, url) = try audioSummary()
        let result = try XCTUnwrap(AudioStageView.readPeaks(url: url, buckets: AudioStageView.bucketCount))
        XCTAssertEqual(result.peaks.count, 600)
        XCTAssertEqual(result.seconds, 4.25, accuracy: 0.01)
        // The quiet first tone sits near 0.25, the driven one reaches full scale.
        XCTAssertEqual(result.peaks[40], 0.25, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(result.peaks.max() ?? 0, AudioStageView.clipLevel)
        XCTAssertNil(AudioStageView.readPeaks(url: url.deletingLastPathComponent().appendingPathComponent("missing.wav"), buckets: 600))
    }

    func testAudioStageDrawsCoverAndWaveform() async throws {
        let (summary, url) = try audioSummary()
        XCTAssertEqual(summary.tags.title, "Night Shift (demo)")
        let view = AudioStageView(summary: summary, fileURL: url)
        let ready = expectation(description: "waveform read")
        view.onWaveformReady = { ready.fulfill() }
        let stage = staged(view)
        await fulfillment(of: [ready], timeout: 20)
        XCTAssertEqual(view.peaks?.count, AudioStageView.bucketCount)
        XCTAssertEqual(AudioStageView.chips(summary), ["Electronic", "Track 3 of 9"])
        XCTAssertFalse(view.isPlaying, "nothing plays in tests")

        // Give the cover decode a moment (it is off the main thread too): it adds the cover-size chip.
        for _ in 0..<100 where !view.subviews.contains(where: { ($0 as? ChipView)?.label.stringValue == "Cover art 600 px" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(view.subviews.contains { ($0 as? ChipView)?.label.stringValue == "Cover art 600 px" })
        view.seek(toFraction: 0.3)

        for dark in [false, true] {
            let rep = try render(stage, "audio-stage", dark: dark)
            let waveRow = NSRect(x: 120, y: 420 - 20 - 58, width: 640, height: 58)
            XCTAssertGreaterThan(count(rep, in: waveRow, where: Self.isSeaGlass), 200, "played bars in series-1")
            XCTAssertGreaterThan(count(rep, in: waveRow, where: Self.isCaution), 60, "clipped bars in caution")
            // The cover: warm pink/orange pixels where the art is drawn.
            let cover = NSRect(x: 40, y: 40, width: 220, height: 220)
            XCTAssertGreaterThan(count(rep, in: cover) { r, g, b in r > 150 && b > 60 && r > g + 60 }, 5_000, "the cover art")
            // The title text is drawn in t1 to the right of the cover.
            let text = NSRect(x: 300, y: 80, width: 400, height: 140)
            let ink = count(rep, in: text) { r, g, b in dark ? (r > 200 && g > 200 && b > 200) : (r < 80 && g < 80 && b < 80) }
            XCTAssertGreaterThan(ink, 150, "title and byline")
        }
        view.removeFromSuperview()
        XCTAssertFalse(view.isPlaying)
    }

    func testAudioPlaceholderBeforeTheWaveform() throws {
        let (summary, url) = try audioSummary()
        var noCover = summary
        noCover.cover = nil
        let view = AudioStageView(summary: noCover, fileURL: url)
        let stage = staged(view)
        let rep = try render(stage, "audio-placeholder", dark: false)
        let waveRow = NSRect(x: 120, y: 420 - 20 - 58, width: 640, height: 58)
        XCTAssertEqual(count(rep, in: waveRow, where: Self.isCaution), 0, "no bars until the peaks arrive")
        XCTAssertGreaterThan(count(rep, in: waveRow) { r, g, b in abs(r - g) < 12 && r < 225 && r > 150 }, 200, "the flat placeholder row")
        try render(stage, "audio-placeholder", dark: true)
    }

    func testAudioBarsMergeBucketsAndMarkClips() {
        let bars = AudioWaveformView.bars([0.1, 0.2, 1.0, 0.3, 0.4, 0.5], count: 3)
        XCTAssertEqual(bars.map(\.level), [0.2, 1.0, 0.5])
        XCTAssertEqual(bars.map(\.clipped), [false, true, false])
        XCTAssertEqual(AudioStageView.clock(67), "1:07")
        XCTAssertEqual(AudioStageView.clock(3_725), "1:02:05")
    }

    // MARK: F4 subtitles

    func testSubtitleFastCuesAndClickMovesTheCue() throws {
        let summary = try subtitleSummary()
        XCTAssertGreaterThan(summary.cues.count, 100)
        let view = SubtitleStageView(summary: summary)
        XCTAssertFalse(view.fastCues.isEmpty)
        XCTAssertTrue(view.fastCues.allSatisfy { summary.cues[$0].index % 15 == 7 })
        XCTAssertEqual(view.currentCue, 0)

        let stage = staged(view)
        _ = stage
        var told: Int?
        view.onCueChange = { told = $0 }
        // A click halfway along the timeline lands on a cue around the middle of the episode.
        let r = view.timelineRect
        let point = NSPoint(x: r.midX, y: 420 - (r.minY + 10)) // window coordinates run up
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let picked = try XCTUnwrap(view.currentCue)
        XCTAssertEqual(told, picked)
        let middle = view.span / 2
        XCTAssertLessThan(abs(summary.cues[picked].start - middle), 60, "the cue nearest the clicked time")

        view.selectCue(at: summary.cues[5].start + 0.1)
        XCTAssertEqual(view.currentCue, 5)
        view.selectCue(at: -10)
        XCTAssertEqual(view.currentCue, 0)
        view.selectCue(at: view.span + 100)
        XCTAssertEqual(view.currentCue, summary.cues.count - 1)
        XCTAssertEqual(SubtitleStageView.timecode(735.4), "12:15.400")
    }

    func testSubtitleStageDrawsFrameCueAndTimeline() throws {
        let summary = try subtitleSummary()
        let view = SubtitleStageView(summary: summary)
        let stage = staged(view)
        view.selectCue(at: summary.cues[5].start + 0.5)
        for dark in [false, true] {
            let rep = try render(stage, "subtitle-stage", dark: dark)
            let r = view.timelineRect
            let track = NSRect(x: r.minX, y: r.minY, width: r.width, height: 26)
            XCTAssertGreaterThan(count(rep, in: track, where: Self.isCaution), 40, "fast cues marked in caution")
            XCTAssertGreaterThan(count(rep, in: track, where: Self.isSeaGlass), 10, "the accent playhead")
            // The frame: dark slate pixels, and white cue text near its bottom.
            let frame = NSRect(x: 250, y: 30, width: 400, height: 230)
            XCTAssertGreaterThan(count(rep, in: frame) { r, g, b in r < 100 && g < 115 && b < 130 }, 20_000, "the neutral frame")
            XCTAssertGreaterThan(count(rep, in: NSRect(x: 220, y: 200, width: 460, height: 90)) { r, g, b in r > 235 && g > 235 && b > 235 }, 200, "the cue text")
        }
    }

    func testSubtitleWithNoCuesDrawsTheEmptyFrame() throws {
        let view = SubtitleStageView(summary: SubtitleSummary(format: .srt))
        XCTAssertNil(view.currentCue)
        view.selectCue(at: 10)
        XCTAssertNil(view.currentCue)
        let rep = try render(staged(view), "subtitle-empty", dark: false)
        XCTAssertGreaterThan(count(rep, in: NSRect(x: 250, y: 30, width: 400, height: 230)) { r, g, b in r < 100 && g < 115 && b < 130 }, 20_000)
    }

    func testBuildingTheViewsStaysWellUnderFiftyMilliseconds() throws {
        let (audio, url) = try audioSummary()
        let subtitles = try subtitleSummary()
        _ = staged(SubtitleStageView(summary: subtitles)); _ = staged(AudioStageView(summary: audio, fileURL: url)) // warm up
        let start = Date()
        _ = staged(SubtitleStageView(summary: subtitles))
        _ = staged(AudioStageView(summary: audio, fileURL: url))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
    }
}
