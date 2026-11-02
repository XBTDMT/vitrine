// Composes Vitrine's launch and README pictures from the app's own renders (S-17), the way the News Feed and
// Battery kits were made: each render is placed whole or cropped on a soft ground, with rounded corners and a real
// drop shadow, beside captions in the system font. Nothing is drawn over a render's pixels.
//
//   swiftc -O -o compose compose.swift && ./compose <spec.json> <out.png>
//
// The spec (top-left origin, pixels):
//   {"size":[W,H], "ground":{"top":"#rrggbb","bottom":"#rrggbb","glows":[[x,y,radius,"#rrggbb",alpha], …]},
//    "items":[
//      {"image":"path.png","crop":[x,y,w,h],"rect":[x,y,w,h],"radius":28,"shadow":60,"shadowAlpha":0.28,"stroke":"#rrggbb"},
//      {"text":"…","rect":[x,y,w,h],"size":72,"weight":"bold|semibold|medium|regular","color":"#rrggbb","align":"left|center"},
//      {"keycap":"space","rect":[x,y,w,h],"dark":false}]}
// roadmap: S-17
import AppKit

struct Spec: Decodable {
    struct Ground: Decodable { let top: String; let bottom: String; let glows: [[Glow]]? }
    enum Glow: Decodable {
        case number(Double), text(String)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
        var number: Double { if case .number(let n) = self { n } else { 0 } }
        var text: String { if case .text(let t) = self { t } else { "#000000" } }
    }
    struct Item: Decodable {
        let image: String?; let crop: [Double]?; let rect: [Double]
        let radius: Double?; let shadow: Double?; let shadowAlpha: Double?; let stroke: String?
        let text: String?; let size: Double?; let weight: String?; let color: String?; let align: String?
        let keycap: String?; let dark: Bool?
    }
    let size: [Int]; let ground: Ground; let items: [Item]
}

func color(_ hex: String, _ alpha: Double = 1) -> NSColor {
    var v: UInt64 = 0; Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
}

let args = CommandLine.arguments
guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]) else {
    FileHandle.standardError.write(Data("usage: compose <spec.json> <out.png>\n".utf8)); exit(64)
}
let spec = try JSONDecoder().decode(Spec.self, from: data)
let W = spec.size[0], H = spec.size[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
// Top-left origin, as the spec is written.
cg.translateBy(x: 0, y: CGFloat(H)); cg.scaleBy(x: 1, y: -1)
func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }

// The ground: a vertical gradient, then soft radial glows.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ground = CGGradient(colorsSpace: space, colors: [color(spec.ground.top).cgColor, color(spec.ground.bottom).cgColor] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(ground, start: .zero, end: CGPoint(x: 0, y: H), options: [])
for g in spec.ground.glows ?? [] {
    let c = color(g[3].text, g[4].number)
    let glow = CGGradient(colorsSpace: space, colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    let p = CGPoint(x: g[0].number, y: g[1].number)
    cg.drawRadialGradient(glow, startCenter: p, startRadius: 0, endCenter: p, endRadius: g[2].number, options: [])
}

for item in spec.items {
    let r = rect(item.rect)
    if let path = item.image {
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
        }
        let image = item.crop.map { src.cropping(to: rect($0))! } ?? src
        let radius = item.radius ?? 0
        let shape = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let blur = item.shadow, blur > 0 {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: blur * 0.35), blur: blur, color: NSColor(white: 0, alpha: item.shadowAlpha ?? 0.25).cgColor)
            cg.addPath(shape); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
            cg.restoreGState()
        }
        cg.saveGState()
        cg.addPath(shape); cg.clip()
        // Images draw upright in the flipped context.
        cg.translateBy(x: r.minX, y: r.maxY); cg.scaleBy(x: 1, y: -1)
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(origin: .zero, size: r.size))
        cg.restoreGState()
        if let stroke = item.stroke {
            cg.addPath(shape); cg.setStrokeColor(color(stroke, 0.9).cgColor); cg.setLineWidth(2); cg.strokePath()
        }
    } else if let text = item.text {
        let weight: NSFont.Weight = ["bold": .bold, "semibold": .semibold, "medium": .medium][item.weight ?? ""] ?? .regular
        let para = NSMutableParagraphStyle(); para.alignment = item.align == "center" ? .center : .left; para.lineHeightMultiple = 1.08
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: item.size ?? 40, weight: weight),
                                                    .foregroundColor: color(item.color ?? "#1d1d1f"), .paragraphStyle: para,
                                                    .kern: (item.size ?? 40) > 60 ? -(item.size ?? 40) * 0.02 : 0]
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(H)); cg.scaleBy(x: 1, y: -1)
        NSAttributedString(string: text, attributes: attrs).draw(with: CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height),
                                                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        cg.restoreGState()
    } else if let label = item.keycap {
        // A keyboard key: a soft body, a lighter cap and the label in the system font.
        let dark = item.dark ?? false
        let body = CGPath(roundedRect: r, cornerWidth: r.height * 0.22, cornerHeight: r.height * 0.22, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: r.height * 0.06), blur: r.height * 0.18, color: NSColor(white: 0, alpha: dark ? 0.5 : 0.18).cgColor)
        cg.addPath(body); cg.setFillColor((dark ? color("#2c2f33") : color("#e6e8eb")).cgColor); cg.fillPath()
        cg.restoreGState()
        let inset = r.insetBy(dx: r.height * 0.06, dy: r.height * 0.06).offsetBy(dx: 0, dy: -r.height * 0.04)
        cg.addPath(CGPath(roundedRect: inset, cornerWidth: r.height * 0.18, cornerHeight: r.height * 0.18, transform: nil))
        cg.setFillColor((dark ? color("#3a3e43") : color("#ffffff")).cgColor); cg.fillPath()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r.height * 0.26, weight: .medium),
                                                    .foregroundColor: dark ? color("#e8eaed") : color("#4a4f55"), .paragraphStyle: para]
        let line = r.height * 0.34
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(H)); cg.scaleBy(x: 1, y: -1)
        NSAttributedString(string: label, attributes: attrs).draw(in: CGRect(x: inset.minX, y: CGFloat(H) - inset.midY - line * 0.62, width: inset.width, height: line))
        cg.restoreGState()
    }
}
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(W)×\(H)")
