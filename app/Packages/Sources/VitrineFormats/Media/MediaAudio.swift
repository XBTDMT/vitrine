import Foundation

/// The tags an audio file carries, merged across the tag formats it has (ID3v2 wins over ID3v1). roadmap: S-23
public struct MediaAudioTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var year: String?
    public var track: Int?
    public var trackTotal: Int?
    public var disc: Int?
    public var discTotal: Int?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    /// The file carries lyrics (USLT, ©lyr, LYRICS); their text is not kept.
    public var hasLyrics: Bool

    public init() { hasLyrics = false }

    public var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil && year == nil && track == nil
            && disc == nil && genre == nil && composer == nil && comment == nil && !hasLyrics
    }
}

/// What the audio stream is, when the container states it cheaply. roadmap: S-23
public struct MediaAudioStream: Sendable, Equatable {
    public var durationSeconds: Double?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitsPerSample: Int?
    /// "MP3", "AAC", "Apple Lossless", "FLAC", "Vorbis", "Opus", "PCM" …
    public var codec: String?
    /// Average bits per second.
    public var bitrate: Int?

    public init() {}
}

/// An audio file's tags and stream facts (N-8): MP3 (ID3v1, ID3v2.2–2.4), MP4/M4A, FLAC, Ogg Vorbis and Opus,
/// WAV. The waveform is drawn elsewhere (AVFoundation). roadmap: S-23
public struct MediaAudioSummary: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// "MP3", "MP4", "FLAC", "Ogg Vorbis", "Opus" or "WAV".
    public var format: String
    /// The tag formats found ("ID3v2.4", "ID3v1", "iTunes", "Vorbis comments", "RIFF INFO").
    public var tagFormats: [String]
    public var tags: MediaAudioTags
    public var stream: MediaAudioStream
    /// Cover art, when it is at most 2 MB.
    public var cover: MediaPicture?
    /// Why the cover art is not included.
    public var coverNote: String?
    public var truncated: Bool
}

enum MediaAudioReader {
    static func read(_ data: Data, fileName: String, format: MediaFormat) -> MediaAudioSummary? {
        var s = MediaAudioSummary(headline: MediaPath.base(fileName), facts: [], warnings: [], format: "",
                                  tagFormats: [], tags: MediaAudioTags(), stream: MediaAudioStream(), cover: nil,
                                  coverNote: nil, truncated: false)
        var tags = MediaTagSet()
        let b = MediaBytes(data)
        // A tag-only sniff decides when the extension is generic (an .mp4 or .ogg with another payload).
        var effective = format
        if b.matches("fLaC", at: 0) { effective = .flac }
        else if b.matches("OggS", at: 0) { effective = .ogg }
        else if (b.matches("RIFF", at: 0) || b.matches("RF64", at: 0)) && b.matches("WAVE", at: 8) { effective = .wav }
        else if b.matches("ftyp", at: 4) { effective = .mp4Audio }
        else if b.matches("ID3", at: 0) {
            let size = MediaID3.tagSize(b) ?? 0
            if b.matches("fLaC", at: size) { effective = .flac } else if effective != .mp3 && effective != .mp4Audio { effective = .mp3 }
        }

        switch effective {
        case .mp3: readMP3(b, into: &s, tags: &tags)
        case .mp4Audio: readMP4(b, into: &s, tags: &tags)
        case .flac: readFLAC(b, into: &s, tags: &tags)
        case .ogg: readOgg(b, into: &s, tags: &tags)
        case .wav: readWAV(b, into: &s, tags: &tags)
        default: return nil
        }
        if s.format.isEmpty { return nil }

        s.tags = tags.tags
        if let (picture, size) = tags.cover {
            if let picture { s.cover = picture } else {
                s.coverNote = String(localized: "The cover art is \(MediaText.bytesString(size)), over the \(MediaText.bytesString(MediaLimits.maxAudioCoverBytes)) shown in previews.", bundle: .module, comment: "Audio card note. The arguments are sizes.")
            }
        }
        if s.stream.bitrate == nil, let d = s.stream.durationSeconds, d > 0 {
            s.stream.bitrate = FormatMath.int(Double(data.count) * 8 / d)   // nil for a duration too short to divide by
        }
        s.truncated = s.truncated || tags.truncated

        let t = s.tags
        if let title = t.title {
            s.headline = t.artist.map { "\(title) — \($0)" } ?? title
        }
        var facts: [MediaFact] = []
        if let v = t.artist { facts.append(MediaFact(String(localized: "Artist", bundle: .module, comment: "Audio card fact label."), v)) }
        if let v = t.album { facts.append(MediaFact(String(localized: "Album", bundle: .module, comment: "Audio card fact label."), v)) }
        if let v = t.albumArtist, v != t.artist { facts.append(MediaFact(String(localized: "Album artist", bundle: .module, comment: "Audio card fact label."), v)) }
        if let v = t.year { facts.append(MediaFact(String(localized: "Year", bundle: .module, comment: "Audio card fact label."), v)) }
        if let n = t.track { facts.append(MediaFact(String(localized: "Track", bundle: .module, comment: "Audio card fact label."), t.trackTotal.map { String(localized: "\(n) of \($0)", bundle: .module, comment: "Audio card: track or disc number of a total.") } ?? "\(n)")) }
        if let n = t.disc { facts.append(MediaFact(String(localized: "Disc", bundle: .module, comment: "Audio card fact label."), t.discTotal.map { String(localized: "\(n) of \($0)", bundle: .module, comment: "Audio card: track or disc number of a total.") } ?? "\(n)")) }
        if let v = t.genre { facts.append(MediaFact(String(localized: "Genre", bundle: .module, comment: "Audio card fact label."), v)) }
        if let v = t.composer { facts.append(MediaFact(String(localized: "Composer", bundle: .module, comment: "Audio card fact label."), v)) }
        if let d = s.stream.durationSeconds { facts.append(MediaFact(String(localized: "Duration", bundle: .module, comment: "Audio card fact label."), MediaText.duration(d))) }
        if let c = s.stream.codec { facts.append(MediaFact(String(localized: "Codec", bundle: .module, comment: "Audio card fact label."), c)) }
        if let r = s.stream.sampleRate { facts.append(MediaFact(String(localized: "Sample rate", bundle: .module, comment: "Audio card fact label."), "\(MediaText.number(Double(r) / 1000, digits: 1)) kHz")) }
        if let c = s.stream.channels { facts.append(MediaFact(String(localized: "Channels", bundle: .module, comment: "Audio card fact label."), c == 1 ? String(localized: "Mono", bundle: .module, comment: "Audio channel layout.") : c == 2 ? String(localized: "Stereo", bundle: .module, comment: "Audio channel layout.") : "\(c)")) }
        if let bits = s.stream.bitsPerSample { facts.append(MediaFact(String(localized: "Bit depth", bundle: .module, comment: "Audio card fact label."), "\(bits)-bit")) }
        if let br = s.stream.bitrate { facts.append(MediaFact(String(localized: "Bitrate", bundle: .module, comment: "Audio card fact label."), "\(br / 1000) kbps")) }
        if t.hasLyrics { facts.append(MediaFact(String(localized: "Lyrics", bundle: .module, comment: "Audio card fact label."), String(localized: "Included", bundle: .module, comment: "Audio card fact: the file has lyrics."))) }
        if !s.tagFormats.isEmpty { facts.append(MediaFact(String(localized: "Tags", bundle: .module, comment: "Audio card fact label."), s.tagFormats.joined(separator: ", "))) }
        s.facts = facts + s.facts
        return s
    }

