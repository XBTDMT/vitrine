import CoreText
import Foundation
import VitrineDocument

/// The card's words for a font file, from `FontFileInfo` (cards.html §3b "Font in the Vitrine window"): the family, how
/// many glyphs and which scripts, its styles or axes, then the Sizes waterfall, the Font facts and the Features
/// chips. Pure data. roadmap: S-23
enum FontCard {
    static func make(_ info: FontFileInfo, fileSize: Int64) -> InfoCard {
        let glyphs = glyphPhrase(info.glyphCount)
        let scripts = info.scripts.isEmpty ? nil : InfoCard.list(info.scripts.map(scriptName))
        // Each sentence is one localized phrase; the bold parts are localized on their own and match its words.
        let sentence: String
        let lead: String
        if info.isVariable {
            lead = String(localized: "variable font", bundle: .previewKit, comment: "Bold part of a variable font's sentence; must match the words of the sentence.")
            let family = info.family
            switch (scripts, weightRange(info)) {
            case let (scripts?, (light, heavy)?):
                sentence = String(localized: "A variable font, \(family), with \(glyphs) covering \(scripts), from \(light) to \(heavy).", bundle: .previewKit,
                                  comment: "A variable font's sentence: family, glyph count, scripts, lightest and heaviest styles; e.g. “A variable font, Inter, with 2,548 glyphs covering Latin and Greek, from Thin to Black.”")
            case let (scripts?, nil):
                sentence = String(localized: "A variable font, \(family), with \(glyphs) covering \(scripts).", bundle: .previewKit,
                                  comment: "A variable font's sentence: family, glyph count and scripts.")
            case let (nil, (light, heavy)?):
                sentence = String(localized: "A variable font, \(family), with \(glyphs), from \(light) to \(heavy).", bundle: .previewKit,
                                  comment: "A variable font's sentence: family, glyph count, lightest and heaviest styles.")
            case (nil, nil):
                sentence = String(localized: "A variable font, \(family), with \(glyphs).", bundle: .previewKit,
                                  comment: "A variable font's sentence: family and glyph count.")
            }
        } else if info.isCollection {
            lead = String(localized: "font collection", bundle: .previewKit, comment: "Bold part of a font collection's sentence; must match the words of the sentence.")
            let family = info.family, styles = styleCount(info)
            if let scripts {
                sentence = String(localized: "A font collection, \(family), with \(styles) and \(glyphs) covering \(scripts).", bundle: .previewKit,
                                  comment: "A font collection's sentence: family, style count, glyph count and scripts; e.g. “A font collection, Helvetica, with 6 styles and 2,252 glyphs covering Latin.”")
            } else {
                sentence = String(localized: "A font collection, \(family), with \(styles) and \(glyphs).", bundle: .previewKit,
                                  comment: "A font collection's sentence: family, style count and glyph count.")
            }
        } else {
            lead = String(localized: "font", bundle: .previewKit, comment: "Bold part of a font's sentence; must match the words of the sentence.")
            let name = info.faces.first?.fullName ?? info.family
            if let scripts {
                sentence = String(localized: "A font, \(name), with \(glyphs) covering \(scripts).", bundle: .previewKit,
                                  comment: "A font's sentence: its name, glyph count and scripts; e.g. “A font, Arial, with 3,381 glyphs covering Latin, Greek and Cyrillic.”")
            } else {
                sentence = String(localized: "A font, \(name), with \(glyphs).", bundle: .previewKit,
                                  comment: "A font's sentence: its name and glyph count.")
            }
        }
        let glyphsLabel = String(localized: "Glyphs", bundle: .previewKit, comment: "Font card label: how many glyphs the font has.")
        let axesLabel = String(localized: "Axes", bundle: .previewKit, comment: "Font card label: a variable font's variation axes.")
        let stylesLabel = String(localized: "Styles", bundle: .previewKit, comment: "Font card label: the styles in the file.")
        let formatLabel = String(localized: "Format", bundle: .previewKit, comment: "Font card label: the font file's format.")
        let scriptsLabel = String(localized: "Scripts", bundle: .previewKit, comment: "Font card label: the writing systems the font covers.")
        let versionLabel = String(localized: "Version", bundle: .previewKit, comment: "Font card label: the font's version.")
        var strip: [InfoCard.Stat] = [.init(value: info.glyphCount.formatted(), label: glyphsLabel)]
        if info.isVariable { strip.append(.init(value: info.axes.map(\.tag).joined(separator: ", "), label: axesLabel)) }
        else if info.isCollection { strip.append(.init(value: info.faces.count.formatted(), label: stylesLabel)) }
        else { strip.append(.init(value: shortFormat(info), label: formatLabel)) }
        if !info.scripts.isEmpty { strip.append(.init(value: scriptNames(info), label: scriptsLabel)) }
        else if let version = info.version { strip.append(.init(value: version, label: versionLabel)) }

        var rows: [InfoCard.Row] = [.init(key: String(localized: "Family", bundle: .previewKit, comment: "Font card row: the font family's name."), value: info.family),
                                    .init(key: stylesLabel, value: stylesValue(info))]
        if let version = info.version { rows.append(.init(key: versionLabel, value: version)) }
        if let designer = info.designer {
            rows.append(.init(key: String(localized: "Designer", bundle: .previewKit, comment: "Font card row: who designed the font."), value: designer))
        }
        if let foundry = info.foundry, foundry != info.designer {
            rows.append(.init(key: String(localized: "Foundry", bundle: .previewKit, comment: "Font card row: the company that made the font."), value: foundry))
        }
        if let licence = info.licence {
            rows.append(.init(key: String(localized: "Licence", bundle: .previewKit, comment: "Font card row: the font's licence."), value: FontFileInfo.licenceName(licence)))
        }
        rows.append(.init(key: formatLabel, value: info.formatName))

        var sections: [InfoCard.Section] = [
            .init(title: String(localized: "Sizes", bundle: .previewKit, comment: "Font card section: the sample at several sizes."), content: .drawn("sizes")),
            .init(title: String(localized: "Font", bundle: .previewKit, comment: "Font card section: the font's facts."), content: .rows(rows)),
        ]
        if info.isVariable {
            sections.append(.init(title: axesLabel, content: .rows(info.axes.map { .init(key: "\($0.name) (\($0.tag))", value: axisRange($0)) })))
        }
        if !info.features.isEmpty {
            sections.append(.init(title: String(localized: "Features", bundle: .previewKit, comment: "Font card section: the font's OpenType feature tags."),
                                  content: .chips(info.features)))
        }
        return InfoCard(kindName: String(localized: "Font", bundle: .previewKit, comment: "Kind of file: a font."),
                        title: info.family, sentence: sentence, bold: [lead, glyphs], tileToken: "kind-text",
                        tileSymbol: "textformat", strip: strip,
                        actions: [.init(id: "install", title: String(localized: "Install…", bundle: .previewKit, comment: "Button: hands the font to Font Book to install it."), style: .primary),
                                  .init(id: "copyName", title: String(localized: "Copy name", bundle: .previewKit, comment: "Button: copies the font family's name."), style: .normal)],
                        sections: sections)
    }

