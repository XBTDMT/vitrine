import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What ImageIO says about a picture, read without decoding its pixels: format, size as shown (orientation applied),
/// colour, bit depth, animation, the camera's EXIF and the GPS position the file carries. Everything comes from the
/// file alone; nothing is looked up (no place names, no map tiles), so the extension's sandbox and the no-network rule
/// both hold. roadmap: S-23
struct ImageInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case photo, animated, image }

    struct Location: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        /// Metres above sea level; negative below it.
        var altitude: Double?
    }

    struct Animation: Equatable, Sendable {
        var frames: Int
        /// Seconds per frame, as the file asks (unclamped where the format says so).
        var delays: [Double]
        /// 0 = forever; nil = the file does not say (GIF without a loop block plays once).
        var loops: Int?
        var duration: Double { delays.reduce(0, +) }
        /// Every frame within 1 ms of the first.
        var evenTiming: Bool { delays.allSatisfy { abs($0 - (delays.first ?? 0)) < 0.001 } }
    }

    /// One property as the file stores it, for the Info view: "Exif › FNumber: 2".
    struct Property: Equatable, Sendable {
        var group: String
        var key: String
        var value: String
    }

    var typeIdentifier: String
    var formatName: String
    var width: Int
    var height: Int
    var imageCount: Int
    var dpi: Double?
    var colorModel: String?
    var profileName: String?
    var bitDepth: Int?
    var hasAlpha: Bool
    var isHDR: Bool
    var animation: Animation?
    var compression: String?
    var make: String?
    var model: String?
    var lens: String?
    var focalLength: Double?
    var focalLength35: Int?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Int?
    var exposureBias: Double?
    var flashFired: Bool?
    /// "2026:10:11 17:42:00" as EXIF writes it: the camera's own clock, no time zone.
    var dateTaken: String?
    var software: String?
    var location: Location?
    var properties: [Property]

    var kind: Kind {
        if let animation, animation.frames > 1 { return .animated }
        return isPhoto ? .photo : .image
    }

    /// A camera wrote it: a camera model or exposure settings.
    var isPhoto: Bool { model != nil || make != nil || exposureTime != nil || fNumber != nil }

    var megapixels: Double { Double(width) * Double(height) / 1_000_000 }

    enum ReadError: Error, LocalizedError {
        case unreadable
        var errorDescription: String? {
            String(localized: "ImageIO cannot read this picture", bundle: .previewKit, comment: "Error shown when macOS's image reader cannot open the file.")
        }
    }

    /// Reads the picture's properties. Frames are read up to `frameLimit` (their delays only, never their pixels).
    static func read(url: URL, frameLimit: Int = 10_000) throws -> ImageInfo {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetStatus(source) != .statusInvalidData,
              let type = CGImageSourceGetType(source) as String?, CGImageSourceGetCount(source) > 0 else { throw ReadError.unreadable }
        let count = CGImageSourceGetCount(source)
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] ?? [:]
        let exif = first[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = first[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = first[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var width = int(first[kCGImagePropertyPixelWidth]) ?? 0
        var height = int(first[kCGImagePropertyPixelHeight]) ?? 0
        // Orientations 5 to 8 turn the picture a quarter: it is shown with width and height swapped.
        if let orientation = int(first[kCGImagePropertyOrientation]), (5...8).contains(orientation) { swap(&width, &height) }

        let animation = readAnimation(source: source, type: type, container: container, count: count, limit: frameLimit)
        var info = ImageInfo(
            typeIdentifier: type, formatName: formatName(type: type, animated: (animation?.frames ?? 0) > 1),
            width: width, height: height, imageCount: count,
            dpi: double(first[kCGImagePropertyDPIWidth]),
            colorModel: first[kCGImagePropertyColorModel] as? String,
            profileName: first[kCGImagePropertyProfileName] as? String,
            bitDepth: int(first[kCGImagePropertyDepth]),
            hasAlpha: (first[kCGImagePropertyHasAlpha] as? Bool) ?? false,
            isHDR: false, animation: animation, compression: nil,
            make: text(tiff[kCGImagePropertyTIFFMake]), model: text(tiff[kCGImagePropertyTIFFModel]),
            lens: text(exif[kCGImagePropertyExifLensModel]),
            focalLength: double(exif[kCGImagePropertyExifFocalLength]),
            focalLength35: int(exif[kCGImagePropertyExifFocalLenIn35mmFilm]),
            fNumber: double(exif[kCGImagePropertyExifFNumber]),
            exposureTime: double(exif[kCGImagePropertyExifExposureTime]),
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(int),
            exposureBias: double(exif[kCGImagePropertyExifExposureBiasValue]),
            flashFired: int(exif[kCGImagePropertyExifFlash]).map { $0 & 1 == 1 },
            dateTaken: text(exif[kCGImagePropertyExifDateTimeOriginal]) ?? text(tiff[kCGImagePropertyTIFFDateTime]),
            software: text(tiff[kCGImagePropertyTIFFSoftware]),
            location: readLocation(gps),
            properties: flatten(first))
        info.isHDR = readHDR(source: source)
        info.compression = compression(type: type, url: url, tiff: tiff)
        return info
    }

    // MARK: Reading

    private static func readAnimation(source: CGImageSource, type: String, container: [CFString: Any], count: Int, limit: Int) -> Animation? {
        guard count > 1 else { return nil }
        let keys: (dict: CFString, unclamped: CFString, delay: CFString, loops: CFString)
        switch type {
        case UTType.gif.identifier:
            keys = (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFLoopCount)
        case UTType.png.identifier:
            keys = (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGLoopCount)
        case UTType.webP.identifier:
            keys = (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPLoopCount)
        case "public.heics", UTType.heic.identifier, UTType.heif.identifier, "public.avis", "public.avif":
            keys = (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSLoopCount)
        default:
            return nil
        }
        var delays: [Double] = []
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        for i in 0..<min(count, limit) {
            let frame = CGImageSourceCopyPropertiesAtIndex(source, i, options) as? [CFString: Any]
            let dict = frame?[keys.dict] as? [CFString: Any]
            guard let delay = double(dict?[keys.unclamped]).flatMap({ $0 > 0 ? $0 : nil }) ?? double(dict?[keys.delay]) else {
                // A HEIC holding several pictures without timing is a set of images, not an animation.
                if i == 0 { return nil }
                delays.append(delays.last ?? 0.1)
                continue
            }
            delays.append(delay)
        }
        let loops = int((container[keys.dict] as? [CFString: Any])?[keys.loops])
        return Animation(frames: count, delays: delays, loops: loops)
    }

    private static func readLocation(_ gps: [CFString: Any]) -> Location? {
        guard var lat = double(gps[kCGImagePropertyGPSLatitude]), var lon = double(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -abs(lat) }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lon = -abs(lon) }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        var altitude = double(gps[kCGImagePropertyGPSAltitude])
        if let a = altitude, int(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -abs(a) }
        return Location(latitude: lat, longitude: lon, altitude: altitude)
    }

    /// An HDR picture: a gain map beside the base image (Apple's or ISO 21496-1), or a PQ/HLG colour space.
    private static func readHDR(source: CGImageSource) -> Bool {
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil { return true }
        }
        // Creating the image does not decode it (no cache); only its colour space is read.
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
        if let image = CGImageSourceCreateImageAtIndex(source, 0, options), let space = image.colorSpace {
            return CGColorSpaceUsesITUR_2100TF(space)
        }
        return false
    }

    /// The compression where the format fixes it or says it: WebP's VP8L chunk is lossless and VP8 lossy, PNG and GIF
    /// are lossless, JPEG lossy, TIFF names its scheme.
    private static func compression(type: String, url: URL, tiff: [CFString: Any]) -> String? {
        switch type {
        case UTType.png.identifier, UTType.gif.identifier: return lossless
        case UTType.jpeg.identifier: return lossy
        case UTType.webP.identifier: return webPCompression(url)
        case UTType.tiff.identifier:
            switch int(tiff[kCGImagePropertyTIFFCompression]) {
            case 1?: return String(localized: "none", bundle: .previewKit, comment: "A TIFF's compression: none.")
            case 5?: return String(localized: "LZW, lossless", bundle: .previewKit, comment: "A TIFF's compression scheme (LZW is its name).")
            case 6?, 7?: return String(localized: "JPEG, lossy", bundle: .previewKit, comment: "A TIFF's compression scheme (JPEG is its name).")
            case 8?, 32946?: return String(localized: "Deflate, lossless", bundle: .previewKit, comment: "A TIFF's compression scheme (Deflate is its name).")
            case 32773?: return String(localized: "PackBits, lossless", bundle: .previewKit, comment: "A TIFF's compression scheme (PackBits is its name).")
            default: return nil
            }
        default: return nil
        }
    }

    static var lossless: String { String(localized: "lossless", bundle: .previewKit, comment: "A picture's compression: no detail is lost.") }
    static var lossy: String { String(localized: "lossy", bundle: .previewKit, comment: "A picture's compression: some detail is lost.") }

    /// Walks the RIFF chunks (and the first ANMF frame of an animation) for `VP8L` or `VP8 `.
    static func webPCompression(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), data.count >= 20,
              data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) else { return nil }
        let bytes = [UInt8](data)
        func walk(_ start: Int, _ end: Int) -> String? {
            var offset = start
            while offset + 8 <= end {
                let tag = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
                let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
                switch tag {
                case "VP8L": return lossless
                case "VP8 ": return lossy
                case "ANMF": if let found = walk(offset + 8 + 16, min(end, offset + 8 + size)) { return found }
                default: break
                }
                offset += 8 + size + (size & 1)
            }
            return nil
        }
        return walk(12, bytes.count)
    }

    /// Every property, groups in their dictionary name ("Exif", "GPS", "TIFF"), for the Info view.
    private static func flatten(_ properties: [CFString: Any]) -> [Property] {
        var out: [Property] = []
        func add(_ group: String, _ dict: [CFString: Any], depth: Int) {
            for (key, value) in dict.sorted(by: { ($0.key as String) < ($1.key as String) }) {
                let name = (key as String).trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                if let nested = value as? [CFString: Any] {
                    if depth < 2 { add(group.isEmpty ? name : "\(group) › \(name)", nested, depth: depth + 1) }
                    continue
                }
                guard out.count < 2_000 else { return }
                out.append(Property(group: group, key: name, value: describe(value)))
            }
        }
        add("", properties, depth: 0)
        return out.sorted { ($0.group.isEmpty ? 0 : 1, $0.group) < ($1.group.isEmpty ? 0 : 1, $1.group) }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let s as String: return s.count > 500 ? String(s.prefix(500)) + "…" : s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.prefix(32).map(describe).joined(separator: ", ") + (a.count > 32 ? ", …" : "")
        case let d as Data: return ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file)
        default: return String(describing: value)
        }
    }

    // MARK: Values

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))), !s.isEmpty else { return nil }
        return s
    }

    /// "JPEG", "HEIC", "PNG" (APNG when it moves), "WebP", "RAW (CR3)".
    static func formatName(type: String, animated: Bool) -> String {
        switch type {
        case UTType.jpeg.identifier: return "JPEG"
        case UTType.heic.identifier: return "HEIC"
        case UTType.heif.identifier: return "HEIF"
        case "public.heics": return String(localized: "HEIC sequence", bundle: .previewKit, comment: "Picture format: a sequence of HEIC images (HEIC is the format's name).")
        case UTType.png.identifier: return animated ? "APNG" : "PNG"
        case UTType.webP.identifier: return "WebP"
        case UTType.gif.identifier: return "GIF"
        case UTType.tiff.identifier: return "TIFF"
        case "public.avif": return "AVIF"
        case "public.avis": return String(localized: "AVIF sequence", bundle: .previewKit, comment: "Picture format: a sequence of AVIF images (AVIF is the format's name).")
        case "public.jpeg-xl": return "JPEG XL"
        case UTType.bmp.identifier: return "BMP"
        case UTType.ico.identifier: return "ICO"
        case UTType.icns.identifier: return "ICNS"
        default:
            let t = UTType(type)
            let ext = t?.preferredFilenameExtension?.uppercased()
            if t?.conforms(to: .rawImage) == true { return ext.map { "RAW (\($0))" } ?? "RAW" }
            return ext ?? String(localized: "image", bundle: .previewKit, comment: "Picture format when the file's type has no name or extension.")
        }
    }
}