    // MARK: MP3

    static func readMP3(_ b: MediaBytes, into s: inout MediaAudioSummary, tags: inout MediaTagSet) {
        s.format = "MP3"
        var audioStart = 0
        if let id3 = MediaID3.parseV2(b, at: 0, tags: &tags) {
            s.tagFormats.append(id3.version)
            s.warnings += id3.warnings
            audioStart = id3.end
        }
        var audioEnd = b.count
        if MediaID3.parseV1(b, tags: &tags) {
            s.tagFormats.append("ID3v1")
            audioEnd -= 128
        }
        if let info = MediaMPEG.scan(b, from: audioStart, to: audioEnd) {
            s.stream = info
        } else if b.count > 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "No MPEG audio frames were found; the file may be damaged or not an MP3.", bundle: .module, comment: "Audio card warning.")))
        }
    }

    // MARK: MP4

    static func readMP4(_ b: MediaBytes, into s: inout MediaAudioSummary, tags: inout MediaTagSet) {
        var walker = MediaMP4Walker(b: b)
        walker.walk(0, b.count, depth: 0, path: [])
        guard walker.sawFtypOrMoov else {
            if b.matches("ID3", at: 0) { readMP3(b, into: &s, tags: &tags); return }
            s.format = "MP4"
            s.warnings.append(MediaWarning(.danger, String(localized: "This is not an MP4 file: no ftyp or moov atom was found.", bundle: .module, comment: "Audio card warning.")))
            return
        }
        s.format = "MP4"
        if walker.timescale > 0, walker.duration > 0 {
            s.stream.durationSeconds = Double(walker.duration) / Double(walker.timescale)
        }
        s.stream.codec = walker.codec
        s.stream.channels = walker.channels
        s.stream.sampleRate = walker.sampleRate
        s.stream.bitsPerSample = walker.codec == "Apple Lossless" ? walker.sampleSize : nil
        for (key, value) in walker.items { tags.apply(mp4: key, value) }
        if let pic = walker.cover { tags.offerCover(pic, size: walker.coverSize) }
        if walker.coverSize > 0, walker.cover == nil { tags.offerCover(nil, size: walker.coverSize) }
        if walker.hasLyrics { tags.tags.hasLyrics = true }
        if walker.sawIlst { s.tagFormats.append("iTunes") }
        if walker.hasVideo { s.facts.append(MediaFact(String(localized: "Video", bundle: .module, comment: "Audio card fact label."), String(localized: "Yes (this file also holds video)", bundle: .module, comment: "Audio card fact value."))) }
        if walker.compressedMovie {
            s.warnings.append(MediaWarning(.caution, String(localized: "The movie header is compressed (cmov); its tags cannot be read.", bundle: .module, comment: "Audio card warning.")))
        }
        if walker.truncated {
            s.truncated = true
            s.warnings.append(MediaWarning(.danger, String(localized: "The file is cut short: an atom runs past its end.", bundle: .module, comment: "Audio card warning.")))
        }
    }

    // MARK: FLAC

    static func readFLAC(_ b: MediaBytes, into s: inout MediaAudioSummary, tags: inout MediaTagSet) {
        s.format = "FLAC"
        var offset = 0
        if let id3 = MediaID3.parseV2(b, at: 0, tags: &tags) {
            s.tagFormats.append(id3.version)
            offset = id3.end
        }
        guard b.matches("fLaC", at: offset) else {
            s.warnings.append(MediaWarning(.danger, String(localized: "This is not a FLAC file: the \"fLaC\" marker is missing.", bundle: .module, comment: "Audio card warning.")))
            return
        }
        offset += 4
        var blocks = 0
        while blocks < 1_000 {
            guard let header = b.u8(offset), let length = b.be24(offset + 1).map(Int.init) else {
                s.warnings.append(MediaWarning(.danger, String(localized: "The file is cut short inside its metadata.", bundle: .module, comment: "Audio card warning.")))
                s.truncated = true
                break
            }
            blocks += 1
            let body = offset + 4
            let type = header & 0x7F
            if body + length > b.count {
                s.warnings.append(MediaWarning(.danger, String(localized: "The file is cut short inside a metadata block.", bundle: .module, comment: "Audio card warning.")))
                s.truncated = true
                break
            }
            switch type {
            case 0 where length >= 18:
                let bytes = b.bytes(body, 18)
                let rate = Int(bytes[10]) << 12 | Int(bytes[11]) << 4 | Int(bytes[12]) >> 4
                let channels = Int((bytes[12] >> 1) & 7) + 1
                let bits = Int((bytes[12] & 1) << 4 | bytes[13] >> 4) + 1
                let total = UInt64(bytes[13] & 0x0F) << 32 | UInt64(bytes[14]) << 24 | UInt64(bytes[15]) << 16 | UInt64(bytes[16]) << 8 | UInt64(bytes[17])
                s.stream.codec = "FLAC"
                s.stream.sampleRate = rate > 0 ? rate : nil
                s.stream.channels = channels
                s.stream.bitsPerSample = bits
                if rate > 0, total > 0 { s.stream.durationSeconds = Double(total) / Double(rate) }
            case 4:
                if MediaVorbisComment.parse(b.bytes(body, length), tags: &tags) { s.tagFormats.append("Vorbis comments") }
            case 6:
                if let (pic, size) = MediaFLACPicture.parse(b.bytes(body, length)) { tags.offerCover(pic, size: size) }
            default: break
            }
            offset = body + length
            if header & 0x80 != 0 { break }
        }
    }

    // MARK: Ogg

    static func readOgg(_ b: MediaBytes, into s: inout MediaAudioSummary, tags: inout MediaTagSet) {
        var offset = 0
        var serial: UInt32?
        var packets: [[UInt8]] = []
        var current: [UInt8] = []
        var pages = 0
        let maxPacket = 16 * 1024 * 1024
        while packets.count < 2, pages < 100_000, offset + 27 <= b.count {
            guard b.matches("OggS", at: offset), let segments = b.u8(offset + 26).map(Int.init),
                  let pageSerial = b.le32(offset + 14) else { break }
            pages += 1
            let lacing = b.bytes(offset + 27, segments)
            guard lacing.count == segments else { s.truncated = true; break }
            var body = offset + 27 + segments
            let next = body + lacing.reduce(0) { $0 + Int($1) }
            if serial == nil { serial = pageSerial }
            if pageSerial == serial {
                for lace in lacing {
                    if current.count + Int(lace) > maxPacket { s.truncated = true; current = []; packets.append([]); break }
                    current += b.bytes(body, Int(lace))
                    body += Int(lace)
                    if lace < 255 { packets.append(current); current = []; if packets.count >= 2 { break } }
                }
            }
            if next > b.count { s.truncated = true }
            offset = next
        }
        guard let first = packets.first, !first.isEmpty else {
            s.format = "Ogg"
            s.warnings.append(MediaWarning(.danger, String(localized: "This Ogg file has no readable stream header.", bundle: .module, comment: "Audio card warning.")))
            return
        }
        var preSkip = 0
        var rate = 0
        if first.count >= 16, first[0] == 1, MediaText.latin1(first[1..<7]) == "vorbis" {
            s.format = "Ogg Vorbis"
            s.stream.codec = "Vorbis"
            s.stream.channels = Int(first[11])
            rate = Int(first.mediaLE32(12) ?? 0)
            if let nominal = first.mediaLE32(20), nominal > 0, nominal < 10_000_000 { s.stream.bitrate = Int(nominal) }
        } else if first.count >= 19, MediaText.latin1(first[0..<8]) == "OpusHead" {
            s.format = "Opus"
            s.stream.codec = "Opus"
            s.stream.channels = Int(first[9])
            preSkip = Int(first[10]) | Int(first[11]) << 8
            rate = 48_000
            if let input = first.mediaLE32(12), input > 0 { s.facts.append(MediaFact(String(localized: "Original rate", bundle: .module, comment: "Audio card fact label."), "\(MediaText.number(Double(input) / 1000)) kHz")) }
        } else if first.count >= 5, first[0] == 0x7F, MediaText.latin1(first[1..<5]) == "FLAC" {
            s.format = "Ogg FLAC"
            s.stream.codec = "FLAC"
        } else {
            s.format = "Ogg"
            s.warnings.append(MediaWarning(.caution, String(localized: "This Ogg stream is not Vorbis or Opus; only its container was read.", bundle: .module, comment: "Audio card warning.")))
        }
        if rate > 0 { s.stream.sampleRate = rate }
        if packets.count >= 2 {
            let second = packets[1]
            var comment: [UInt8]?
            if second.count >= 7, second[0] == 3, MediaText.latin1(second[1..<7]) == "vorbis" { comment = Array(second[7...]) }
            if second.count >= 8, MediaText.latin1(second[0..<8]) == "OpusTags" { comment = Array(second[8...]) }
            if let comment, MediaVorbisComment.parse(comment, tags: &tags) { s.tagFormats.append("Vorbis comments") }
        }
        // Duration: the granule position of the stream's last page, found from the end.
        if rate > 0, let serial {
            let windowStart = max(0, b.count - 256 * 1024)
            var position = b.count - 27
            while position >= windowStart {
                if b.u8(position) == 0x4F, b.matches("OggS", at: position), b.le32(position + 14) == serial,
                   let granule = b.le64(position + 6), granule != UInt64.max {
                    let samples = Double(granule) - Double(preSkip)
                    if samples > 0 { s.stream.durationSeconds = samples / Double(rate) }
                    break
                }
                position -= 1
            }
        }
    }

    // MARK: WAV

    static func readWAV(_ b: MediaBytes, into s: inout MediaAudioSummary, tags: inout MediaTagSet) {
        s.format = "WAV"
        let rf64 = b.matches("RF64", at: 0)
        var offset = 12
        var byteRate = 0
        var dataSize: UInt64?
        var ds64Data: UInt64?
        var chunks = 0
        var sawFmt = false
        while offset + 8 <= b.count, chunks < 10_000 {
            chunks += 1
            guard let id = b.fourCC(offset), let size32 = b.le32(offset + 4) else { break }
            let body = offset + 8
            let size = Int(size32)
            switch id {
            case "ds64":
                ds64Data = b.le64(body + 8)
            case "fmt ":
                sawFmt = true
                guard let tag = b.le16(body), let ch = b.le16(body + 2), let rate = b.le32(body + 4),
                      let br = b.le32(body + 8), let bits = b.le16(body + 14) else { break }
                var format = tag
                if tag == 0xFFFE, size >= 40, let sub = b.le16(body + 24) { format = sub }
                s.stream.codec = waveCodec(format)
                s.stream.channels = Int(ch)
                s.stream.sampleRate = Int(rate)
                s.stream.bitsPerSample = bits > 0 ? Int(bits) : nil
                byteRate = Int(br)
                if br > 0 { s.stream.bitrate = Int(br) * 8 }
            case "data":
                dataSize = (rf64 && size32 == 0xFFFF_FFFF) ? ds64Data : UInt64(size32)
                // Compared as `d > count - body`: an RF64 ds64 size near UInt64.max would overflow `body + d`.
                if let d = dataSize, UInt64(body) > UInt64(b.count) || d > UInt64(b.count) - UInt64(body) {
                    s.warnings.append(MediaWarning(.caution, String(localized: "The file is cut short: the audio data declares more bytes than the file holds.", bundle: .module, comment: "Audio card warning.")))
                    s.truncated = true
                }
            case "LIST":
                if b.matches("INFO", at: body) {
                    var p = body + 4
                    let end = min(b.count, body + size)
                    var found = false
                    while p + 8 <= end {
                        guard let sub = b.fourCC(p), let len = b.le32(p + 4).map(Int.init) else { break }
                        let raw = b.bytes(p + 8, min(len, 64 * 1024))
                        let value = MediaText.clean(String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self))
                        if let value { found = true; tags.apply(riff: sub, value) }
                        p += 8 + len + (len & 1)
                    }
                    if found { s.tagFormats.append("RIFF INFO") }
                }
            case "id3 ", "ID3 ":
                let inner = MediaBytes(b.sub(body, size))
                if let id3 = MediaID3.parseV2(inner, at: 0, tags: &tags) { s.tagFormats.append(id3.version) }
            default: break
            }
            if id == "data", let d = dataSize, d > UInt64(Int.max / 2) { break }
            let advance = id == "data" ? Int(min(dataSize ?? UInt64(size), UInt64(b.count))) : size
            offset = body + advance + (advance & 1)
        }
        if !sawFmt {
            s.warnings.append(MediaWarning(.danger, String(localized: "The WAV file has no format chunk; it may be damaged.", bundle: .module, comment: "Audio card warning.")))
        }
        if let d = dataSize, byteRate > 0 {
            s.stream.durationSeconds = Double(d) / Double(byteRate)
        }
    }

    static func waveCodec(_ tag: UInt16) -> String {
        switch tag {
        case 1: "PCM"
        case 2: "Microsoft ADPCM"
        case 3: "PCM (float)"
        case 6: "A-law"
        case 7: "µ-law"
        case 0x11: "IMA ADPCM"
        case 0x55: "MP3"
        case 0x2000: "AC-3"
        default: String(format: "Format 0x%04X", tag)
        }
    }
}

