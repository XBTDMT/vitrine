import Foundation
import ImageIO

/// An image's details from ImageIO (N-9) and, when it carries any, its AI-image provenance (T-11). roadmap: S-23
public struct MediaImageSummary: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// The uniform type ImageIO read ("public.png").
    public var typeIdentifier: String?
    public var width: Int?
    public var height: Int?
    public var dpiWidth: Double?
    public var dpiHeight: Double?
    /// "RGB", "Gray", "CMYK", "Lab".
    public var colorModel: String?
    /// The embedded color profile's name ("Display P3").
    public var profileName: String?
    /// Bits per channel.
    public var bitDepth: Int?
    public var hasAlpha: Bool?
    /// EXIF orientation 1–8.
    public var orientation: Int?
    public var frameCount: Int
    /// Loops of an animation; 0 means forever.
    public var loopCount: Int?
    /// One pass of the animation, in seconds.
    public var animationDuration: Double?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var software: String?
    /// Seconds.
    public var exposureTime: Double?
    public var fNumber: Double?
    public var iso: Int?
    /// Millimetres.
    public var focalLength: Double?
    public var focalLength35mm: Double?
    /// As the camera wrote it ("2026:05:01 10:00:00").
    public var dateTaken: String?
    /// Where it was taken, when the file records it.
    public var location: MediaCoordinate?
    public var provenance: MediaProvenance?
    public var truncated: Bool
}

enum MediaImageReader {
    static let maxFramesTimed = 5_000

    static func read(url: URL?, data: Data, fileName: String) -> MediaImageSummary? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource? = if let url { CGImageSourceCreateWithURL(url as CFURL, options) }
            else { CGImageSourceCreateWithData(data as CFData, options) }
        let type = source.flatMap { CGImageSourceGetType($0) as String? }
        let count = source.map { CGImageSourceGetCount($0) } ?? 0

