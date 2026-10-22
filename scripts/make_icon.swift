// Draws the KeelMac app icon (design/canvas/About.dc.html) into App/Resources/Assets.xcassets/AppIcon.appiconset.
// Hull-ink rounded square, verdigris water across the lower part, and the Plimsoll mark (ring and line) on the waterline.
// Usage: swift scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
let hull = rgb(0x21, 0x1C, 0x16)
let hullLight = rgb(0x33, 0x2D, 0x26)
let verdigris = rgb(0x00, 0x71, 0x67)
let sail = rgb(0xF2, 0xF0, 0xEC)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body, radius ~ 185/1024.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = s * 185 / 1024
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow as on system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 24 / 1024, color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(path); ctx.setFillColor(hull); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    // Subtle vertical light on the hull (a single flat tone reads as a hole at small sizes).
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [hullLight, hull] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    // Water: lower 38% of the body.
    let waterline = body.minY + body.height * 0.40
    ctx.setFillColor(verdigris)
    ctx.fill(CGRect(x: body.minX, y: body.minY, width: body.width, height: waterline - body.minY))
    ctx.restoreGState()

    // Plimsoll mark centred on the waterline.
    let stroke = s * 46 / 1024
    let ringR = body.width * 0.20
    let c = CGPoint(x: body.midX, y: waterline)
    ctx.setStrokeColor(sail); ctx.setLineWidth(stroke); ctx.setLineCap(.butt)
    ctx.strokeEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR))
    let half = body.width * 0.36
    ctx.move(to: CGPoint(x: c.x - half, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + half, y: c.y)); ctx.strokePath()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(px).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: set.appendingPathComponent("Contents.json"))
try render(1024).write(to: root.appendingPathComponent("site/public/icon.png"))
print("wrote AppIcon (10 sizes) and site/public/icon.png")