// MARK: - Tag set

/// Gathers tags from any format through each format's keys, keeping the first value for each field.
struct MediaTagSet {
    var tags = MediaAudioTags()
    /// The chosen cover (nil picture when it was too large) and its size.
    var cover: (MediaPicture?, Int)?
    var coverIsFront = false
    var truncated = false

    mutating func set(_ field: WritableKeyPath<MediaAudioTags, String?>, _ value: String?) {
        guard tags[keyPath: field] == nil, let v = MediaText.clean(value) else { return }
        tags[keyPath: field] = v
    }

    /// "3/12" or "3".
    mutating func setNumber(_ number: WritableKeyPath<MediaAudioTags, Int?>, _ total: WritableKeyPath<MediaAudioTags, Int?>, _ value: String?) {
        guard let value else { return }
        let parts = value.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if tags[keyPath: number] == nil, let n = parts.first ?? nil, n > 0 { tags[keyPath: number] = n }
        if tags[keyPath: total] == nil, parts.count > 1, let t = parts[1], t > 0 { tags[keyPath: total] = t }
    }

    /// Prefers a front cover over any other picture; a picture over the 2 MB cap is noted without its bytes.
    mutating func offerCover(_ picture: MediaPicture?, size: Int) {
        let front = picture?.pictureType == "Front cover"
        if cover != nil, coverIsFront || !front { return }
        coverIsFront = front
        if let picture, picture.data.count <= MediaLimits.maxAudioCoverBytes { cover = (picture, picture.data.count) }
        else { cover = (nil, size) }
    }

