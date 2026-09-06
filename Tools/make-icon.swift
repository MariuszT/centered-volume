// Draws the app icon and writes it into the asset catalogue.
//
// The icon is the volume track itself: solid white on the left, faded on the
// right, with a round thumb dead centre on the vertical axis. Centring is the
// whole point of the app, so it is the whole point of the icon.
//
//     swift Tools/make-icon.swift CenteredVolume/Assets.xcassets/AppIcon.appiconset
import AppKit

let side: CGFloat = 1024

// Apple's icon grid: the body sits in 824 of the 1024 canvas, leaving the margin
// the system expects. The corner is a superellipse rather than a circular arc.
// Sampling the alpha channel of a stock macOS icon puts the exponent at about
// 5.1, and that is what makes the shoulder run long instead of stopping short.
let bodyInset: CGFloat = 100
let squircleExponent: CGFloat = 5.1

// How much of the drawing survives. A 16 point icon has room for one idea, so
// the thumb and the fade both give way to a single solid ramp; the rim and the
// drop shadow only arrive once there are pixels to resolve them.
enum Detail { case minimal, medium, full }

func detail(for pixels: CGFloat) -> Detail {
    if pixels < 24 { return .minimal }
    if pixels < 96 { return .medium }
    return .full
}

func squircle(in rect: NSRect) -> NSBezierPath {
    let a = rect.width / 2, b = rect.height / 2
    let path = NSBezierPath()
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let x = rect.midX + a * copysign(pow(abs(cos(t)), 2 / squircleExponent), cos(t))
        let y = rect.midY + b * copysign(pow(abs(sin(t)), 2 / squircleExponent), sin(t))
        step == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

let body = NSRect(x: bodyInset, y: bodyInset, width: side - 2 * bodyInset, height: side - 2 * bodyInset)

func background(_ level: Detail, top: NSColor, bottom: NSColor, wash: CGFloat = 0.14) {
    NSGraphicsContext.saveGraphicsState()
    squircle(in: body).setClip()
    NSGradient(starting: top, ending: bottom)!.draw(in: body, angle: -90)
    NSGradient(starting: NSColor(white: 1, alpha: wash), ending: NSColor(white: 1, alpha: 0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    if level == .full {
        let rim = squircle(in: body.insetBy(dx: 2, dy: 2))
        rim.lineWidth = 4
        NSColor(white: 1, alpha: 0.20).setStroke()
        rim.stroke()
    }
}

// Fill+stroke of the same colour double up along the edge when the colour is
// translucent, which draws an outline nobody asked for. Composing the shape at
// full opacity inside a transparency layer and fading the layer avoids that.
func faded(_ ctx: CGContext, _ alpha: CGFloat, _ draw: () -> Void) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func punch(_ ctx: CGContext, _ path: NSBezierPath) {
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    NSColor.black.setFill()
    path.fill()
    ctx.restoreGState()
}

// The volume track as the whole icon: the fill stops on the centre line and
// the thumb sits on the centre line. (An earlier pass put detent marks above
// and below it; they turned the ramp into a compass rose, and the thumb on
// the axis already says where the middle is, so they were dropped.)

func drawIcon(_ ctx: CGContext, _ level: Detail) {
    background(level, top: NSColor(srgbRed: 0.31, green: 0.57, blue: 0.98, alpha: 1),
               bottom: NSColor(srgbRed: 0.07, green: 0.17, blue: 0.54, alpha: 1))
    if level == .full {
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                      color: NSColor(srgbRed: 0.02, green: 0.05, blue: 0.16, alpha: 0.42).cgColor)
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    func ramp(_ half: CGFloat, _ h0: CGFloat, _ h1: CGFloat, _ y: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: side / 2 - half, y: y - h0))
        p.line(to: NSPoint(x: side / 2 + half, y: y - h1))
        p.line(to: NSPoint(x: side / 2 + half, y: y + h1))
        p.line(to: NSPoint(x: side / 2 - half, y: y + h0))
        p.close()
        p.lineWidth = 30
        p.lineJoinStyle = .round
        return p
    }
    func stamp(_ p: NSBezierPath) { NSColor.white.setFill(); NSColor.white.setStroke(); p.fill(); p.stroke() }
    func leftHalf(_ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side / 2, height: side)).setClip()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    switch level {
    case .full:
        let r = ramp(324, 22, 116, 512)
        faded(ctx, 0.32) { stamp(r) }
        leftHalf { stamp(r) }
        punch(ctx, circle(NSPoint(x: side / 2, y: 512), 108))
        NSColor.white.setFill()
        circle(NSPoint(x: side / 2, y: 512), 88).fill()
    case .medium:
        let r = ramp(346, 24, 132, 512)
        faded(ctx, 0.36) { stamp(r) }
        leftHalf { stamp(r) }
        punch(ctx, circle(NSPoint(x: side / 2, y: 512), 130))
        NSColor.white.setFill()
        circle(NSPoint(x: side / 2, y: 512), 104).fill()
    case .minimal:
        // Solid, undivided. Every attempt to keep the thumb at this size turned
        // the ramp into two blobs.
        stamp(ramp(362, 26, 170, 512))
    }
    ctx.endTransparencyLayer()
}

func bitmap(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    return rep
}

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = bitmap(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / side, y: CGFloat(pixels) / side)
    drawIcon(ctx, detail(for: CGFloat(pixels)))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ pixels: Int) -> Data {
    render(pixels).representation(using: .png, properties: [:])!
}

let target = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "CenteredVolume/Assets.xcassets/AppIcon.appiconset"
let directory = URL(fileURLWithPath: target)

for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(point)x\(point).png" : "icon_\(point)x\(point)@2x.png"
    try! png(point * scale).write(to: directory.appendingPathComponent(name))
    print("wrote \(name)")
}

// A single large copy for the README and the website.
try! FileManager.default.createDirectory(
    atPath: "Screenshots", withIntermediateDirectories: true
)
try! png(1024).write(to: URL(fileURLWithPath: "Screenshots/icon.png"))
print("wrote Screenshots/icon.png")
