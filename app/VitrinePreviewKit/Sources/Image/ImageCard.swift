import Foundation
import VitrineDocument

/// The card's words for a picture, from `ImageInfo` (cards.html §3b "Photo in the Vitrine window" and §4 "Animated
/// image"): a photo says what took it and when, and whether it carries a location; an animation says how long it
/// runs; any other picture says its size, format and colour. Pure data. roadmap: S-23
///
/// Location in a photo (the privacy treatment): the sentence always says whether the file carries a GPS position;
/// when it does, the Location section shows the coordinates and altitude as a neutral flagged row numbered 1 (the
/// design's `.flag-neutral`), the pill's tooltip carries an info badge, and Copy coordinates is the only thing done
/// with them. No place name is looked up and no map tile is fetched: both would send the position off the Mac.
enum ImageCard {
    static func make(_ info: ImageInfo, fileName: String, fileSize: Int64, locale: Locale = .current, now: Date = Date()) -> InfoCard {
        switch info.kind {
        case .photo: return photo(info, fileName: fileName, locale: locale, now: now)
        case .animated: return animated(info, fileName: fileName)
        case .image: return image(info, fileName: fileName, fileSize: fileSize)
        }
    }

    // MARK: Photo

    static func photo(_ info: ImageInfo, fileName: String, locale: Locale, now: Date) -> InfoCard {
        let mp = megapixels(info)
        // The sentence is put together from whole localized phrases: the subject, then what took it and when, then the
        // location clause. The bold parts are localized on their own and match the words the sentence uses.
        let subject: String
        let what: String
        if let mp {
            what = String(localized: "\(mp) photo", bundle: .previewKit,
                          comment: "Bold part of a photo's sentence, e.g. “12 MP photo”; must match the words of the sentence.")
            subject = InfoCard.article(beforeNumber: mp) == "an"
                ? String(localized: "An \(mp) photo", bundle: .previewKit,
                         comment: "Start of a photo's sentence; the argument is its megapixels, e.g. “8 MP” (English says “An” before a number said with a vowel).")
                : String(localized: "A \(mp) photo", bundle: .previewKit,
                         comment: "Start of a photo's sentence; the argument is its megapixels, e.g. “12 MP”.")
        } else {
            what = String(localized: "photo", bundle: .previewKit, comment: "Bold part of a photo's sentence; must match the words of the sentence.")
            subject = String(localized: "A photo", bundle: .previewKit, comment: "Start of a photo's sentence when its size says nothing.")
        }
        let taken = info.dateTaken.flatMap { takenPhrase($0, locale: locale, now: now) }
        let camera = cameraName(info)
        let described: String
        switch (taken, camera) {
        case let (taken?, camera?):
            described = cameraArticle(camera) == "an"
                ? String(localized: "\(subject) taken \(taken) on an \(camera)", bundle: .previewKit,
                         comment: "A photo's subject, when it was taken and the camera; e.g. “A photo taken Sunday 11 October at 17:42 on an Olympus E-M1”.")
                : String(localized: "\(subject) taken \(taken) on a \(camera)", bundle: .previewKit,
                         comment: "A photo's subject, when it was taken and the camera; e.g. “A photo taken Sunday 11 October at 17:42 on a Canon EOS R5”.")
        case let (taken?, nil):
            described = String(localized: "\(subject) taken \(taken)", bundle: .previewKit,
                               comment: "A photo's subject and when it was taken; e.g. “A photo taken Sunday 11 October at 17:42”.")
        case let (nil, camera?):
            described = cameraArticle(camera) == "an"
                ? String(localized: "\(subject) taken on an \(camera)", bundle: .previewKit,
                         comment: "A photo's subject and the camera; e.g. “A photo taken on an Olympus E-M1”.")
                : String(localized: "\(subject) taken on a \(camera)", bundle: .previewKit,
                         comment: "A photo's subject and the camera; e.g. “A photo taken on a Canon EOS R5”.")
        case (nil, nil):
            described = subject
        }
        let locationPhrase: String
        let sentence: String
        if info.location == nil {
            locationPhrase = String(localized: "carries no location", bundle: .previewKit,
                                    comment: "Bold part of a photo's sentence; must match the words of the sentence.")
            sentence = String(localized: "\(described); it carries no location.", bundle: .previewKit,
                              comment: "A photo's sentence when the file holds no GPS position; the argument is the start of the sentence.")
        } else {
            locationPhrase = String(localized: "carries its GPS location", bundle: .previewKit,
                                    comment: "Bold part of a photo's sentence; must match the words of the sentence.")
            sentence = String(localized: "\(described); it carries its GPS location.", bundle: .previewKit,
                              comment: "A photo's sentence when the file holds a GPS position; the argument is the start of the sentence.")
        }

        var strip: [InfoCard.Stat] = []
        if let camera { strip.append(.init(value: camera, label: String(localized: "Camera", bundle: .previewKit, comment: "Image card label: the camera that took the photo."))) }
        if let exposure = exposureLine(info) {
            strip.append(.init(value: exposure, label: String(localized: "Exposure", bundle: .previewKit, comment: "Image card label: aperture, shutter speed and ISO.")))
        }
        strip.append(.init(value: pixels(info), label: String(localized: "Pixels", bundle: .previewKit, comment: "Image card label: width × height in pixels.")))

        var actions: [InfoCard.Action] = []
        if info.location != nil {
            actions.append(.init(id: "copyCoordinates", title: String(localized: "Copy coordinates", bundle: .previewKit, comment: "Button: copies the picture's GPS coordinates."),
                                 style: .primary))
        }
        actions.append(.init(id: "openInPhotos", title: String(localized: "Open in Photos", bundle: .previewKit, comment: "Button: opens the picture in the Photos app."),
                             style: .normal))

        var sections: [InfoCard.Section] = []
        let chips = exposureChips(info)
        if !chips.isEmpty {
            sections.append(.init(title: String(localized: "Exposure", bundle: .previewKit, comment: "Image card section: the camera's exposure settings."), content: .chips(chips)))
        }
        var rows = imageRows(info)
        if let camera {
            rows.append(.init(key: String(localized: "Camera", bundle: .previewKit, comment: "Image card row: the camera and lens."),
                              value: [camera, info.lens].compactMap { $0 }.joined(separator: " · ")))
        }
        sections.append(.init(title: String(localized: "Image", bundle: .previewKit, comment: "Image card section: size, resolution and colour."), content: .rows(rows)))
        if let location = info.location {
            sections.append(.init(title: String(localized: "Location", bundle: .previewKit, comment: "Image card section: the GPS position the file carries."),
                                  content: .rows(locationRows(location))))
        }
        return InfoCard(kindName: String(localized: "Photo", bundle: .previewKit, comment: "Kind of picture: a photo a camera took."),
                        title: fileName, sentence: sentence, bold: [what, locationPhrase],
                        tileToken: "kind-image", tileSymbol: "camera", strip: Array(strip.prefix(3)), actions: actions, sections: sections)
    }