        var s = MediaImageSummary(headline: MediaPath.base(fileName), facts: [], warnings: [], typeIdentifier: type,
                                  width: nil, height: nil, dpiWidth: nil, dpiHeight: nil, colorModel: nil,
                                  profileName: nil, bitDepth: nil, hasAlpha: nil, orientation: nil, frameCount: count,
                                  loopCount: nil, animationDuration: nil, cameraMake: nil, cameraModel: nil, lens: nil,
                                  software: nil, exposureTime: nil, fNumber: nil, iso: nil, focalLength: nil,
                                  focalLength35mm: nil, dateTaken: nil, location: nil, provenance: nil, truncated: false)
        var userComment: String?
        if let source, count > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            s.width = int(props[kCGImagePropertyPixelWidth])
            s.height = int(props[kCGImagePropertyPixelHeight])
            s.dpiWidth = double(props[kCGImagePropertyDPIWidth])
            s.dpiHeight = double(props[kCGImagePropertyDPIHeight])
            s.colorModel = props[kCGImagePropertyColorModel] as? String
            s.profileName = MediaText.clean(props[kCGImagePropertyProfileName] as? String, max: 200)
            s.bitDepth = int(props[kCGImagePropertyDepth])
            s.hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool
            s.orientation = int(props[kCGImagePropertyOrientation])

            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            s.cameraMake = MediaText.clean(tiff?[kCGImagePropertyTIFFMake] as? String, max: 100)
            s.cameraModel = MediaText.clean(tiff?[kCGImagePropertyTIFFModel] as? String, max: 100)
            s.software = MediaText.clean(tiff?[kCGImagePropertyTIFFSoftware] as? String, max: 200)
            s.lens = MediaText.clean(exif?[kCGImagePropertyExifLensModel] as? String, max: 200)
            s.exposureTime = double(exif?[kCGImagePropertyExifExposureTime])
            s.fNumber = double(exif?[kCGImagePropertyExifFNumber])
            s.iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(int)
            s.focalLength = double(exif?[kCGImagePropertyExifFocalLength])
            s.focalLength35mm = double(exif?[kCGImagePropertyExifFocalLenIn35mmFilm])
            s.dateTaken = MediaText.clean((exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String, max: 40)
            userComment = exif?[kCGImagePropertyExifUserComment] as? String
            if let gps, let lat = double(gps[kCGImagePropertyGPSLatitude]), let lon = double(gps[kCGImagePropertyGPSLongitude]) {
                let latSign = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -1.0 : 1.0
                let lonSign = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -1.0 : 1.0
                var alt = double(gps[kCGImagePropertyGPSAltitude])
                if let a = alt, int(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { alt = -a }
                s.location = MediaCoordinate(latitude: lat * latSign, longitude: lon * lonSign, elevation: alt)
            }
            animation(source, count: count, first: props, into: &s)
        }
        s.provenance = MediaProvenanceReader.read(data: data, exifUserComment: userComment)
        guard type != nil || s.provenance != nil else { return nil }
        if count == 0 || s.width == nil {
            s.warnings.append(MediaWarning(.danger, String(localized: "ImageIO could not read this image; it may be damaged or cut short.", bundle: .module, comment: "Image card warning.")))
        }
        if s.location != nil {
            s.warnings.append(MediaWarning(.caution, String(localized: "This image records where it was taken (GPS location). Anyone you send it to can see that place.", bundle: .module, comment: "Image card warning about GPS metadata.")))
        }
        if let p = s.provenance { s.warnings += p.warnings }

        if let w = s.width, let h = s.height { s.headline = "\(w) × \(h)" }
        var facts: [MediaFact] = []
        if let w = s.width, let h = s.height {
            facts.append(MediaFact(String(localized: "Dimensions", bundle: .module, comment: "Image fact label."), "\(w) × \(h)"))
        }
        if let x = s.dpiWidth {
            let y = s.dpiHeight ?? x
            facts.append(MediaFact(String(localized: "Resolution", bundle: .module, comment: "Image fact label (dots per inch)."),
                                   x == y ? "\(MediaText.number(x, digits: 0)) dpi" : "\(MediaText.number(x, digits: 0)) × \(MediaText.number(y, digits: 0)) dpi"))
        }
        if let m = s.colorModel {
            let depth = s.bitDepth.map { " · \($0)-bit" } ?? ""
            facts.append(MediaFact(String(localized: "Color", bundle: .module, comment: "Image fact label: color model and bit depth."), m + depth + (s.hasAlpha == true ? " · α" : "")))
        }
        if let p = s.profileName { facts.append(MediaFact(String(localized: "Profile", bundle: .module, comment: "Image fact label: color profile."), p)) }
        if let o = s.orientation, o != 1 { facts.append(MediaFact(String(localized: "Orientation", bundle: .module, comment: "Image fact label."), "\(o)")) }
        if s.frameCount > 1 {
            facts.append(MediaFact(String(localized: "Frames", bundle: .module, comment: "Image fact label: animation frames."), "\(s.frameCount)"))
            if let d = s.animationDuration { facts.append(MediaFact(String(localized: "Duration", bundle: .module, comment: "Image fact label: animation length."), "\(MediaText.number(d, digits: 2)) s")) }
            if let l = s.loopCount {
                facts.append(MediaFact(String(localized: "Loops", bundle: .module, comment: "Image fact label: animation loop count."),
                                       l == 0 ? String(localized: "Forever", bundle: .module, comment: "An animation that loops forever.") : "\(l)"))
            }
        }
        let camera = [s.cameraMake, s.cameraModel].compactMap { $0 }
        if !camera.isEmpty {
            let model = s.cameraModel ?? ""
            let text = s.cameraMake.map { make in model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)" } ?? model
            facts.append(MediaFact(String(localized: "Camera", bundle: .module, comment: "Image fact label."), text.trimmingCharacters(in: .whitespaces)))
        }
        if let l = s.lens { facts.append(MediaFact(String(localized: "Lens", bundle: .module, comment: "Image fact label."), l)) }
        var exposure: [String] = []
        if let t = s.exposureTime {
            // 1/t only when it is a whole number an Int holds: a tiny exposure from the file would make it trap.
            if t < 1, t > 0, let denominator = FormatMath.int(rounding: 1 / t) { exposure.append("1/\(denominator) s") }
            else { exposure.append("\(MediaText.number(t, digits: 1)) s") }
        }
        if let f = s.fNumber { exposure.append("ƒ/\(MediaText.number(f, digits: 1))") }
        if let i = s.iso { exposure.append("ISO \(i)") }
        if let f = s.focalLength { exposure.append("\(MediaText.number(f, digits: 1)) mm") }
        if !exposure.isEmpty { facts.append(MediaFact(String(localized: "Exposure", bundle: .module, comment: "Image fact label: shutter, aperture, ISO, focal length."), exposure.joined(separator: " · "))) }
        if let d = s.dateTaken { facts.append(MediaFact(String(localized: "Taken", bundle: .module, comment: "Image fact label: date the photo was taken."), d)) }
        if let g = s.location {
            facts.append(MediaFact(String(localized: "Location", bundle: .module, comment: "Image fact label: GPS position."),
                                   String(format: "%.5f, %.5f", g.latitude, g.longitude) + (g.elevation.map { " · \(MediaText.number($0, digits: 0)) m" } ?? "")))
        }
        if let sw = s.software { facts.append(MediaFact(String(localized: "Software", bundle: .module, comment: "Image fact label."), sw)) }
        s.facts = facts
        return s
    }

    /// Loop count and one pass's duration for GIF, APNG, WebP and HEICS animations.
    static func animation(_ source: CGImageSource, count: Int, first: [CFString: Any], into s: inout MediaImageSummary) {
        guard count > 1 else { return }
        let families: [(CFString, CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        for (dict, loop, unclamped, clamped) in families {
            guard first[dict] != nil || container?[dict] != nil else { continue }
            let top = container?[dict] as? [CFString: Any]
            s.loopCount = int(top?[loop]) ?? int((first[dict] as? [CFString: Any])?[loop])
            var total = 0.0
            var timed = 0
            for i in 0..<min(count, maxFramesTimed) {
                guard let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                      let d = p[dict] as? [CFString: Any] else { continue }
                if let delay = double(d[unclamped]) ?? double(d[clamped]) { total += delay; timed += 1 }
            }
            if count > maxFramesTimed { s.truncated = true }
            if timed > 0 { s.animationDuration = total }
            return
        }
    }

    static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
    static func double(_ any: Any?) -> Double? {
        guard let v = (any as? NSNumber)?.doubleValue, v.isFinite else { return nil }
        return v
    }
}
