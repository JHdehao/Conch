import AppKit
import CoreGraphics
import Foundation

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon art into a square of side `s` (origin bottom-left): a big
/// ivory C on Claude's terracotta, with a terminal prompt `>_` inside it.
func drawArt(_ ctx: CGContext, s: CGFloat) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Terracotta (the app's accent, #D97757), a touch lighter at the top.
    let background = CGGradient(colorsSpace: space, colors: [color(0xE38B6D), color(0xD97757), color(0xC7654A)] as CFArray,
                                locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.3, y: s * 0.9), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.3, y: s * 0.9), endRadius: s * 0.7, options: [])

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x7A2E18, 0.35))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // The C: a thick round-capped ring open to the right, nudged right so its
    // weight (all on the left) looks centred.
    let center = CGPoint(x: s * 0.525, y: s * 0.5)
    let gap: CGFloat = 44 * .pi / 180
    ctx.setLineWidth(s * 0.14)
    ctx.setStrokeColor(color(0xFAF9F5))
    ctx.addArc(center: center, radius: s * 0.29, startAngle: gap, endAngle: 2 * .pi - gap, clockwise: false)
    ctx.strokePath()

    // The prompt, in Claude's charcoal, centred in the C's counter.
    let h = s * 0.078
    let mid = CGPoint(x: center.x - s * 0.005, y: center.y + s * 0.012)
    ctx.setLineWidth(s * 0.05)
    ctx.setStrokeColor(color(0x262624))
    ctx.move(to: CGPoint(x: mid.x - s * 0.11, y: mid.y + h))
    ctx.addLine(to: CGPoint(x: mid.x - s * 0.032, y: mid.y))
    ctx.addLine(to: CGPoint(x: mid.x - s * 0.11, y: mid.y - h))
    ctx.move(to: CGPoint(x: mid.x + s * 0.012, y: mid.y - h))
    ctx.addLine(to: CGPoint(x: mid.x + s * 0.105, y: mid.y - h))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int, mac: Bool) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    if mac {
        // macOS icon grid: 824pt squircle-ish rounded rect inside 1024 with a drop shadow.
        let inset = s * 100 / 1024
        let rect = CGRect(x: inset, y: inset + s * 0.012, width: s - inset * 2, height: s - inset * 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: color(0x000000, 0.35))
        ctx.addPath(shape); ctx.setFillColor(color(0xD97757)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape); ctx.clip()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        drawArt(ctx, s: rect.width)
    } else {
        drawArt(ctx, s: s)
    }
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try render(size: 1024, mac: false).write(to: URL(fileURLWithPath: "\(out)/icon-ios-1024.png"))
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size, mac: true).write(to: URL(fileURLWithPath: "\(out)/icon-\(size).png"))
}