    static func facts(_ info: FontFileInfo, card: InfoCard, fileSize: Int64) -> [Fact] {
        var facts = [Fact(key: "kindName", label: String(localized: "Kind", bundle: .previewKit, comment: "Fact label: what kind of file it is."), value: card.kindName),
                     DocumentFacts.size(fileSize),
                     Fact(key: "family", label: String(localized: "Family", bundle: .previewKit, comment: "Fact label: the font family's name."), value: info.family),
                     Fact(key: "styles", label: String(localized: "Styles", bundle: .previewKit, comment: "Fact label: the styles in the font file."), value: stylesValue(info)),
                     Fact(key: "glyphs", label: String(localized: "Glyphs", bundle: .previewKit, comment: "Fact label: how many glyphs the font has."),
                          value: info.glyphCount.formatted()),
                     Fact(key: "format", label: String(localized: "Format", bundle: .previewKit, comment: "Fact label: the font file's format."), value: info.formatName)]
        if !info.scripts.isEmpty {
            facts.append(Fact(key: "scripts", label: String(localized: "Scripts", bundle: .previewKit, comment: "Fact label: the writing systems the font covers."),
                              value: scriptNames(info)))
        }
        if info.isVariable {
            facts.append(Fact(key: "axes", label: String(localized: "Axes", bundle: .previewKit, comment: "Fact label: a variable font's variation axes."),
                              value: info.axes.map(\.tag).joined(separator: ", ")))
        }
        if let version = info.version {
            facts.append(Fact(key: "version", label: String(localized: "Version", bundle: .previewKit, comment: "Fact label: the font's version."), value: version))
        }
        if let designer = info.designer {
            facts.append(Fact(key: "designer", label: String(localized: "Designer", bundle: .previewKit, comment: "Fact label: who designed the font."), value: designer))
        }
        if let foundry = info.foundry {
            facts.append(Fact(key: "foundry", label: String(localized: "Foundry", bundle: .previewKit, comment: "Fact label: the company that made the font."), value: foundry))
        }
        if let licence = info.licence {
            facts.append(Fact(key: "licence", label: String(localized: "Licence", bundle: .previewKit, comment: "Fact label: the font's licence."),
                              value: FontFileInfo.licenceName(licence)))
        }
        if !info.features.isEmpty {
            facts.append(Fact(key: "features", label: String(localized: "Features", bundle: .previewKit, comment: "Fact label: the font's OpenType feature tags."),
                              value: info.features.joined(separator: " ")))
        }
        return facts
    }

