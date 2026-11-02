// Finder thumbnail reach (S-18, SP-6): asks QuickLookThumbnailing, the API Finder uses, for each file's thumbnail and
// reports who drew it: VITRINE (the r3-a sheet leaves the canvas corners transparent), other (macOS or another app) or
// none, with the time it took. Run through thumb_reach.sh. roadmap: S-18
import AppKit
import QuickLookThumbnailing

let size = CGFloat(Double(CommandLine.arguments[1]) ?? 256)
let files = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let group = DispatchGroup()
func marker(_ cg: CGImage) -> Int {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self); var m = 0
    for i in 0..<(w * h) where p[i*4] > 200 && p[i*4+1] < 80 && p[i*4+2] > 200 { m += 1 }
    // Vitrine's r3-a sheet leaves the canvas's corners transparent; Apple's text page fills them.
    if m == 0 && p[3] == 0 && p[(w * h - 1) * 4 + 3] == 0 && p[(w - 1) * 4 + 3] == 0 { m = 1 }
    return m
}
for url in files {
    group.enter()
    let start = Date()
    let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, error in
        let t = Date().timeIntervalSince(start)
        let name = url.lastPathComponent.padding(toLength: 22, withPad: " ", startingAt: 0)
        if let rep {
            let m = marker(rep.cgImage)
            if let out = ProcessInfo.processInfo.environment["PROBE_OUT"] {
                let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out).appendingPathComponent(url.lastPathComponent + ".png") as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, rep.cgImage, nil); CGImageDestinationFinalize(dest)
            }
            print("type \(rep.type.rawValue)", terminator: " ")
            print("\(name) \(m > 0 ? "VITRINE" : "other  ") \(rep.cgImage.width)px  \(String(format: "%.3f", t))s")
        } else {
            print("\(name) none     \(String(format: "%.3f", t))s  \(error.map { "\($0)" } ?? "")".prefix(900))
        }
        group.leave()
    }
    group.wait()
}