    mutating func apply(vorbis key: String, _ value: String) {
        switch key.uppercased() {
        case "TITLE": set(\.title, value)
        case "ARTIST": set(\.artist, value)
        case "ALBUM": set(\.album, value)
        case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": set(\.albumArtist, value)
        case "DATE", "YEAR", "ORIGINALDATE": set(\.year, value)
        case "TRACKNUMBER": setNumber(\.track, \.trackTotal, value)
        case "TRACKTOTAL", "TOTALTRACKS": if tags.trackTotal == nil { tags.trackTotal = Int(value) }
        case "DISCNUMBER": setNumber(\.disc, \.discTotal, value)
        case "DISCTOTAL", "TOTALDISCS": if tags.discTotal == nil { tags.discTotal = Int(value) }
        case "GENRE": set(\.genre, value)
        case "COMPOSER": set(\.composer, value)
        case "COMMENT", "DESCRIPTION": set(\.comment, value)
        case "LYRICS", "UNSYNCEDLYRICS": tags.hasLyrics = true
        default: break
        }
    }

    mutating func apply(mp4 key: String, _ value: MediaMP4Value) {
        switch (key, value) {
        case ("©nam", .text(let v)): set(\.title, v)
        case ("©ART", .text(let v)): set(\.artist, v)
        case ("©alb", .text(let v)): set(\.album, v)
        case ("aART", .text(let v)): set(\.albumArtist, v)
        case ("©day", .text(let v)): set(\.year, v)
        case ("©gen", .text(let v)): set(\.genre, v)
        case ("©wrt", .text(let v)): set(\.composer, v)
        case ("©cmt", .text(let v)): set(\.comment, v)
        case ("gnre", .binary(let bytes)) where bytes.count >= 2:
            let index = Int(bytes[0]) << 8 | Int(bytes[1])
            if index > 0 { set(\.genre, MediaID3.genre(index - 1)) }
        case ("trkn", .binary(let bytes)) where bytes.count >= 6:
            let n = Int(bytes[2]) << 8 | Int(bytes[3]), t = Int(bytes[4]) << 8 | Int(bytes[5])
            if n > 0, tags.track == nil { tags.track = n }
            if t > 0, tags.trackTotal == nil { tags.trackTotal = t }
        case ("disk", .binary(let bytes)) where bytes.count >= 6:
            let n = Int(bytes[2]) << 8 | Int(bytes[3]), t = Int(bytes[4]) << 8 | Int(bytes[5])
            if n > 0, tags.disc == nil { tags.disc = n }
            if t > 0, tags.discTotal == nil { tags.discTotal = t }
        default: break
        }
    }