    // MARK: Animated image

    static func animated(_ info: ImageInfo, fileName: String) -> InfoCard {
        guard let a = info.animation else { return image(info, fileName: fileName, fileSize: 0) }
        let length = seconds(a.duration)
        let fps = rate(a)
        let loops = loopPhrase(a.loops)
        let sentence: String
        if let fps {
            let words = fps.words
            sentence = String(localized: "An animated image, \(length) long at \(words), \(loops).", bundle: .previewKit,
                              comment: "An animation's sentence: its length, frame rate and loops; e.g. “An animated image, 0.4 seconds long at 10 frames a second, looping forever.”")
        } else {
            sentence = String(localized: "An animated image, \(length) long, \(loops).", bundle: .previewKit,
                              comment: "An animation's sentence: its length and loops; e.g. “An animated image, 2 seconds long, playing once.”")
        }
        let framesLabel = String(localized: "Frames", bundle: .previewKit, comment: "Image card label: the number of frames in an animation.")
        let rateLabel = String(localized: "Rate", bundle: .previewKit, comment: "Image card label: an animation's frame rate.")
        var strip: [InfoCard.Stat] = [.init(value: a.frames.formatted(), label: framesLabel)]
        if let fps { strip.append(.init(value: fps.short, label: rateLabel)) }
        strip.append(.init(value: pixels(info), label: String(localized: "Pixels", bundle: .previewKit, comment: "Image card label: width × height in pixels.")))
        let frameCount = a.frames.formatted()
        let duration = a.duration.formatted(.number.precision(.fractionLength(1)))
        var animation: [InfoCard.Row] = [
            .init(key: framesLabel, value: String(localized: "\(frameCount) · \(duration) s", bundle: .previewKit,
                                                  comment: "An animation's frame count and its length in seconds; e.g. “4 · 0.4 s”.")),
        ]
        if let fps {
            let short = fps.short
            animation.append(.init(key: rateLabel, value: a.evenTiming
                ? String(localized: "\(short), even timing", bundle: .previewKit, comment: "An animation's rate when every frame lasts as long; e.g. “10 fps, even timing”.")
                : String(localized: "\(short), uneven timing", bundle: .previewKit, comment: "An animation's rate when its frames last different times; e.g. “10 fps, uneven timing”.")))
        }
        animation.append(.init(key: String(localized: "Loops", bundle: .previewKit, comment: "Image card row: how many times an animation plays."), value: loopsValue(a.loops)))
        animation.append(.init(key: String(localized: "Size", bundle: .previewKit, comment: "Image card row: an animation's size in pixels."), value: sizeWithAlpha(info)))
        if let compression = info.compression {
            animation.append(.init(key: String(localized: "Compression", bundle: .previewKit, comment: "Image card row: lossless or lossy."), value: compression))
        }
        var image: [InfoCard.Row] = [.init(key: String(localized: "Format", bundle: .previewKit, comment: "Image card row: the file format."), value: info.formatName)]
        if let colour = colour(info) {
            image.append(.init(key: String(localized: "Colour", bundle: .previewKit, comment: "Image card row: colour profile and bit depth."), value: colour))
        }
        if let dpi = info.dpi {
            image.append(.init(key: String(localized: "Resolution", bundle: .previewKit, comment: "Image card row: dots per inch."), value: dpiValue(dpi)))
        }
        var sections: [InfoCard.Section] = [
            .init(title: String(localized: "Animation", bundle: .previewKit, comment: "Image card section: frames, rate and loops."), content: .rows(animation)),
            .init(title: String(localized: "Image", bundle: .previewKit, comment: "Image card section: size, resolution and colour."), content: .rows(image)),
        ]
        if let location = info.location {
            sections.append(.init(title: String(localized: "Location", bundle: .previewKit, comment: "Image card section: the GPS position the file carries."),
                                  content: .rows(locationRows(location))))
        }
        let bold = [fps?.words].compactMap { $0 }
            + [String(localized: "animated image", bundle: .previewKit, comment: "Bold part of an animation's sentence; must match the words of the sentence.")]
        return InfoCard(kindName: String(localized: "Animated image", bundle: .previewKit, comment: "Kind of picture: one that moves (GIF, APNG, WebP)."),
                        title: fileName, sentence: sentence, bold: bold,
                        tileToken: "kind-image", tileSymbol: "play.rectangle", strip: strip, actions: [], sections: sections)
    }