    /// Everything the name table and the file say, for the Info view (and copy and find).
    static func infoText(_ info: FontFileInfo, card: InfoCard) -> String {
        var lines = [card.title, card.sentence, ""]
        lines.append(line(String(localized: "Format", bundle: .previewKit, comment: "Font Info view label: the file format."), info.formatName))
        lines.append(line(String(localized: "Glyphs", bundle: .previewKit, comment: "Font Info view label: the glyph count."), info.glyphCount.formatted()))
        if !info.scripts.isEmpty {
            lines.append(line(String(localized: "Scripts", bundle: .previewKit, comment: "Font Info view label: the writing systems covered."), scriptNames(info)))
        }
        if let v = info.version { lines.append(line(String(localized: "Version", bundle: .previewKit, comment: "Font Info view label: the font's version."), v)) }
        if let d = info.designer { lines.append(line(String(localized: "Designer", bundle: .previewKit, comment: "Font Info view label: who designed the font."), d)) }
        if let f = info.foundry { lines.append(line(String(localized: "Foundry", bundle: .previewKit, comment: "Font Info view label: the company that made the font."), f)) }
        if let c = info.copyright { lines.append(line(String(localized: "Copyright", bundle: .previewKit, comment: "Font Info view label: the copyright notice."), c)) }
        if let u = info.licenceURL { lines.append(line(String(localized: "Licence URL", bundle: .previewKit, comment: "Font Info view label: the licence's web address."), u)) }
        if let l = info.licence { lines += ["", String(localized: "Licence", bundle: .previewKit, comment: "Font Info view heading: the licence text follows."), l] }
        if info.isVariable {
            lines += ["", String(localized: "Axes", bundle: .previewKit, comment: "Font Info view heading: the variation axes follow.")]
            lines += info.axes.map { line("\($0.name) (\($0.tag))", axisRange($0)) }
        }
        if !info.features.isEmpty {
            lines += ["", String(localized: "OpenType features", bundle: .previewKit, comment: "Font Info view heading: the feature tags follow (OpenType is the format's name)."),
                      info.features.joined(separator: " ")]
        }
        lines += ["", info.isVariable ? String(localized: "Named instances", bundle: .previewKit, comment: "Font Info view heading: a variable font's named styles follow.")
                                      : String(localized: "Styles", bundle: .previewKit, comment: "Font Info view heading: the styles in the file follow.")]
        lines += info.faces.prefix(500).map(\.fullName)
        return lines.joined(separator: "\n")
    }

    /// "Label: value", one line of the Info view.
    static func line(_ label: String, _ value: String) -> String {
        String(localized: "\(label): \(value)", bundle: .previewKit, comment: "One line of an Info view: a label, then its value; e.g. “Version: 2.104”.")
    }

    /// "100–900, default 400".
    static func axisRange(_ axis: FontFileInfo.Axis) -> String {
        let minimum = number(axis.minimum), maximum = number(axis.maximum), standard = number(axis.defaultValue)
        return String(localized: "\(minimum)–\(maximum), default \(standard)", bundle: .previewKit,
                      comment: "A variable font axis's range and default value; e.g. “100–900, default 400”.")
    }

    /// "3,381 glyphs", "1 glyph".
    static func glyphPhrase(_ count: Int) -> String {
        if count == 1 { return String(localized: "1 glyph", bundle: .previewKit, comment: "A font with exactly one glyph.") }
        let n = count.formatted()
        return String(localized: "\(n) glyphs", bundle: .previewKit, comment: "How many glyphs a font has; e.g. “3,381 glyphs”. Bold in the font's sentence.")
    }