    mutating func apply(riff key: String, _ value: String) {
        switch key {
        case "INAM": set(\.title, value)
        case "IART": set(\.artist, value)
        case "IPRD": set(\.album, value)
        case "ICRD": set(\.year, value)
        case "IGNR": set(\.genre, value)
        case "ICMT": set(\.comment, value)
        case "IMUS", "ICMS": set(\.composer, value)
        case "ITRK", "IPRT", "TRCK": setNumber(\.track, \.trackTotal, value)
        default: break
        }
    }
}

// MARK: - ID3

enum MediaID3 {
    struct Result { var version: String; var end: Int; var warnings: [MediaWarning] }

    static func syncsafe(_ b: MediaBytes, _ o: Int) -> Int? {
        let bytes = b.bytes(o, 4)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }

    /// The whole tag's length, header included.
    static func tagSize(_ b: MediaBytes) -> Int? {
        guard b.matches("ID3", at: 0), let size = syncsafe(b, 6) else { return nil }
        let footer = (b.u8(5) ?? 0) & 0x10 != 0 ? 10 : 0
        return 10 + size + footer
    }

    static func parseV2(_ b: MediaBytes, at start: Int, tags: inout MediaTagSet) -> Result? {
        guard b.matches("ID3", at: start), let major = b.u8(start + 3), let flags = b.u8(start + 5),
              let size = syncsafe(b, start + 6) else { return nil }
        let footer = flags & 0x10 != 0 ? 10 : 0
        var result = Result(version: "ID3v2.\(major)", end: start + 10 + size + footer, warnings: [])
        guard (2...4).contains(major) else {
            result.warnings.append(MediaWarning(.caution, String(localized: "The ID3 tag is version 2.\(major), which is not read.", bundle: .module, comment: "Audio card warning. Arguments are filled in at run time.")))
            return result
        }
        var body = b.bytes(start + 10, size)
        if body.count < size {
            result.warnings.append(MediaWarning(.danger, String(localized: "The file is cut short inside its ID3 tag.", bundle: .module, comment: "Audio card warning.")))
            tags.truncated = true
        }
        if flags & 0x80 != 0, major < 4 { body = unsynchronise(body) }
        var offset = 0
        if flags & 0x40 != 0 {
            if major == 3, let ext = body.mediaBE32(0) { offset = 4 + Int(ext) }
            if major == 4, body.count >= 4 { offset = body[0..<4].reduce(0) { $0 << 7 | Int($1 & 0x7F) } }
        }
        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10
        var frames = 0
        while offset + headerLength <= body.count, frames < 10_000 {
            frames += 1
            let idBytes = Array(body[offset..<(offset + idLength)])
            guard idBytes.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) }) else { break }   // padding
            let id = MediaText.latin1(idBytes)
            var frameSize: Int
            var formatFlags: UInt8 = 0
            if major == 2 {
                frameSize = Int(body[offset + 3]) << 16 | Int(body[offset + 4]) << 8 | Int(body[offset + 5])
            } else {
                let raw = Array(body[(offset + 4)..<(offset + 8)])
                if major == 4, raw.allSatisfy({ $0 < 0x80 }) {
                    frameSize = raw.reduce(0) { $0 << 7 | Int($1) }
                } else {
                    frameSize = raw.reduce(0) { $0 << 8 | Int($1) }
                }
                formatFlags = body[offset + 9]
            }
            let dataStart = offset + headerLength
            guard frameSize >= 0, dataStart + frameSize <= body.count else {
                result.warnings.append(MediaWarning(.danger, String(localized: "An ID3 frame (\(id)) runs past the end of the tag.", bundle: .module, comment: "Audio card warning. Arguments are filled in at run time.")))
                tags.truncated = true
                break
            }
            var frame = Array(body[dataStart..<(dataStart + frameSize)])
            offset = dataStart + frameSize
            // Compressed or encrypted frames are skipped; grouping and length-indicator bytes are dropped.
            if major == 3 {
                if formatFlags & 0xC0 != 0 { continue }
                if formatFlags & 0x20 != 0 { frame = Array(frame.dropFirst(1)) }
            } else if major == 4 {
                if formatFlags & 0x0C != 0 { continue }
                if formatFlags & 0x40 != 0 { frame = Array(frame.dropFirst(1)) }
                if formatFlags & 0x01 != 0 { frame = Array(frame.dropFirst(4)) }
                if formatFlags & 0x02 != 0 || flags & 0x80 != 0 { frame = unsynchronise(frame) }
            }
            apply(id, frame, major: major, tags: &tags)
        }
        return result
    }

    static func unsynchronise(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 { i += 1 }
            i += 1
        }
        return out
    }

    static func decode(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> String {
        let a = Array(bytes)
        switch encoding {
        case 1: return MediaText.utf16(a, littleEndianDefault: true)
        case 2: return MediaText.utf16(a, littleEndianDefault: false)
        case 3: return MediaText.utf8(a)
        default: return MediaText.latin1(a)
        }
    }

    /// The end of a terminated string starting at `from` (index of the terminator) and where the next field starts.
    static func terminated(_ f: [UInt8], from: Int, encoding: UInt8) -> (Int, Int) {
        if encoding == 1 || encoding == 2 {
            var i = from
            while i + 1 < f.count {
                if f[i] == 0, f[i + 1] == 0 { return (i, i + 2) }
                i += 2
            }
            return (f.count, f.count)
        }
        var i = from
        while i < f.count, f[i] != 0 { i += 1 }
        return (i, min(f.count, i + 1))
    }

    static func text(_ f: [UInt8]) -> String? {
        guard let enc = f.first else { return nil }
        let s = decode(f[1...], encoding: enc)
        let parts = s.split(separator: "\u{0}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func apply(_ id: String, _ f: [UInt8], major: UInt8, tags: inout MediaTagSet) {
        switch id {
        case "TIT2", "TT2": tags.set(\.title, text(f))
        case "TPE1", "TP1": tags.set(\.artist, text(f))
        case "TALB", "TAL": tags.set(\.album, text(f))
        case "TPE2", "TP2": tags.set(\.albumArtist, text(f))
        case "TYER", "TYE", "TDRC", "TDOR", "TORY": tags.set(\.year, text(f))
        case "TRCK", "TRK": tags.setNumber(\.track, \.trackTotal, text(f))
        case "TPOS", "TPA": tags.setNumber(\.disc, \.discTotal, text(f))
        case "TCON", "TCO": tags.set(\.genre, text(f).map(genreName))
        case "TCOM", "TCM": tags.set(\.composer, text(f))
        case "USLT", "ULT", "SYLT", "SLT": tags.tags.hasLyrics = true
        case "COMM", "COM":
            guard f.count > 4 else { return }
            let enc = f[0]
            let (descEnd, textStart) = terminated(f, from: 4, encoding: enc)
            let desc = decode(f[4..<descEnd], encoding: enc)
            guard !desc.hasPrefix("iTun") else { return }                 // iTunes' own normalisation data
            tags.set(\.comment, decode(f[textStart...], encoding: enc))
        case "APIC":
            guard f.count > 4 else { return }
            let enc = f[0]
            var i = 1
            while i < f.count, f[i] != 0 { i += 1 }
            let mime = MediaText.latin1(f[1..<min(i, f.count)])
            guard i + 2 <= f.count else { return }
            let type = f[i + 1]
            let (descEnd, dataStart) = terminated(f, from: i + 2, encoding: enc)
            let desc = MediaText.clean(decode(f[(i + 2)..<descEnd], encoding: enc), max: 200)
            let bytes = Data(f[dataStart...])
            let resolvedMime = mime.contains("/") ? mime : (MediaPath.sniffImageMime(bytes) ?? "image/\(mime.lowercased())")
            tags.offerCover(MediaPicture(data: bytes, mimeType: resolvedMime, pictureType: MediaFLACPicture.typeName(Int(type)), description: desc),
                            size: bytes.count)
        case "PIC":
            guard f.count > 5 else { return }
            let enc = f[0]
            let format = MediaText.latin1(f[1..<4]).uppercased()
            let type = f[4]
            let (descEnd, dataStart) = terminated(f, from: 5, encoding: enc)
            let desc = MediaText.clean(decode(f[5..<descEnd], encoding: enc), max: 200)
            let bytes = Data(f[dataStart...])
            tags.offerCover(MediaPicture(data: bytes, mimeType: format == "PNG" ? "image/png" : "image/jpeg",
                                         pictureType: MediaFLACPicture.typeName(Int(type)), description: desc),
                            size: bytes.count)
        default: break
        }
    }

    /// "(17)", "17", "(17)Rock" or a plain name.
    static func genreName(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("("), let close = s.firstIndex(of: ")"), let n = Int(s[s.index(after: s.startIndex)..<close]) {
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? (genre(n) ?? s) : rest
        }
        if let n = Int(s.trimmingCharacters(in: .whitespaces)) { s = genre(n) ?? s }
        return s
    }

    static func parseV1(_ b: MediaBytes, tags: inout MediaTagSet) -> Bool {
        let start = b.count - 128
        guard start >= 0, b.matches("TAG", at: start) else { return false }
        let raw = b.bytes(start, 128)
        func field(_ o: Int, _ n: Int) -> String? {
            MediaText.clean(MediaText.latin1(raw[o..<(o + n)].prefix { $0 != 0 }))
        }
        tags.set(\.title, field(3, 30))
        tags.set(\.artist, field(33, 30))
        tags.set(\.album, field(63, 30))
        tags.set(\.year, field(93, 4))
        if raw[125] == 0, raw[126] != 0 {
            tags.set(\.comment, field(97, 28))
            if tags.tags.track == nil { tags.tags.track = Int(raw[126]) }
        } else {
            tags.set(\.comment, field(97, 30))
        }
        if raw[127] != 255 { tags.set(\.genre, genre(Int(raw[127]))) }
        return true
    }

    static func genre(_ n: Int) -> String? { genres.indices.contains(n) ? genres[n] : nil }

    /// ID3v1 genres 0–79 and the Winamp extensions 80–125.
    static let genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age",
        "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
        "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion",
        "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal",
        "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival", "Celtic",
        "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock",
        "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club",
        "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock",
        "Drum Solo", "A Cappella", "Euro-House", "Dance Hall",
    ]
}

