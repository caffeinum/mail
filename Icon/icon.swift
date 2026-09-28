// Draws the app icon (8c: the top stream bar curls up into a reply arrow)
// into an .iconset folder: `swift Icon/icon.swift build/AppIcon.iconset`.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func draw(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    // The design lives on a 200-unit grid (10…190 is the plate); Apple's
    // template puts the plate at 100…924 of 1024.
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 100, y: 100)
    let k: CGFloat = 824 / 180
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -10, y: -10)

    let plate = CGPath(roundedRect: CGRect(x: 10, y: 10, width: 180, height: 180), cornerWidth: 42, cornerHeight: 42, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: color(0x5a3c0a, 0.25))
    ctx.addPath(plate); ctx.setFillColor(color(0xf5f1e8)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(plate); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [color(0xf7f3ea), color(0xe4dccb)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 10), end: CGPoint(x: 0, y: 190), options: [])
    ctx.restoreGState()
    ctx.addPath(plate); ctx.setStrokeColor(color(0x000000, 0.08)); ctx.setLineWidth(2); ctx.strokePath()

    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(color(0xf0561f)); ctx.setLineWidth(14)
    let curl = CGMutablePath()
    curl.move(to: CGPoint(x: 58, y: 111))
    curl.addLine(to: CGPoint(x: 120, y: 111))
    curl.addCurve(to: CGPoint(x: 150, y: 81), control1: CGPoint(x: 140, y: 111), control2: CGPoint(x: 150, y: 99))
    curl.addCurve(to: CGPoint(x: 112, y: 51), control1: CGPoint(x: 150, y: 63), control2: CGPoint(x: 136, y: 51))
    curl.addLine(to: CGPoint(x: 86, y: 51))
    ctx.addPath(curl); ctx.strokePath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 100, y: 36)); head.addLine(to: CGPoint(x: 82, y: 51)); head.addLine(to: CGPoint(x: 100, y: 66))
    ctx.addPath(head); ctx.strokePath()

    for (y, w, a) in [(CGFloat(128), CGFloat(72), CGFloat(0.55)), (152, 46, 0.3)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 51, y: y, width: w, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(color(0x2b2b30, a)); ctx.fillPath()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
