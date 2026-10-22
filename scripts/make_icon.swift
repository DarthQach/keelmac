// Draws the KeelMac app icon (docs/forge/03-design.md › App icon) into App/Resources/Assets.xcassets/AppIcon.appiconset.
// Dark-theme palette from design/tokens.css: charcoal body, deep verdigris water across the lower part,
// a bright waterline, and the Plimsoll mark (ring and line) on it.
// Usage: swift scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// OKLCH (as written in tokens.css) to an sRGB CGColor.
func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: CGFloat = 1) -> CGColor {
    let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
    let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
    let lin = [4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
               -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
               -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_]
    let g = lin.map { v -> CGFloat in
        let v = min(max(v, 0), 1)
        return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }
    return CGColor(srgbRed: g[0], green: g[1], blue: g[2], alpha: alpha)
}

// Body: dark --surface-muted at the top to --bg at the waterline (neutral, chroma 0).
let bodyTop = oklch(0.310, 0, 0)
let bodyBottom = oklch(0.205, 0, 0)
// Water: dark --water at the surface, deepening with depth.
let waterTop = oklch(0.430, 0.060, 190)
let waterBottom = oklch(0.250, 0.045, 195)
// Waterline: dark --water-edge / --accent.
let waterEdge = oklch(0.740, 0.095, 185)
let mark = oklch(0.990, 0, 0)
let markUnderwater = oklch(0.860, 0.050, 188)

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let u = s / 1024 // one unit of the 1024 design grid
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body, radius ~ 185/1024.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let radius = 185 * u
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let waterline = (body.minY + body.height * 0.40).rounded()
    let small = px <= 64

    // Soft drop shadow as on system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(bodyBottom); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    // Charcoal body lit from the top, plus a faint glow behind the mark.
    ctx.drawLinearGradient(gradient([bodyTop, bodyBottom], [0, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: waterline), options: [])
    ctx.drawRadialGradient(gradient([oklch(0.740, 0.095, 185, alpha: 0.10), oklch(0.740, 0.095, 185, alpha: 0)], [0, 1]),
                           startCenter: CGPoint(x: body.midX, y: waterline), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: waterline), endRadius: 380 * u, options: [])
    // Water: lower 40% of the body, darker with depth.
    let water = CGRect(x: body.minX, y: body.minY, width: body.width, height: waterline - body.minY)
    ctx.saveGState()
    ctx.clip(to: water)
    ctx.drawLinearGradient(gradient([waterTop, waterBottom], [0, 1]),
                           start: CGPoint(x: 0, y: waterline), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()
    // Bright waterline with a soft glow above it.
    let edge = max(1, (small ? 18 : 10) * u)
    ctx.drawLinearGradient(gradient([oklch(0.740, 0.095, 185, alpha: 0.20), oklch(0.740, 0.095, 185, alpha: 0.06), oklch(0.740, 0.095, 185, alpha: 0)], [0, 0.4, 1]),
                           start: CGPoint(x: 0, y: waterline), end: CGPoint(x: 0, y: waterline + 120 * u), options: [])
    ctx.setFillColor(waterEdge)
    ctx.fill(CGRect(x: body.minX, y: waterline - edge / 2, width: body.width, height: edge))
    ctx.restoreGState()

    // Plimsoll mark centred on the waterline: white above water, tinted by the water below it.
    let stroke = (small ? 64 : 48) * u
    let ringR = 165 * u
    let half = 300 * u
    let c = CGPoint(x: body.midX, y: waterline)
    let markPath = CGMutablePath()
    markPath.addEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR))
    markPath.move(to: CGPoint(x: c.x - half, y: c.y)); markPath.addLine(to: CGPoint(x: c.x + half, y: c.y))
    let strokedMark = markPath.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 1)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(strokedMark); ctx.setFillColor(mark); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: s, height: waterline - stroke / 2))
    ctx.addPath(strokedMark); ctx.setFillColor(markUnderwater); ctx.fillPath()
    ctx.restoreGState()

    // Faint inner rim so the edge reads on a dark Dock, brighter at the top.
    ctx.saveGState()
    let rimWidth = max(1, 3 * u)
    let rim = CGPath(roundedRect: body.insetBy(dx: rimWidth / 2, dy: rimWidth / 2),
                     cornerWidth: radius - rimWidth / 2, cornerHeight: radius - rimWidth / 2, transform: nil)
    ctx.addPath(rim.copy(strokingWithWidth: rimWidth, lineCap: .butt, lineJoin: .round, miterLimit: 1)); ctx.clip()
    ctx.drawLinearGradient(gradient([CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.05)], [0, 1]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

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