// MARK: - MPEG audio

enum MediaMPEG {
    static let v1l1 = [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448]
    static let v1l2 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
    static let v1l3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let v2l1 = [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256]
    static let v2l23 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    struct Header { var version: Int; var layer: Int; var bitrate: Int; var rate: Int; var channels: Int; var samples: Int; var length: Int }

    /// version: 1, 2 or 25 (2.5); layer 1–3.
    static func header(_ b: MediaBytes, _ o: Int) -> Header? {
        guard let h = b.be32(o), h >> 21 == 0x7FF else { return nil }
        let versionBits = (h >> 19) & 3, layerBits = (h >> 17) & 3
        let bitrateIndex = Int((h >> 12) & 15), rateIndex = Int((h >> 10) & 3)
        guard versionBits != 1, layerBits != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
        let version = versionBits == 3 ? 1 : versionBits == 2 ? 2 : 25
        let layer = 4 - Int(layerBits)
        let table: [Int]
        switch (version, layer) {
        case (1, 1): table = v1l1
        case (1, 2): table = v1l2
        case (1, 3): table = v1l3
        case (_, 1): table = v2l1
        default: table = v2l23
        }
        let bitrate = table[bitrateIndex] * 1000
        let rates = version == 1 ? [44_100, 48_000, 32_000] : version == 2 ? [22_050, 24_000, 16_000] : [11_025, 12_000, 8_000]
        let rate = rates[rateIndex]
        let padding = Int((h >> 9) & 1)
        let channels = (h >> 6) & 3 == 3 ? 1 : 2
        let samples = layer == 1 ? 384 : (layer == 3 && version != 1) ? 576 : 1152
        let length = layer == 1 ? (12 * bitrate / rate + padding) * 4 : samples / 8 * bitrate / rate + padding
        return Header(version: version, layer: layer, bitrate: bitrate, rate: rate, channels: channels, samples: samples, length: length)
    }

