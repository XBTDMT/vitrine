import AppKit
import VitrineUI

/// Draws a ThumbnailPage the way thumbnails r3-a does (S-18): the macOS document sheet on one toned paper for light
/// and dark Finder, drawn three ways by size (the content at 128 pt and up, a silhouette measured from the content
/// from 33 to 127 pt, the family glyph at 32 pt and below), with a red or orange mark at the lower left only when the
/// file is dangerous or broken, and the reason written on the page at 256 pt and up. Core Graphics only.
/// roadmap: S-18
public enum ThumbnailRenderer {
    public enum Tier: Equatable { case glyph, silhouette, content }

    public static func tier(for side: CGFloat) -> Tier { side >= 128 ? .content : (side > 32 ? .silhouette : .glyph) }

    /// The sheet's rectangle in a canvas (bottom-left origin): a document's proportions, centred, a little inset.
    public static func sheet(in canvas: CGSize) -> CGRect {
        let side = min(canvas.width, canvas.height)
        let h = side * 0.94, w = (h * 0.78).rounded()
        return CGRect(x: ((canvas.width - w) / 2).rounded(), y: ((canvas.height - h) / 2).rounded(), width: w, height: h.rounded())
    }

    /// Draws the whole thumbnail into `context`, whose origin is at the bottom left and whose units are points.
    public static func draw(_ page: ThumbnailPage, in context: CGContext, size: CGSize) {
        let side = min(size.width, size.height), tier = tier(for: side)
        let sheet = sheet(in: size)
        let fold = (sheet.width * (tier == .glyph ? 0.3 : 0.22)).rounded()
        let radius = max(1, sheet.width * 0.035)
        let outline = sheetPath(sheet, fold: fold, radius: radius)

        // The paper, with a soft shadow under it.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -max(0.5, side * 0.006)), blur: max(1, side * 0.02), color: color(0, 0, 0, 0.22))
        context.addPath(outline); context.setFillColor(token("paper-thumb", fallback: "#F7F7F8")); context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(outline); context.clip()
        switch tier {
        case .content: drawContent(page, in: context, sheet: sheet, side: side)
        case .silhouette: drawSilhouette(page, in: context, sheet: sheet, side: side)
        case .glyph: drawGlyph(page, in: context, sheet: sheet)
        }
        if page.isHuge, tier != .glyph {
            let fadeH = sheet.height * 0.28
            let paper = token("paper-thumb", fallback: "#F7F7F8")
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [paper.copy(alpha: 0)!, paper] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: sheet.minY + fadeH), end: CGPoint(x: 0, y: sheet.minY), options: [])
            }
        }
        if side >= 256, let (reason, tint) = markInfo(page.mark) { drawReasonBand(reason, tint: tint, in: context, sheet: sheet, side: side) }
        context.restoreGState()

        // The edge and the fold over everything drawn on the page.
        context.addPath(outline); context.setStrokeColor(color(0, 0, 0, 0.16)); context.setLineWidth(max(0.5, side / 256)); context.strokePath()
        drawFold(in: context, sheet: sheet, fold: fold, side: side)
        if let (_, tint) = markInfo(page.mark) { drawMark(tint: tint, danger: isDanger(page.mark), in: context, sheet: sheet, side: side) }
    }

    // MARK: Tiers

    static func drawContent(_ page: ThumbnailPage, in context: CGContext, sheet: CGRect, side: CGFloat) {
        let inset = sheet.width * 0.075
        let frame = sheet.insetBy(dx: inset, dy: sheet.height * 0.055)
        if page.isEmpty { drawCentered(emptyWord, in: context, sheet: sheet, size: sheet.width * 0.09, color: token("t3")); return }
        withFlippedText(context, height: sheet.maxY + sheet.minY) {
            let top = (sheet.maxY + sheet.minY) - frame.maxY
            switch page.layout {
            case .text(let lines, let numbered, let prose):
                let fontSize = frame.width / (prose ? 30 : 50) / 0.6
                let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                let lineH = (fontSize * 1.42).rounded(.up)
                let gutter = numbered ? (fontSize * 0.6 * CGFloat(max(2, String(lines.count).count)) + fontSize * 0.9) : 0
                var y = top
                for (i, runs) in lines.enumerated() {
                    let heading = prose && runs.first?.token == .keyword
                    let h = heading ? lineH * 1.5 : lineH
                    if y + h > top + frame.height { break }
                    if numbered {
                        NSAttributedString(string: "\(i + 1)", attributes: [.font: mono, .foregroundColor: nsColor("t3")])
                            .draw(at: CGPoint(x: frame.minX, y: y))
                    }
                    let line = NSMutableAttributedString()
                    // Long lines run off the page's edge, as on paper; prose wraps no further than its line.
                    let clip = NSMutableParagraphStyle(); clip.lineBreakMode = .byClipping
                    for run in runs {
                        let font: NSFont = heading ? .systemFont(ofSize: fontSize * 1.6, weight: .bold)
                            : (prose ? .systemFont(ofSize: fontSize * 1.05) : mono)
                        line.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: tokenColor(run.token, prose: prose), .paragraphStyle: clip]))
                    }
                    line.draw(with: CGRect(x: frame.minX + gutter, y: y, width: sheet.maxX - frame.minX - gutter, height: h), options: [.usesLineFragmentOrigin])
                    y += h
                }
            case .table(let rows):
                drawTable(rows, frame: frame, top: top, tint: page.tint, in: context)
            }
        }
    }

    static func drawTable(_ rows: [[String]], frame: CGRect, top: CGFloat, tint: String, in context: CGContext) {
        guard let header = rows.first else { return }
        let available = max(header.count, rows.map(\.count).max() ?? 0)
        guard available > 0 else { return }
        // Column widths by their longest cell (capped), so a short id column keeps its whole value; as many columns as
        // fit in 56 characters, and the font sized to them, so cells are not cut.
        let allWidths = (0..<available).map { c in CGFloat(max(3, min(18, rows.prefix(20).map { c < $0.count ? $0[c].count : 0 }.max() ?? 3)) + 2) }
        var widths: [CGFloat] = []
        for w in allWidths where widths.isEmpty || widths.reduce(0, +) + w <= 56 { widths.append(w) }
        let columns = widths.count
        let total = max(widths.reduce(0, +), 34)
        let fontSize = frame.width / total / 0.6
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let rowH = (fontSize * 1.6).rounded(.up)
        let unit = frame.width / total
        var y = top
        for (r, row) in rows.enumerated() {
            if y + rowH > top + frame.height { break }
            if r == 0 {
                NSColor(cgColor: token(tint))?.withAlphaComponent(0.14).setFill()
                NSRect(x: frame.minX - 2, y: y, width: frame.width + 4, height: rowH).fill()
            }
            var x = frame.minX
            for c in 0..<columns {
                let w = widths[c] * unit
                let text = c < row.count ? row[c] : ""
                NSAttributedString(string: text, attributes: [.font: r == 0 ? bold : font, .foregroundColor: nsColor(r == 0 ? "t1" : "t2")])
                    .draw(with: CGRect(x: x + 2, y: y + rowH * 0.18, width: w - 4, height: rowH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                x += w
            }
            nsColor("sep").setFill()
            NSRect(x: frame.minX - 2, y: y + rowH - 0.5, width: frame.width + 4, height: 0.5).fill()
            y += rowH
        }
    }

    /// The minimap: every run a bar as long as its text, in its token's colour; a table's cells as bars on a grid.
    static func drawSilhouette(_ page: ThumbnailPage, in context: CGContext, sheet: CGRect, side: CGFloat) {
        let frame = sheet.insetBy(dx: sheet.width * 0.11, dy: sheet.height * 0.08)
        if page.isEmpty { drawCentered(emptyWord, in: context, sheet: sheet, size: sheet.width * 0.13, color: token("t3")); return }
        let unit = frame.width / 40
        let barH = max(1, (unit * 1.2).rounded())
        let lineH = barH * 2
        var y = frame.maxY - barH
        switch page.layout {
        case .text(let lines, let numbered, let prose):
            for runs in lines {
                if y < frame.minY { break }
                let heading = prose && runs.first?.token == .keyword
                var x = frame.minX + (numbered ? unit * 3 : 0)
                if numbered { context.setFillColor(token("t3")); context.fill(CGRect(x: frame.minX, y: y, width: unit * 1.5, height: barH)) }
                for run in runs {
                    let count = CGFloat(run.text.count)
                    let leading = CGFloat(run.text.prefix { $0 == " " }.count)
                    let visible = count - leading - CGFloat(run.text.reversed().prefix { $0 == " " }.count)
                    x += leading * unit
                    if visible > 0, x < frame.maxX {
                        let w = min(visible * unit, frame.maxX - x)
                        context.setFillColor(silhouetteColor(run.token, tint: page.tint, heading: heading))
                        let r = CGRect(x: x, y: y - (heading ? barH * 0.4 : 0), width: w, height: heading ? barH * 1.6 : barH)
                        context.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil)); context.fillPath()
                    }
                    x += max(0, count - leading) * unit
                }
                y -= heading ? lineH * 1.4 : lineH
            }
        case .table(let rows):
            let columns = max(1, min(rows.first?.count ?? 1, 5))
            let colW = frame.width / CGFloat(columns)
            for (r, row) in rows.enumerated() {
                if y < frame.minY { break }
                if r == 0 { context.setFillColor(token(page.tint, alpha: 0.18)); context.fill(CGRect(x: frame.minX - 1, y: y - barH * 0.5, width: frame.width + 2, height: barH * 2)) }
                for c in 0..<columns {
                    let len = c < row.count ? CGFloat(min(row[c].count, 14)) / 14 : 0
                    context.setFillColor(r == 0 ? token(page.tint) : token("t3"))
                    context.fill(CGRect(x: frame.minX + CGFloat(c) * colW + unit * 0.5, y: y, width: max(unit, (colW - unit) * len), height: barH))
                }
                y -= lineH
            }
        }
    }

    static func drawGlyph(_ page: ThumbnailPage, in context: CGContext, sheet: CGRect) {
        let box = sheet.width * 0.56
        let rect = CGRect(x: sheet.midX - box / 2, y: sheet.midY - box / 2 - sheet.height * 0.04, width: box, height: box)
        guard let symbol = NSImage(systemSymbolName: page.glyph, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: box, weight: .semibold)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(cgColor: token(page.tint))?.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let aspect = symbol.size.width / max(1, symbol.size.height)
        let w = aspect >= 1 ? box : box * aspect, h = aspect >= 1 ? box / aspect : box
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        tinted.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Sheet, fold, mark

    static func sheetPath(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }

    static func drawFold(in context: CGContext, sheet r: CGRect, fold: CGFloat, side: CGFloat) {
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: r.maxX - fold, y: r.maxY))
        flap.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY - fold + fold * 0.12))
        flap.addQuadCurve(to: CGPoint(x: r.maxX - fold + fold * 0.12, y: r.maxY - fold), control: CGPoint(x: r.maxX - fold, y: r.maxY - fold))
        flap.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
        flap.closeSubpath()
        context.saveGState()
        context.setShadow(offset: CGSize(width: -side * 0.004, height: -side * 0.004), blur: max(0.5, side * 0.012), color: color(0, 0, 0, 0.18))
        context.addPath(flap); context.setFillColor(color(0.89, 0.89, 0.91, 1)); context.fillPath()
        context.restoreGState()
        context.addPath(flap); context.setStrokeColor(color(0, 0, 0, 0.14)); context.setLineWidth(max(0.5, side / 320)); context.strokePath()
    }

    /// The lens mark at the sheet's lower left, where macOS puts an alias arrow: a disc with a white glyph.
    static func drawMark(tint: CGColor, danger: Bool, in context: CGContext, sheet: CGRect, side: CGFloat) {
        let d = markDiameter(side)
        let disc = CGRect(x: sheet.minX - d * 0.12, y: sheet.minY - d * 0.12, width: d, height: d)
        context.setFillColor(color(1, 1, 1, 1)); context.fillEllipse(in: disc.insetBy(dx: -max(0.5, d * 0.07), dy: -max(0.5, d * 0.07)))
        context.setFillColor(tint); context.fillEllipse(in: disc)
        if let symbol = NSImage(systemSymbolName: danger ? "xmark" : "exclamationmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: d * 0.5, weight: .heavy)) {
            let white = NSImage(size: symbol.size, flipped: false) { r in symbol.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let s = symbol.size
            white.draw(in: CGRect(x: disc.midX - s.width / 2, y: disc.midY - s.height / 2, width: s.width, height: s.height))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Small enough to stay a corner mark: 42% of a list-view icon, a fifth at 64 pt, 40 pt at 512.
    static func markDiameter(_ side: CGFloat) -> CGFloat {
        max(7, (side <= 32 ? side * 0.42 : min(side * 0.2, 14 + side * 0.05)).rounded())
    }

    /// The reason, on a band across the foot of the page (256 pt and up).
    static func drawReasonBand(_ reason: String, tint: CGColor, in context: CGContext, sheet: CGRect, side: CGFloat) {
        let h = (sheet.height * 0.13).rounded()
        let band = CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: h)
        context.setFillColor(color(1, 1, 1, 1)); context.fill(band)
        context.setFillColor(tint.copy(alpha: 0.14)!); context.fill(band)
        context.setFillColor(tint); context.fill(CGRect(x: band.minX, y: band.maxY - max(1, side / 256), width: band.width, height: max(1, side / 256)))
        let fontSize = sheet.width * 0.052
        withFlippedText(context, height: sheet.maxY + sheet.minY) {
            let top = (sheet.maxY + sheet.minY) - band.maxY
            NSAttributedString(string: reason, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor(cgColor: tint) ?? .red])
                .draw(with: CGRect(x: band.minX + markDiameter(side) * 0.88 + sheet.width * 0.04, y: top + (h - fontSize * 2.4) / 2,
                                   width: band.width - markDiameter(side) - sheet.width * 0.08, height: fontSize * 2.6),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    static func drawCentered(_ text: String, in context: CGContext, sheet: CGRect, size: CGFloat, color: CGColor) {
        withFlippedText(context, height: sheet.maxY + sheet.minY) {
            let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor(cgColor: color) ?? .gray])
            let b = s.size()
            s.draw(at: CGPoint(x: sheet.midX - b.width / 2, y: (sheet.maxY + sheet.minY) / 2 - b.height / 2))
        }
    }

    static var emptyWord: String { String(localized: "Empty", bundle: .module, comment: "Finder thumbnail of a file with nothing in it.") }

    static func markInfo(_ mark: ThumbnailPage.Mark) -> (String, CGColor)? {
        switch mark {
        case .none: return nil
        case .caution(let reason): return (reason, cgColor("#B35C00"))
        case .danger(let reason): return (reason, token("danger"))
        }
    }

    static func isDanger(_ mark: ThumbnailPage.Mark) -> Bool { if case .danger = mark { return true }; return false }

    // MARK: Colour

    static func tokenColor(_ t: CodeLexer.Token, prose: Bool) -> NSColor {
        let name: String
        switch t {
        case .keyword: name = prose ? "t1" : "syn-kw"
        case .type: name = "syn-ty"
        case .function: name = "syn-fn"
        case .string: name = prose ? "t2" : "syn-str"
        case .number: name = "syn-num"
        case .comment: name = "syn-com"
        case .key: name = "syn-key"
        case .tag: name = "syn-kw"
        case .attribute: name = "syn-attr"
        case .punctuation: name = "syn-punct"
        case .constant: name = "syn-bool"
        case .plain: name = "t1"
        }
        return nsColor(name)
    }

    static func silhouetteColor(_ t: CodeLexer.Token, tint: String, heading: Bool) -> CGColor {
        if heading { return token(tint) }
        switch t {
        case .plain, .punctuation: return token("t3", alpha: 0.55)
        default: return tokenColor(t, prose: false).withAlphaComponent(0.8).cgColor
        }
    }

    /// A token's LIGHT colour: one picture serves light and dark Finder (r3-a), on the toned paper.
    static func token(_ name: String, fallback: String = "#808080", alpha: CGFloat? = nil) -> CGColor {
        let c = cgColor(GeneratedTokens.color(name)?.light ?? fallback)
        return alpha.flatMap { c.copy(alpha: $0) } ?? c
    }

    static func nsColor(_ name: String) -> NSColor { NSColor(cgColor: token(name)) ?? .black }

    static func cgColor(_ css: String) -> CGColor { NSColor(css: css)?.usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0.5, alpha: 1) }

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// Text drawn top-down inside a bottom-up context.
    static func withFlippedText(_ context: CGContext, height: CGFloat, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: 0, y: height); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

public extension ThumbnailRenderer {
    /// The thumbnail as an image `side` points square at `scale`, transparent around the sheet.
    static func image(_ page: ThumbnailPage, side: CGFloat, scale: CGFloat = 2) -> CGImage? {
        let px = Int((side * scale).rounded())
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(page, in: ctx, size: CGSize(width: side, height: side))
        return ctx.makeImage()
    }

    /// Every size side by side on a backdrop, for proofs: Finder's sizes 16 to 512 by default.
    static func proof(_ page: ThumbnailPage, sides: [CGFloat] = [16, 32, 64, 128, 256, 512], backdrop: CGColor = CGColor(gray: 1, alpha: 1), scale: CGFloat = 2) -> CGImage? {
        let pad: CGFloat = 16
        let width = sides.reduce(pad) { $0 + $1 + pad }, height = (sides.max() ?? 0) + pad * 2
        let w = Int(width * scale), h = Int(height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(backdrop); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var x = pad
        for side in sides {
            if let tile = image(page, side: side, scale: scale) {
                ctx.draw(tile, in: CGRect(x: x * scale, y: pad * scale, width: side * scale, height: side * scale))
            }
            x += side + pad
        }
        return ctx.makeImage()
    }
}
