import CoreText
import Foundation

/// What CoreText says about a font file, read without installing it: the faces in it (a collection's styles, or a
/// variable font's named instances), the family, version, designer, foundry and licence from the name table, the
/// glyph count, the scripts its characters cover, its variation axes and its OpenType features (the GSUB and GPOS
/// feature lists). TrueType, OpenType (CFF), collections, WOFF and WOFF 2 all load through
/// `CTFontManagerCreateFontDescriptorsFromURL` (measured 2026-10-30 on this Mac's own fonts and the KaTeX WOFF 2
/// files Vitrine ships). roadmap: S-23
struct FontFileInfo: @unchecked Sendable {
    struct Face {
        var descriptor: CTFontDescriptor
        var style: String
        var fullName: String
    }

    struct Axis: Equatable {
        var tag: String
        var name: String
        var minimum: Double
        var maximum: Double
        var defaultValue: Double
    }

    enum Container: Equatable { case trueType, cff, collection, woff, woff2, suitcase, other }

    var faces: [Face]
    var container: Container
    /// Inside a WOFF, WOFF 2 or collection: TrueType outlines or CFF.
    var outlines: Container
    var family: String
    var version: String?
    var designer: String?
    var foundry: String?
    var licence: String?
    var licenceURL: String?
    var copyright: String?
    var glyphCount: Int
    var scripts: [String]
    var axes: [Axis]
    var namedInstances: Int
    var features: [String]
    /// Characters for the glyph grid: the alphabet the font covers best, never one it lacks.
    var gridCharacters: [String]
    /// The sample sentence, in characters the font has.
    var sample: String

    var isVariable: Bool { !axes.isEmpty }
    var isCollection: Bool { container == .collection }

    enum ReadError: Error, LocalizedError {
        case unreadable
        var errorDescription: String? {
            String(localized: "CoreText cannot read this font", bundle: .previewKit, comment: "Error shown when macOS's font reader cannot open the file.")
        }
    }