    /// The first frame (confirmed by the frame after it), with the Xing/Info or VBRI frame count when present.
    static func scan(_ b: MediaBytes, from: Int, to: Int) -> MediaAudioStream? {
        var o = from
        let limit = min(to - 4, from + 256 * 1024)
        while o <= limit {
            if b.u8(o) == 0xFF, let h = header(b, o), h.length > 4 {
                let next = o + h.length
                if next + 4 > to || header(b, next) != nil {
                    var s = MediaAudioStream()
                    s.codec = h.layer == 3 ? "MP3" : "MPEG Layer \(h.layer)"
                    s.sampleRate = h.rate
                    s.channels = h.channels
                    let side = h.version == 1 ? (h.channels == 1 ? 17 : 32) : (h.channels == 1 ? 9 : 17)
                    let xing = o + 4 + side
                    var frames: Int?
                    if b.matches("Xing", at: xing) || b.matches("Info", at: xing), let flags = b.be32(xing + 4), flags & 1 != 0 {
                        frames = b.be32(xing + 8).map(Int.init)
                    } else if b.matches("VBRI", at: o + 36) {
                        frames = b.be32(o + 36 + 14).map(Int.init)
                    }
                    if let frames, frames > 0 {
                        let seconds = Double(frames * h.samples) / Double(h.rate)
                        s.durationSeconds = seconds
                        if seconds > 0 { s.bitrate = FormatMath.int(Double(to - o) * 8 / seconds) }
                    } else {
                        s.bitrate = h.bitrate
                        s.durationSeconds = Double(to - o) * 8 / Double(h.bitrate)
                    }
                    return s
                }
            }
            o += 1
        }
        return nil
    }
}

// MARK: - MP4 atoms

enum MediaMP4Value: Equatable { case text(String), binary([UInt8]) }

/// Walks MP4 atoms: mvhd for the duration, the sound track's sample entry for the codec, and the iTunes `ilst`.
struct MediaMP4Walker {
    let b: MediaBytes
    var sawFtypOrMoov = false
    var sawIlst = false
    var timescale: UInt64 = 0
    var duration: UInt64 = 0
    var items: [(String, MediaMP4Value)] = []
    var cover: MediaPicture?
    var coverSize = 0
    var hasLyrics = false
    var hasVideo = false
    var codec: String?
    var channels: Int?
    var sampleRate: Int?
    var sampleSize: Int?
    var compressedMovie = false
    var truncated = false
    var atoms = 0
    private var trackHandler: String?

    init(b: MediaBytes) { self.b = b }

    static let containers: Set<String> = ["moov", "udta", "trak", "mdia", "minf", "stbl", "ilst", "edts", "dinf"]

