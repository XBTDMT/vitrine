import AppKit
import ImageIO
import QuartzCore
import VitrineDocument
import VitrineSupport
import VitrineUI

/// Pictures on the facts card (cards.html §3b "Photo in the Vitrine window", §4 "Animated image"): the picture on
/// the stage (a photo fills it, as drawn; any other picture fits inside the stage's padding, on the checkerboard when
/// it has transparency; an animation plays at its own timing), then the label and the Exposure, Image, Animation and
/// Location sections. The viewer switch's second view, Info, lists every property the file stores.
///
/// macOS keeps Quick Look for its own image types (measured 2026-10-30 with `qlmanage -p -o`: JPEG, HEIC, PNG, GIF,
/// TIFF, AVIF and WebP all get macOS's preview), so this card is reached through the Vitrine window ("Open With →
/// Vitrine", the CLI, the menu bar) and, in Quick Look, only for `.apng`, which macOS has no type for. roadmap: S-23
@MainActor
public final class ImageRenderer: NSObject, Renderer {
    public static func canRender(_ kind: FileKind) -> Bool { kind == .image }
    public override required init() { super.init() }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let info = try await Task.detached(priority: .userInitiated) { try ImageInfo.read(url: url) }.value
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let card = ImageCard.make(info, fileName: url.deletingPathExtension().lastPathComponent, fileSize: fileSize)
        let text = ImageCard.infoText(info, card: card)
        var document = PreviewDocument(kind: .image, facts: ImageCard.facts(info, card: card, fileSize: fileSize),
                                       badges: ImageCard.badges(info), views: [.text(text), .text(text)])
        document.viewTitles = [
            info.kind == .photo ? "Photo"
                                : "Image",
            "Info",
        ]

        let picture = ImageStageView(fill: info.kind == .photo, hasAlpha: info.hasAlpha)
        let view = InfoCardView(card: card, stageContent: picture, stageHeight: .share(0.53, minimum: 150), narrowStageHeight: 118,
                                facts: document.facts)
        view.onAction = { id in
            switch id {
            case "copyCoordinates":
                guard let location = info.location else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ImageCard.coordinates(location), forType: .string)
            case "openInPhotos":
                guard let photos = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else { return }
                NSWorkspace.shared.open([url], withApplicationAt: photos, configuration: NSWorkspace.OpenConfiguration())
            default: break
            }
        }
        let frames = try? await Task.detached(priority: .userInitiated) { try ImageFrames.decode(url: url, info: info) }.value
        if let frames { picture.show(frames) }
        return RenderedPreview(view: view, document: document, owner: self,
                               scrollOffset: { [weak view] in view.map { Double($0.scrollView.contentView.bounds.origin.y) } },
                               restoreScroll: { [weak view] y in view?.scroll(to: CGFloat(y)) },
                               toggleInspector: { [weak view] in view?.toggleInspector() },
                               showView: { $0 == 0 })
    }
}

/// The decoded picture for the stage: one image, or an animation's frames with their delays. Downsampled so the
/// stage never holds the full-size pixels: stills to 2,560 px on the long side, an animation's frames together to
/// about 64 megapixels. roadmap: S-23
struct ImageFrames: @unchecked Sendable {
    var images: [CGImage]
    var delays: [Double]
    var loops: Int?

    static func decode(url: URL, info: ImageInfo) throws -> ImageFrames {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageInfo.ReadError.unreadable
        }
        let long = max(info.width, info.height, 1)
        if let animation = info.animation, animation.frames > 1 {
            let count = animation.delays.count
            let side = min(long, 1024, Int((64_000_000 / Double(max(count, 1))).squareRoot()))
            var images: [CGImage] = []
            for i in 0..<count {
                guard let frame = thumbnail(source, index: i, side: max(side, 16)) else { break }
                images.append(frame)
            }
            guard !images.isEmpty else { throw ImageInfo.ReadError.unreadable }
            return ImageFrames(images: images, delays: Array(animation.delays.prefix(images.count)), loops: animation.loops)
        }
        guard let still = thumbnail(source, index: 0, side: min(long, 2560)) else { throw ImageInfo.ReadError.unreadable }
        return ImageFrames(images: [still], delays: [], loops: nil)
    }

    private static func thumbnail(_ source: CGImageSource, index: Int, side: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}

/// The picture on the stage: a layer showing the image (aspect-fill for a photo, aspect-fit inside the `.ctr`
/// padding of 22 × 34 for anything else), a checkerboard under a picture with transparency, and an animation played
/// as a discrete keyframe animation of the layer's contents at the file's own frame delays. roadmap: S-23
@MainActor
final class ImageStageView: NSView {
    let fill: Bool
    let hasAlpha: Bool
    private let picture = CALayer()
    private let checker = CALayer()
    private(set) var frames: ImageFrames?
    private(set) var isAnimating = false

    init(fill: Bool, hasAlpha: Bool) {
        self.fill = fill
        self.hasAlpha = hasAlpha
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        checker.isHidden = true
        picture.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
        picture.magnificationFilter = .trilinear
        layer?.addSublayer(checker)
        layer?.addSublayer(picture)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ frames: ImageFrames) {
        self.frames = frames
        picture.contents = frames.images.first
        picture.removeAllAnimations()
        isAnimating = false
        if frames.images.count > 1, frames.delays.reduce(0, +) > 0 {
            let total = frames.delays.reduce(0, +)
            var t = 0.0
            var keyTimes: [NSNumber] = []
            for d in frames.delays { keyTimes.append(NSNumber(value: t / total)); t += d }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames.images
            animation.keyTimes = keyTimes
            animation.calculationMode = .discrete
            animation.duration = total
            animation.repeatCount = frames.loops == 0 ? .infinity : Float(max(frames.loops ?? 1, 1))
            animation.isRemovedOnCompletion = false
            animation.fillMode = .forwards
            animation.beginTime = CACurrentMediaTime()
            picture.add(animation, forKey: "frames")
            isAnimating = true
        }
        needsLayout = true
        needsDisplay = true
    }

    /// Where the picture sits: the whole stage for a photo; else fitted inside the padding.
    func pictureRect() -> CGRect {
        guard !fill, let image = frames?.images.first, image.width > 0, image.height > 0 else { return bounds }
        let box = bounds.insetBy(dx: 34, dy: 22)
        guard box.width > 0, box.height > 0 else { return bounds }
        // Never scaled up past the picture's own size in points (a 16 px icon stays small and sharp).
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height), 1)
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        // Whole points, the origin rounded and the size kept: `.integral` grew a centred 40 pt picture to 41 pt whenever
        // the centre fell on a half point, scaling it up after all (seen 2026-11-01).
        let width = size.width.rounded(), height = size.height.rounded()
        return CGRect(x: (box.midX - width / 2).rounded(), y: (box.midY - height / 2).rounded(), width: width, height: height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let rect = pictureRect()
        picture.frame = rect
        checker.frame = rect
        checker.isHidden = !(hasAlpha && !fill)
        CATransaction.commit()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            checker.backgroundColor = Self.checkerPattern(light: NSColor.token("checker1"), dark: NSColor.token("checker2"))
        }
    }

    /// An 8 pt checkerboard as a pattern colour (`checker1` and `checker2`).
    static func checkerPattern(light: NSColor, dark: NSColor) -> CGColor {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            light.setFill(); NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            dark.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: image).cgColor
    }
}