    /// The scripts the font covers, in the reader's language, comma-separated.
    static func scriptNames(_ info: FontFileInfo) -> String {
        info.scripts.map(scriptName).joined(separator: String(localized: ", ", bundle: .previewKit, comment: "Separator between the items of a list."))
    }

    /// A script's name for people; `FontFileInfo.scripts` holds the English names as keys.
    static func scriptName(_ script: String) -> String {
        switch script {
        case "Latin": String(localized: "Latin", bundle: .previewKit, comment: "Writing system name.")
        case "Greek": String(localized: "Greek", bundle: .previewKit, comment: "Writing system name.")
        case "Cyrillic": String(localized: "Cyrillic", bundle: .previewKit, comment: "Writing system name.")
        case "Armenian": String(localized: "Armenian", bundle: .previewKit, comment: "Writing system name.")
        case "Hebrew": String(localized: "Hebrew", bundle: .previewKit, comment: "Writing system name.")
        case "Arabic": String(localized: "Arabic", bundle: .previewKit, comment: "Writing system name.")
        case "Devanagari": String(localized: "Devanagari", bundle: .previewKit, comment: "Writing system name.")
        case "Bengali": String(localized: "Bengali", bundle: .previewKit, comment: "Writing system name.")
        case "Thai": String(localized: "Thai", bundle: .previewKit, comment: "Writing system name.")
        case "Georgian": String(localized: "Georgian", bundle: .previewKit, comment: "Writing system name.")
        case "Hiragana": String(localized: "Hiragana", bundle: .previewKit, comment: "Writing system name.")
        case "Katakana": String(localized: "Katakana", bundle: .previewKit, comment: "Writing system name.")
        case "Han": String(localized: "Han", bundle: .previewKit, comment: "Writing system name: Chinese characters.")
        case "Hangul": String(localized: "Hangul", bundle: .previewKit, comment: "Writing system name: the Korean alphabet.")
        default: script
        }
    }

    /// "9 named instances", "6 styles", "Regular".
    static func stylesValue(_ info: FontFileInfo) -> String {
        if info.isVariable {
            if info.namedInstances == 1 { return String(localized: "1 named instance", bundle: .previewKit, comment: "A variable font with exactly one named style.") }
            let n = info.namedInstances.formatted()
            return String(localized: "\(n) named instances", bundle: .previewKit, comment: "How many named styles a variable font has; e.g. “9 named instances”.")
        }
        if info.faces.count > 1 { return styleCount(info) }
        return info.faces.first?.style ?? String(localized: "Regular", bundle: .previewKit, comment: "The usual name of a font's plain style, when the file names none.")
    }

    static func styleCount(_ info: FontFileInfo) -> String {
        if info.faces.count == 1 { return String(localized: "1 style", bundle: .previewKit, comment: "A font file with exactly one style.") }
        let n = info.faces.count.formatted()
        return String(localized: "\(n) styles", bundle: .previewKit, comment: "How many styles a font file holds; e.g. “6 styles”.")
    }

    static func shortFormat(_ info: FontFileInfo) -> String {
        switch info.container {
        case .woff: "WOFF"
        case .woff2: "WOFF 2"
        case .cff: "OpenType"
        case .collection: String(localized: "Collection", bundle: .previewKit, comment: "Short font format: a font collection file.")
        case .suitcase: String(localized: "Suitcase", bundle: .previewKit, comment: "Short font format: a classic Mac font suitcase.")
        case .trueType, .other: "TrueType"
        }
    }

    /// The lightest and heaviest named styles, by CoreText's weight trait: ("Thin", "Black").
    static func weightRange(_ info: FontFileInfo) -> (String, String)? {
        let weighted = info.faces.map { face -> (Double, String) in
            let traits = CTFontDescriptorCopyAttribute(face.descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            return ((traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0, face.style)
        }
        guard let light = weighted.min(by: { $0.0 < $1.0 }), let heavy = weighted.max(by: { $0.0 < $1.0 }), light.1 != heavy.1 else { return nil }
        return (light.1, heavy.1)
    }

    /// 400 → "400", 0.5 → "0.5" (in the reader's own decimal separator).
    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : v.formatted(.number.precision(.significantDigits(1...6)).grouping(.never))
    }
}