    mutating func walk(_ start: Int, _ end: Int, depth: Int, path: [String]) {
        guard depth < 12 else { return }
        var o = start
        while o + 8 <= end, atoms < 100_000 {
            atoms += 1
            guard let size32 = b.be32(o), let type = b.bytes(o + 4, 4).count == 4 ? MediaText.latin1(b.bytes(o + 4, 4)) : nil else { return }
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard let large = b.be64(o + 8), large < UInt64(Int.max) else { return }
                size = Int(large)
                header = 16
            } else if size32 == 0 {
                size = end - o
            }
            guard size >= header else { return }
            // `size > end - o`, never `o + size > end`: a 64-bit size near Int.max would overflow the sum.
            if size > end - o { truncated = true; size = end - o }
            let body = o + header, bodyEnd = o + size
            if depth == 0, type == "ftyp" || type == "moov" { sawFtypOrMoov = true }
            if path.last == "ilst" {
                item(type, body, bodyEnd)
            } else if Self.containers.contains(type) {
                if type == "trak" { trackHandler = nil }
                if type == "ilst" { sawIlst = true }
                walk(body, bodyEnd, depth: depth + 1, path: path + [type])
            } else {
                switch type {
                case "meta":
                    // A full box in MP4; QuickTime writes it without the version and flags.
                    let skip = b.matches("hdlr", at: body + 4) ? 0 : 4
                    walk(body + skip, bodyEnd, depth: depth + 1, path: path + [type])
                case "mvhd":
                    let version = b.u8(body) ?? 0
                    if version == 1 {
                        timescale = UInt64(b.be32(body + 20) ?? 0); duration = b.be64(body + 24) ?? 0
                    } else {
                        timescale = UInt64(b.be32(body + 12) ?? 0); duration = UInt64(b.be32(body + 16) ?? 0)
                    }
                case "hdlr":
                    trackHandler = b.fourCC(body + 8)
                    if trackHandler == "vide" { hasVideo = true }
                case "stsd" where trackHandler == "soun" && codec == nil:
                    let entry = body + 8
                    if let format = b.bytes(entry + 4, 4).count == 4 ? MediaText.latin1(b.bytes(entry + 4, 4)) : nil {
                        codec = Self.codecName(format)
                        channels = b.be16(entry + 24).map(Int.init)
                        sampleSize = b.be16(entry + 26).map(Int.init)
                        if let rate = b.be32(entry + 32) { sampleRate = Int(rate >> 16) }
                    }
                case "cmov": compressedMovie = true
                default: break
                }
            }
            o += size
        }
    }

    mutating func item(_ key: String, _ start: Int, _ end: Int) {
        var o = start
        while o + 16 <= end {
            guard let size = b.be32(o).map(Int.init), size >= 16, size <= end - o else { return }
            if b.matches("data", at: o + 4), let kind = b.be32(o + 8) {
                let payloadStart = o + 16, payloadLength = size - 16
                let type = kind & 0x00FF_FFFF
                if key == "covr" {
                    if coverSize == 0 || cover == nil {
                        coverSize = payloadLength
                        if payloadLength <= MediaLimits.maxAudioCoverBytes {
                            let bytes = b.sub(payloadStart, payloadLength)
                            let mime = type == 14 ? "image/png" : type == 13 ? "image/jpeg" : (MediaPath.sniffImageMime(bytes) ?? "image/jpeg")
                            cover = MediaPicture(data: bytes, mimeType: mime, pictureType: "Front cover")
                        }
                    }
                } else if key == "©lyr" {
                    hasLyrics = true
                } else if type == 1 {
                    items.append((key, .text(MediaText.utf8(b.bytes(payloadStart, min(payloadLength, 64 * 1024))))))
                } else {
                    items.append((key, .binary(b.bytes(payloadStart, min(payloadLength, 256)))))
                }
                return
            }
            o += size
        }
    }

    static func codecName(_ format: String) -> String {
        switch format {
        case "mp4a": "AAC"
        case "alac": "Apple Lossless"
        case "ac-3": "AC-3"
        case "ec-3": "E-AC-3"
        case "Opus": "Opus"
        case "fLaC": "FLAC"
        case "lpcm", "sowt", "twos": "PCM"
        default: format.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Vorbis comments and FLAC pictures

enum MediaVorbisComment {
    /// Little-endian vendor and comment list (no framing bit needed). True when any comment was read.
    static func parse(_ c: [UInt8], tags: inout MediaTagSet) -> Bool {
        guard let vendorLength = c.mediaLE32(0).map(Int.init), vendorLength >= 0, 4 + vendorLength + 4 <= c.count,
              let count = c.mediaLE32(4 + vendorLength).map(Int.init) else { return false }
        var o = 8 + vendorLength
        var read = 0
        for _ in 0..<min(count, 10_000) {
            guard let len = c.mediaLE32(o).map(Int.init), len >= 0, o + 4 + len <= c.count else {
                tags.truncated = true
                break
            }
            let entry = c[(o + 4)..<(o + 4 + len)]
            o += 4 + len
            guard let eq = entry.firstIndex(of: 0x3D) else { continue }
            let key = MediaText.latin1(entry[entry.startIndex..<eq]).uppercased()
            let valueBytes = entry[(eq + 1)...]
            read += 1
            if key == "METADATA_BLOCK_PICTURE" {
                if let raw = Data(base64Encoded: Data(valueBytes), options: .ignoreUnknownCharacters),
                   let (pic, size) = MediaFLACPicture.parse([UInt8](raw)) { tags.offerCover(pic, size: size) }
                continue
            }
            tags.apply(vorbis: key, String(decoding: valueBytes.prefix(64 * 1024), as: UTF8.self))
        }
        return read > 0
    }
}

enum MediaFLACPicture {
    /// A FLAC PICTURE block (also base64 inside Vorbis comments). Returns the picture (nil bytes over 2 MB) and size.
    static func parse(_ p: [UInt8]) -> (MediaPicture?, Int)? {
        guard let type = p.mediaBE32(0), let mimeLength = p.mediaBE32(4).map(Int.init), 8 + mimeLength + 4 <= p.count else { return nil }
        let mime = MediaText.latin1(p[8..<(8 + mimeLength)])
        var o = 8 + mimeLength
        guard let descLength = p.mediaBE32(o).map(Int.init), o + 4 + descLength + 20 <= p.count else { return nil }
        let desc = MediaText.clean(MediaText.utf8(p[(o + 4)..<(o + 4 + descLength)]), max: 200)
        o += 4 + descLength + 16
        guard let dataLength = p.mediaBE32(o).map(Int.init) else { return nil }
        let start = o + 4
        let available = max(0, min(dataLength, p.count - start))
        guard dataLength <= MediaLimits.maxAudioCoverBytes, available == dataLength else { return (nil, dataLength) }
        let bytes = Data(p[start..<(start + dataLength)])
        return (MediaPicture(data: bytes, mimeType: mime.isEmpty ? (MediaPath.sniffImageMime(bytes) ?? "image/jpeg") : mime,
                             pictureType: typeName(Int(type)), description: desc), dataLength)
    }

    static func typeName(_ n: Int) -> String? {
        let names = ["Other", "File icon", "Other file icon", "Front cover", "Back cover", "Leaflet page", "Media",
                     "Lead artist", "Artist", "Conductor", "Band", "Composer", "Lyricist", "Recording location",
                     "During recording", "During performance", "Screen capture", "Bright coloured fish", "Illustration",
                     "Band logo", "Publisher logo"]
        return names.indices.contains(n) ? names[n] : nil
    }
}