    static func read(url: URL) throws -> FontFileInfo {
        let header = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 64)
        } ?? Data()
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        guard let firstDescriptor = descriptors.first else { throw ReadError.unreadable }
        let first = CTFontCreateWithFontDescriptor(firstDescriptor, 12, nil)
        let (container, outlines) = containerKind(header, font: first)

        let faces = descriptors.map { d -> Face in
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            return Face(descriptor: d, style: name(font, kCTFontStyleNameKey) ?? "Regular",
                        fullName: name(font, kCTFontFullNameKey) ?? (CTFontCopyFullName(font) as String))
        }
        let axes = (CTFontCopyVariationAxes(first) as? [[CFString: Any]] ?? []).compactMap { a -> Axis? in
            guard let id = (a[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value else { return nil }
            return Axis(tag: tag(id), name: a[kCTFontVariationAxisNameKey] as? String ?? tag(id),
                        minimum: (a[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue ?? 0,
                        maximum: (a[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue ?? 0,
                        defaultValue: (a[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue ?? 0)
        }
        let coverage = CTFontCopyCharacterSet(first) as CharacterSet
        let scripts = Self.scripts(coverage)
        let grid = gridCharacters(coverage)
        let sample = sampleText(coverage, grid: grid)
        return FontFileInfo(
            faces: faces, container: container, outlines: outlines,
            family: CTFontCopyFamilyName(first) as String,
            version: name(first, kCTFontVersionNameKey).map(cleanVersion),
            designer: name(first, kCTFontDesignerNameKey), foundry: name(first, kCTFontManufacturerNameKey),
            licence: name(first, kCTFontLicenseNameKey), licenceURL: name(first, kCTFontLicenseURLNameKey),
            copyright: name(first, kCTFontCopyrightNameKey),
            glyphCount: CTFontGetGlyphCount(first), scripts: scripts, axes: axes,
            namedInstances: axes.isEmpty ? 0 : fvarInstanceCount(first) ?? faces.count,
            features: openTypeFeatures(first), gridCharacters: grid, sample: sample)
    }

    // MARK: Names

    static func name(_ font: CTFont, _ key: CFString) -> String? {
        guard let s = (CTFontCopyName(font, key) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// "Version 2.104; ttfautohint (v1.8)" → "2.104".
    static func cleanVersion(_ raw: String) -> String {
        var v = raw
        if let semicolon = v.firstIndex(of: ";") { v = String(v[..<semicolon]) }
        if v.lowercased().hasPrefix("version") { v = String(v.dropFirst("version".count)) }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// A licence's usual name when the text names one; else its first sentence, at most 90 characters.
    static func licenceName(_ text: String) -> String {
        let lower = text.lowercased()
        let known: [(String, String)] = [
            ("sil open font license", "SIL Open Font License"), ("open font license", "SIL Open Font License"),
            ("apache license", "Apache License"), ("ubuntu font licence", "Ubuntu Font Licence"),
            ("bitstream vera", "Bitstream Vera License"), ("gnu general public license", "GNU GPL"),
            ("mit license", "MIT License"), ("creative commons", "Creative Commons"),
        ]
        if let hit = known.first(where: { lower.contains($0.0) }) {
            let version = text.range(of: #"(?i)(version|v\.?)\s*([0-9]+\.[0-9]+)"#, options: .regularExpression).map {
                text[$0].components(separatedBy: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")).inverted).last ?? ""
            } ?? ""
            return version.isEmpty ? hit.1 : "\(hit.1) \(version)"
        }
        let firstSentence = text.split(whereSeparator: { ".\n".contains($0) }).first.map(String.init) ?? text
        let trimmed = firstSentence.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 90 ? String(trimmed.prefix(89)) + "…" : trimmed
    }

    // MARK: Format

    static func containerKind(_ header: Data, font: CTFont) -> (Container, Container) {
        let magic = header.prefix(4)
        let cff = table(font, "CFF ") != nil || table(font, "CFF2") != nil
        let outlines: Container = cff ? .cff : .trueType
        switch magic {
        case Data("wOFF".utf8): return (.woff, outlines)
        case Data("wOF2".utf8): return (.woff2, outlines)
        case Data("ttcf".utf8): return (.collection, outlines)
        case Data("OTTO".utf8): return (.cff, .cff)
        case Data([0, 1, 0, 0]), Data("true".utf8): return (.trueType, .trueType)
        default: return (header.count >= 4 && header.starts(with: [0, 0, 1, 0]) ? .suitcase : .other, outlines)
        }
    }

    /// "TrueType, variable", "OpenType (CFF)", "TrueType collection", "WOFF 2 (TrueType)".
    var formatName: String {
        let outline = outlines == .cff ? "OpenType (CFF)" : "TrueType"
        var name: String
        switch container {
        case .trueType: name = "TrueType"
        case .cff: name = "OpenType (CFF)"
        case .collection:
            name = outlines == .cff
                ? String(localized: "OpenType collection", bundle: .previewKit, comment: "Font format: a collection of OpenType fonts (OpenType is the format's name).")
                : String(localized: "TrueType collection", bundle: .previewKit, comment: "Font format: a collection of TrueType fonts (TrueType is the format's name).")
        case .woff: name = "WOFF (\(outline))"
        case .woff2: name = "WOFF 2 (\(outline))"
        case .suitcase: name = String(localized: "Font suitcase", bundle: .previewKit, comment: "Font format: a classic Mac font suitcase.")
        case .other: name = outline
        }
        if isVariable {
            let base = name
            name = String(localized: "\(base), variable", bundle: .previewKit, comment: "A variable font's format; e.g. “TrueType, variable”.")
        }
        return name
    }

    // MARK: Tables

    static func tag(_ id: UInt32) -> String {
        String(bytes: [UInt8(id >> 24 & 0xFF), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "?"
    }

    private static func table(_ font: CTFont, _ tag: String) -> [UInt8]? {
        let id = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let data = CTFontCopyTable(font, id, []) as Data? else { return nil }
        return [UInt8](data)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int? { o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : nil }

    /// The named instances a variable font lists in `fvar`.
    static func fvarInstanceCount(_ font: CTFont) -> Int? {
        guard let fvar = table(font, "fvar") else { return nil }
        return u16(fvar, 12)
    }

    /// The OpenType feature tags in GSUB then GPOS, each once, in table order ("liga", "kern", "ss01").
    static func openTypeFeatures(_ font: CTFont) -> [String] {
        var seen: [String] = []
        for name in ["GSUB", "GPOS"] {
            guard let t = table(font, name), let listOffset = u16(t, 6), let count = u16(t, listOffset) else { continue }
            for i in 0..<min(count, 2_000) {
                let o = listOffset + 2 + i * 6
                guard o + 4 <= t.count, let tag = String(bytes: t[o..<o + 4], encoding: .ascii) else { break }
                let clean = tag.trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty, clean.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }), !seen.contains(clean) { seen.append(clean) }
            }
        }
        return seen
    }

    // MARK: Coverage

    /// Scripts the font covers: at least 80 % of each script's core letters. Han and Hangul are judged on a sample of
    /// common characters.
    static let scriptSamples: [(String, String)] = [
        ("Latin", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
        ("Greek", "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩαβγδεζηθικλμνξοπρστυφχψω"),
        ("Cyrillic", "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя"),
        ("Armenian", "ԱԲԳԴԵԶԷԸԹԺԻԼԽԾԿՀՁՂՃՄՅՆՇՈՉՊՋՌՍՎՏՐՑՒՓՔՕՖ"),
        ("Hebrew", "אבגדהוזחטיכלמנסעפצקרשת"),
        ("Arabic", "ابتثجحخدذرزسشصضطظعغفقكلمنهوي"),
        ("Devanagari", "अआइईउऊएऐओऔकखगघचछजझटठडढणतथदधनपफबभमयरलवशषसह"),
        ("Bengali", "অআইঈউঊএঐওঔকখগঘচছজঝটঠডঢণতথদধনপফবভমযরলশষসহ"),
        ("Thai", "กขฃคฅฆงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ"),
        ("Georgian", "აბგდევზთიკლმნოპჟრსტუფქღყშჩცძწჭხჯჰ"),
        ("Hiragana", "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"),
        ("Katakana", "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"),
        ("Han", "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年"),
        ("Hangul", "가나다라마바사아자차카타파하고노도로모보소오조초코토포호"),
    ]

    static func scripts(_ coverage: CharacterSet) -> [String] {
        scriptSamples.compactMap { name, letters in
            let scalars = letters.unicodeScalars
            let covered = scalars.filter { coverage.contains($0) }.count
            return Double(covered) >= Double(scalars.count) * 0.8 ? name : nil
        }
    }

    /// 36 characters for the grid: A–Z and a–j when the font has Latin (as the design draws it), else the first
    /// letters of the script it covers, else the first 36 printable characters it has.
    static func gridCharacters(_ coverage: CharacterSet) -> [String] {
        for (_, letters) in scriptSamples {
            let have = letters.unicodeScalars.filter { coverage.contains($0) }
            if Double(have.count) >= Double(letters.unicodeScalars.count) * 0.8 { return have.prefix(36).map { String(Character($0)) } }
        }
        var out: [String] = []
        for plane in 0..<17 where coverage.hasMember(inPlane: UInt8(plane)) {
            for v in UInt32(plane << 16)..<UInt32((plane + 1) << 16) {
                guard let s = Unicode.Scalar(v), coverage.contains(s), !CharacterSet.controlCharacters.contains(s),
                      !CharacterSet.whitespacesAndNewlines.contains(s) else { continue }
                out.append(String(Character(s)))
                if out.count == 36 { return out }
            }
        }
        return out
    }

    /// The design's pangram when the font has every letter of it; else the grid's characters run together.
    static func sampleText(_ coverage: CharacterSet, grid: [String]) -> String {
        let pangram = "Sphinx of black quartz, judge my vow"
        if pangram.unicodeScalars.allSatisfy({ coverage.contains($0) || $0 == " " }) { return pangram }
        return grid.prefix(24).joined()
    }
}