    // MARK: Any other picture

    static func image(_ info: ImageInfo, fileName: String, fileSize: Int64) -> InfoCard {
        let dimensions = pixels(info)
        let format = info.formatName
        let what = String(localized: "\(dimensions) \(format) image", bundle: .previewKit,
                          comment: "Bold part of a picture's sentence, e.g. “1280 × 800 PNG image”; must match the words of the sentence.")
        let subject = InfoCard.article(beforeNumber: dimensions) == "an"
            ? String(localized: "An \(dimensions) \(format) image", bundle: .previewKit,
                     comment: "Start of a picture's sentence: its size and format, e.g. “An 800 × 600 PNG image” (English says “An” before a number said with a vowel).")
            : String(localized: "A \(dimensions) \(format) image", bundle: .previewKit,
                     comment: "Start of a picture's sentence: its size and format, e.g. “A 1280 × 800 PNG image”.")
        let colourName = info.profileName ?? info.colorModel
        let described: String
        switch (colourName, info.hasAlpha) {
        case let (colour?, true):
            described = String(localized: "\(subject) in \(colour), with transparency", bundle: .previewKit,
                               comment: "A picture's subject, colour space and transparency; e.g. “A 1280 × 800 PNG image in sRGB, with transparency”.")
        case let (colour?, false):
            described = String(localized: "\(subject) in \(colour)", bundle: .previewKit,
                               comment: "A picture's subject and colour space; e.g. “A 1280 × 800 PNG image in Display P3”.")
        case (nil, true):
            described = String(localized: "\(subject), with transparency", bundle: .previewKit,
                               comment: "A picture's subject and transparency; e.g. “A 64 × 64 PNG image, with transparency”.")
        case (nil, false):
            described = subject
        }
        let sentence = info.location != nil
            ? String(localized: "\(described); it carries a GPS location.", bundle: .previewKit,
                     comment: "A picture's sentence when the file holds a GPS position; the argument is the start of the sentence.")
            : String(localized: "\(described).", bundle: .previewKit, comment: "A picture's sentence; the argument is the sentence without its full stop.")
        var strip: [InfoCard.Stat] = [.init(value: dimensions, label: String(localized: "Pixels", bundle: .previewKit, comment: "Image card label: width × height in pixels."))]
        if let colour = colourName {
            strip.append(.init(value: colour, label: String(localized: "Colour", bundle: .previewKit, comment: "Image card label: the colour profile or model.")))
        }
        if fileSize > 0 {
            strip.append(.init(value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file),
                               label: String(localized: "Size", bundle: .previewKit, comment: "Image card label: the file size.")))
        }
        var rows = imageRows(info)
        rows.append(.init(key: String(localized: "Format", bundle: .previewKit, comment: "Image card row: the file format and its compression."),
                          value: [info.formatName, info.compression].compactMap { $0 }.joined(separator: ", ")))
        if info.imageCount > 1 {
            let count = info.imageCount.formatted()
            rows.append(.init(key: String(localized: "Images", bundle: .previewKit, comment: "Image card row: how many pictures the file holds."),
                              value: String(localized: "\(count) in the file", bundle: .previewKit, comment: "How many pictures the file holds; e.g. “3 in the file”.")))
        }
        if let software = info.software {
            rows.append(.init(key: String(localized: "Made with", bundle: .previewKit, comment: "Image card row: the software that wrote the picture."), value: software))
        }
        var sections: [InfoCard.Section] = [
            .init(title: String(localized: "Image", bundle: .previewKit, comment: "Image card section: size, resolution and colour."), content: .rows(rows)),
        ]
        if let location = info.location {
            sections.append(.init(title: String(localized: "Location", bundle: .previewKit, comment: "Image card section: the GPS position the file carries."),
                                  content: .rows(locationRows(location))))
        }
        var actions: [InfoCard.Action] = []
        if info.location != nil {
            actions.append(.init(id: "copyCoordinates", title: String(localized: "Copy coordinates", bundle: .previewKit, comment: "Button: copies the picture's GPS coordinates."),
                                 style: .primary))
        }
        return InfoCard(kindName: String(localized: "Image", bundle: .previewKit, comment: "Kind of picture: a still image that is not a photo."),
                        title: fileName, sentence: sentence, bold: [what], tileToken: "kind-image", tileSymbol: "photo",
                        strip: strip, actions: actions, sections: sections)
    }

    // MARK: Facts, badges, the Info view

    static func facts(_ info: ImageInfo, card: InfoCard, fileSize: Int64) -> [Fact] {
        var facts = [Fact(key: "kindName", label: String(localized: "Kind", bundle: .previewKit, comment: "Fact label: what kind of picture it is."), value: card.kindName),
                     DocumentFacts.size(fileSize),
                     Fact(key: "dimensions", label: String(localized: "Dimensions", bundle: .previewKit, comment: "Fact label: width × height in pixels."), value: pixels(info)),
                     Fact(key: "format", label: String(localized: "Format", bundle: .previewKit, comment: "Fact label: the picture's file format."), value: info.formatName)]
        if let colour = colour(info) {
            facts.append(Fact(key: "colour", label: String(localized: "Colour", bundle: .previewKit, comment: "Fact label: colour profile and bit depth."), value: colour))
        }
        if let camera = cameraName(info) {
            facts.append(Fact(key: "camera", label: String(localized: "Camera", bundle: .previewKit, comment: "Fact label: the camera that took the photo."), value: camera))
        }
        if let lens = info.lens { facts.append(Fact(key: "lens", label: String(localized: "Lens", bundle: .previewKit, comment: "Fact label: the camera's lens."), value: lens)) }
        if let exposure = exposureLine(info) {
            facts.append(Fact(key: "exposure", label: String(localized: "Exposure", bundle: .previewKit, comment: "Fact label: aperture, shutter speed and ISO."), value: exposure))
        }
        if let taken = info.dateTaken {
            facts.append(Fact(key: "taken", label: String(localized: "Taken", bundle: .previewKit, comment: "Fact label: when the photo was taken, as the camera wrote it."), value: taken))
        }
        if let a = info.animation, a.frames > 1 {
            facts.append(Fact(key: "frames", label: String(localized: "Frames", bundle: .previewKit, comment: "Fact label: the number of frames in an animation."),
                              value: a.frames.formatted()))
            let duration = a.duration.formatted(.number.precision(.fractionLength(1)))
            facts.append(Fact(key: "duration", label: String(localized: "Duration", bundle: .previewKit, comment: "Fact label: how long an animation runs."),
                              value: String(localized: "\(duration) s", bundle: .previewKit, comment: "A length in seconds; e.g. “0.4 s”.")))
        }
        if let location = info.location {
            facts.append(Fact(key: "location", label: String(localized: "Location", bundle: .previewKit, comment: "Fact label: the GPS position the file carries."),
                              value: coordinates(location)))
        }
        return facts
    }

    static func badges(_ info: ImageInfo) -> [Badge] {
        guard let location = info.location else { return [] }
        let place = coordinates(location)
        return [Badge(level: .info, title: String(localized: "Carries a GPS location", bundle: .previewKit, comment: "Badge: the picture file holds a GPS position."),
                      detail: String(localized: "\(place) is stored in the file and goes with every copy of it.", bundle: .previewKit,
                                     comment: "Badge detail; the argument is the GPS coordinates, e.g. “30.2672° N, 97.7431° W”."))]
    }

    /// Every property the file stores, one per line, grouped: the Info view and the text copy and find use.
    static func infoText(_ info: ImageInfo, card: InfoCard) -> String {
        var lines = [card.title, card.sentence, ""]
        var group: String?
        for p in info.properties {
            if p.group != group {
                if group != nil || !p.group.isEmpty { lines.append("") }
                if !p.group.isEmpty { lines.append(p.group) }
                group = p.group
            }
            lines.append("\(p.key): \(p.value)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    /// Width × height in pixels, the digits without grouping ("6000 × 4000"), as pixel sizes are written.
    static func pixels(_ info: ImageInfo) -> String { "\(info.width) × \(info.height)" }

    /// The size with ", alpha" when the picture has transparency.
    static func sizeWithAlpha(_ info: ImageInfo) -> String {
        let size = pixels(info)
        return info.hasAlpha ? String(localized: "\(size), alpha", bundle: .previewKit, comment: "A picture's size when it has an alpha channel; e.g. “48 × 48, alpha”.") : size
    }

    /// "24 MP", "2.1 MP"; nil under half a megapixel, where the number says nothing.
    static func megapixels(_ info: ImageInfo) -> String? {
        let mp = info.megapixels
        guard mp >= 0.5 else { return nil }
        let number = mp >= 10 ? Int(mp.rounded()).formatted() : trim((mp * 10).rounded() / 10)
        return String(localized: "\(number) MP", bundle: .previewKit, comment: "Megapixels; e.g. “12 MP”, “2.1 MP”.")
    }

    /// The model, with the maker in front when the model does not already name it: "Canon EOS R5", "SONY ILCE-7M4".
    static func cameraName(_ info: ImageInfo) -> String? {
        guard let model = info.model else { return info.make }
        guard let make = info.make, let first = make.split(separator: " ").first?.lowercased(),
              !model.lowercased().contains(first) else { return model }
        return "\(make) \(model)"
    }

    static func cameraArticle(_ camera: String) -> String {
        guard let c = camera.lowercased().first else { return "a" }
        return "aeio".contains(c) ? "an" : "a"
    }

    /// "ƒ/2 · 1/250 s · ISO 200" (the strip's short form).
    static func exposureLine(_ info: ImageInfo) -> String? {
        let parts = [info.fNumber.map { "ƒ/\(trim($0))" }, info.exposureTime.map(shutter), info.iso.map(isoText)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "ISO 200": ISO is the standard's name, the same in every language.
    static func isoText(_ iso: Int) -> String { "ISO \(iso)" }

    /// "35 mm", "ƒ/2.0", "1/250 s", "ISO 200", "0 ev", "Flash off".
    static func exposureChips(_ info: ImageInfo) -> [String] {
        var chips: [String] = []
        if let f = info.focalLength {
            let length = f < 10 ? f.formatted(.number.precision(.fractionLength(1))) : Int(f.rounded()).formatted()
            chips.append(String(localized: "\(length) mm", bundle: .previewKit, comment: "A lens's focal length in millimetres; e.g. “35 mm”."))
        }
        if let eq = info.focalLength35, let f = info.focalLength, abs(Double(eq) - f) > 1 {
            let length = eq.formatted()
            chips.append(String(localized: "\(length) mm equiv.", bundle: .previewKit, comment: "The 35 mm-equivalent focal length; e.g. “26 mm equiv.”."))
        }
        if let n = info.fNumber { chips.append("ƒ/" + n.formatted(.number.precision(.fractionLength(1)))) }
        if let t = info.exposureTime { chips.append(shutter(t)) }
        if let iso = info.iso { chips.append(isoText(iso)) }
        if let bias = info.exposureBias {
            let r = (bias * 10).rounded() / 10
            let amount = r == 0 ? "0" : (r > 0 ? "+" : "−") + trim(abs(r))
            chips.append(String(localized: "\(amount) ev", bundle: .previewKit, comment: "Exposure compensation in stops; e.g. “+1 ev”, “−0.7 ev”."))
        }
        if let fired = info.flashFired {
            chips.append(fired ? String(localized: "Flash fired", bundle: .previewKit, comment: "Exposure chip: the flash fired.")
                               : String(localized: "Flash off", bundle: .previewKit, comment: "Exposure chip: the flash did not fire."))
        }
        return chips
    }

    static func shutter(_ t: Double) -> String {
        let time: String
        if t <= 0 { time = "0" }
        else if t >= 1 { time = trim((t * 10).rounded() / 10) }
        else { time = "1/\(Int((1 / t).rounded()))" }
        return String(localized: "\(time) s", bundle: .previewKit, comment: "A shutter speed in seconds; e.g. “1/250 s”, “2 s”.")
    }

    /// "300 dpi".
    static func dpiValue(_ dpi: Double) -> String {
        let value = dpiText(dpi)
        return String(localized: "\(value) dpi", bundle: .previewKit, comment: "A picture's resolution in dots per inch; e.g. “300 dpi”.")
    }

    /// The rows every picture shares: Dimensions, Resolution, Colour.
    static func imageRows(_ info: ImageInfo) -> [InfoCard.Row] {
        let size = sizeWithAlpha(info)
        let dimensions: String
        if let mp = megapixels(info) {
            let pixelsText = pixels(info)
            dimensions = info.hasAlpha
                ? String(localized: "\(pixelsText) · \(mp), alpha", bundle: .previewKit, comment: "A picture's size, megapixels and alpha channel; e.g. “6000 × 4000 · 24 MP, alpha”.")
                : String(localized: "\(pixelsText) · \(mp)", bundle: .previewKit, comment: "A picture's size and megapixels; e.g. “6000 × 4000 · 24 MP”.")
        } else {
            dimensions = size
        }
        var rows: [InfoCard.Row] = [.init(key: String(localized: "Dimensions", bundle: .previewKit, comment: "Image card row: width × height in pixels."), value: dimensions)]
        if let dpi = info.dpi {
            let resolution = dpiValue(dpi), wide = inches(info.width), high = inches(info.height)
            rows.append(.init(key: String(localized: "Resolution", bundle: .previewKit, comment: "Image card row: dots per inch and the print size."),
                              value: String(localized: "\(resolution) · prints \(wide) × \(high) in at 300 dpi", bundle: .previewKit,
                                            comment: "A picture's resolution and its print size in inches at 300 dpi; e.g. “72 dpi · prints 20 × 13 in at 300 dpi”.")))
        }
        if let colour = colour(info) {
            rows.append(.init(key: String(localized: "Colour", bundle: .previewKit, comment: "Image card row: colour profile and bit depth."), value: colour))
        }
        return rows
    }

    /// "Display P3 · 10-bit HDR", "sRGB IEC61966-2.1 · 8-bit", "Gray · 16-bit".
    static func colour(_ info: ImageInfo) -> String? {
        let name = info.profileName ?? info.colorModel
        let depth: String? = info.bitDepth.map { bits in
            info.isHDR ? String(localized: "\(bits)-bit HDR", bundle: .previewKit, comment: "Bit depth of an HDR picture; e.g. “10-bit HDR”.")
                       : String(localized: "\(bits)-bit", bundle: .previewKit, comment: "Bit depth of a picture; e.g. “8-bit”.")
        } ?? (info.isHDR ? "HDR" : nil)
        let parts = [name, depth].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func locationRows(_ location: ImageInfo.Location) -> [InfoCard.Row] {
        var rows = [InfoCard.Row(key: String(localized: "Coordinates", bundle: .previewKit, comment: "Image card row: the GPS latitude and longitude."),
                                 value: coordinates(location), flagged: true, number: 1)]
        if let altitude = location.altitude {
            let metres = Int(altitude.rounded()).formatted()
            rows.append(.init(key: String(localized: "Altitude", bundle: .previewKit, comment: "Image card row: metres above sea level."),
                              value: String(localized: "\(metres) m", bundle: .previewKit, comment: "An altitude in metres; e.g. “58 m”.")))
        }
        return rows
    }

    /// "30.2672° N, 97.7431° W": four decimals, about 11 m, as the file gives it. Kept in this one fixed form in every
    /// language (point decimals, N/S/E/W), because Copy coordinates puts it on the clipboard for maps and other apps.
    static func coordinates(_ l: ImageInfo.Location) -> String {
        String(format: "%.4f° %@, %.4f° %@", abs(l.latitude), l.latitude < 0 ? "S" : "N", abs(l.longitude), l.longitude < 0 ? "W" : "E")
    }

    /// "Sunday 11 October at 17:42", the year added when it is not this year's. The camera's clock has no time zone,
    /// so the date is read and written in UTC to keep it as the camera wrote it.
    static func takenPhrase(_ exif: String, locale: Locale, now: Date) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: String(exif.prefix(19))) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sameYear = calendar.component(.year, from: date) == Calendar.current.component(.year, from: now)
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEdMMMM" : "EEEEdMMMMyyyy")
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jjmm")
        let dayText = day.string(from: date), timeText = time.string(from: date)
        return String(localized: "\(dayText) at \(timeText)", bundle: .previewKit,
                      comment: "When a photo was taken: a localized date, then a localized time; e.g. “Sunday 11 October at 17:42”.")
    }

    /// "2 seconds", "1.5 seconds", "1 second".
    static func seconds(_ s: Double) -> String {
        let r = (s * 10).rounded() / 10
        if r == 1 { return String(localized: "1 second", bundle: .previewKit, comment: "An animation's length of exactly one second.") }
        let value = trim(r)
        return String(localized: "\(value) seconds", bundle: .previewKit, comment: "An animation's length; e.g. “0.4 seconds”, “2 seconds”.")
    }

    /// The average frame rate: "24 frames a second" / "24 fps".
    static func rate(_ a: ImageInfo.Animation) -> (words: String, short: String)? {
        guard a.duration > 0 else { return nil }
        let fps = Double(a.delays.count) / a.duration
        let rounded = fps >= 10 ? fps.rounded() : (fps * 10).rounded() / 10
        let text = trim(rounded)
        let words = rounded == 1
            ? String(localized: "1 frame a second", bundle: .previewKit, comment: "An animation's frame rate of exactly one frame a second.")
            : String(localized: "\(text) frames a second", bundle: .previewKit, comment: "An animation's frame rate in words; e.g. “24 frames a second”.")
        return (words, String(localized: "\(text) fps", bundle: .previewKit, comment: "An animation's frame rate, short; e.g. “24 fps”."))
    }

    static func loopPhrase(_ loops: Int?) -> String {
        switch loops {
        case 0?: return String(localized: "looping forever", bundle: .previewKit, comment: "End of an animation's sentence: it repeats without end.")
        case nil, 1?: return String(localized: "playing once", bundle: .previewKit, comment: "End of an animation's sentence: it plays one time.")
        case let n?:
            let count = n.formatted()
            return String(localized: "playing \(count) times", bundle: .previewKit, comment: "End of an animation's sentence; e.g. “playing 3 times”.")
        }
    }

    static func loopsValue(_ loops: Int?) -> String {
        switch loops {
        case 0?: return String(localized: "forever", bundle: .previewKit, comment: "Image card value: the animation repeats without end.")
        case nil, 1?: return String(localized: "once", bundle: .previewKit, comment: "Image card value: the animation plays one time.")
        case let n?:
            let count = n.formatted()
            return String(localized: "\(count) times", bundle: .previewKit, comment: "Image card value: how many times the animation plays; e.g. “3 times”.")
        }
    }

    static func dpiText(_ dpi: Double) -> String { trim((dpi * 10).rounded() / 10) }

    /// Print size at 300 dpi: whole inches from 10 up, one decimal under.
    static func inches(_ pixels: Int) -> String {
        let i = Double(pixels) / 300
        return i >= 10 ? trim(i.rounded()) : trim((i * 10).rounded() / 10)
    }

    /// 2.0 → "2", 2.5 → "2.5" (in the reader's own decimal separator, "2,5" in German).
    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : v.formatted(.number.precision(.significantDigits(1...6)).grouping(.never))
    }
}
