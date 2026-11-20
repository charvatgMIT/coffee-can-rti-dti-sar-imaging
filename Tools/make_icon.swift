// Draws the app icon (a Coffee Can Radar antenna: a coffee can on its side with radar waves).
// Regenerate with:  swiftc -O Tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon icon_1024.png

import AppKit
import CoreGraphics
import CoreText

// Coffee can on its side, open end to the right, radar waves leaving it. 1024 x 1024, y up.
let W = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }

// background: macOS-style rounded square with a soft shadow
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bgPath); ctx.setFillColor(rgb(0x0E2F52)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
ctx.drawLinearGradient(grad([rgb(0x1B4F86), rgb(0x0A2340)], [0, 1]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// faint range rings
for (i, r) in [180.0, 300, 420].enumerated() {
    ctx.setStrokeColor(rgb(0x7FB8FF, 0.08 - CGFloat(i) * 0.015)); ctx.setLineWidth(3)
    ctx.addEllipse(in: CGRect(x: 560 - r, y: 512 - r, width: 2 * r, height: 2 * r)); ctx.strokePath()
}
ctx.restoreGState()

// can geometry: axis horizontal at y = cy, body from x0 (back) to x1 (open front), cross-section ellipse rx x ry
let cy: CGFloat = 512, ry: CGFloat = 170, rx: CGFloat = 58
let x0: CGFloat = 215, x1: CGFloat = 575
// metal shading across the cylinder (top highlight, dark underside)
let metal = grad([rgb(0x5E6670), rgb(0xE9EDF1), rgb(0xFFFFFF), rgb(0xB9C0C8), rgb(0x6C747E), rgb(0x3A4048)], [0, 0.18, 0.28, 0.55, 0.85, 1])
let red = grad([rgb(0x6E0E12), rgb(0xD8323A), rgb(0xFF6A6A), rgb(0xC0232B), rgb(0x7E0F15), rgb(0x4A080B)], [0, 0.18, 0.28, 0.55, 0.85, 1])

// soft shadow under the can
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 40, color: rgb(0x000000, 0.55))
let body = CGMutablePath()
body.addEllipse(in: CGRect(x: x0 - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
body.addRect(CGRect(x: x0, y: cy - ry, width: x1 - x0, height: 2 * ry))
ctx.addPath(body); ctx.setFillColor(rgb(0x808890)); ctx.fillPath()
ctx.restoreGState()

func fillBand(_ path: CGPath, _ g: CGGradient) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: cy + ry), end: CGPoint(x: 0, y: cy - ry), options: [])
    ctx.restoreGState()
}
fillBand(body, metal)

/// Region between the visible (right-hand) halves of two cross-sections at xa < xb.
func band(_ xa: CGFloat, _ xb: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: xa, y: cy + ry))
    p.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: 0, clockwise: false) // placeholder replaced below
    return p
}
func halfEllipse(_ p: CGMutablePath, x: CGFloat, down: Bool) {
    // right half of the ellipse centred at (x, cy), from top to bottom (down) or bottom to top
    let n = 48
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n) * .pi
        let a = down ? .pi / 2 - t : -.pi / 2 + t
        let pt = CGPoint(x: x + rx * cos(a), y: cy + ry * sin(a))
        if i == 0 && p.isEmpty { p.move(to: pt) } else { p.addLine(to: pt) }
    }
}
// red label between two cross-sections: both edges are right half-ellipses (bulging toward the viewer)
let lx0: CGFloat = 300, lx1: CGFloat = 470
func halfPoints(_ x: CGFloat, down: Bool) -> [CGPoint] {
    (0...48).map { i in
        let t = CGFloat(i) / 48 * .pi
        let a = down ? .pi / 2 - t : -.pi / 2 + t
        return CGPoint(x: x + rx * cos(a), y: cy + ry * sin(a))
    }
}
let lab = CGMutablePath()
lab.addLines(between: halfPoints(lx1, down: true) + halfPoints(lx0, down: false))
lab.closeSubpath()
ctx.saveGState(); ctx.addPath(lab); ctx.clip()
ctx.drawLinearGradient(red, start: CGPoint(x: 0, y: cy + ry), end: CGPoint(x: 0, y: cy - ry), options: [])
ctx.restoreGState()
// label edge lines
for x in [lx0, lx1] {
    let p = CGMutablePath(); halfEllipse(p, x: x, down: true)
    ctx.addPath(p); ctx.setStrokeColor(rgb(0xFFD27A, 0.9)); ctx.setLineWidth(6); ctx.strokePath()
}
// label text, following the cylinder's curvature a little (squeezed vertically toward the edges is overkill: keep flat)
// fit the text between the label's left edge and the can's mouth, at the cylinder's front
let visL = lx0 + rx + 8, visR = x1 - rx - 8
var size: CGFloat = 60
var line: CTLine, tb: CGRect
repeat {
    let font = CTFontCreateWithName("Avenir Next Condensed Heavy" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: rgb(0xFFF4DC), .kern: 1.5]
    line = CTLineCreateWithAttributedString(NSAttributedString(string: "COFFEE", attributes: attrs))
    tb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    size -= 1
} while tb.width > visR - visL
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 4, color: rgb(0x000000, 0.5))
ctx.textPosition = CGPoint(x: (visL + visR) / 2 - tb.width / 2 - tb.minX, y: cy - tb.height / 2 - tb.minY)
CTLineDraw(line, ctx)
ctx.restoreGState()

// ribs near both ends
for (x, w) in [(245.0, 5.0), (266, 5), (510, 5), (530, 5)] as [(CGFloat, CGFloat)] {
    let p = CGMutablePath(); halfEllipse(p, x: x, down: true)
    ctx.addPath(p); ctx.setStrokeColor(rgb(0x2E343B, 0.55)); ctx.setLineWidth(w); ctx.strokePath()
    let q = CGMutablePath(); halfEllipse(q, x: x + 5, down: true)
    ctx.addPath(q); ctx.setStrokeColor(rgb(0xFFFFFF, 0.45)); ctx.setLineWidth(3); ctx.strokePath()
}

// open front end: dark interior inside a bright rolled rim
let mouth = CGRect(x: x1 - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)
ctx.saveGState(); ctx.addEllipse(in: mouth); ctx.clip()
ctx.drawLinearGradient(grad([rgb(0x0D0F12), rgb(0x2F353D), rgb(0x5B636D)], [0, 0.6, 1]),
                       start: CGPoint(x: x1 - rx, y: cy + ry), end: CGPoint(x: x1 + rx, y: cy - ry), options: [])
// the probe (quarter-wave monopole on an SMA jack) inside
ctx.setFillColor(rgb(0xC9A23A)); ctx.fill(CGRect(x: x1 - 18, y: cy - 8, width: 22, height: 16))
ctx.setStrokeColor(rgb(0xF4D27A)); ctx.setLineWidth(9); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: x1 - 8, y: cy)); ctx.addLine(to: CGPoint(x: x1 - 8, y: cy + 92)); ctx.strokePath()
ctx.restoreGState()
ctx.addEllipse(in: mouth.insetBy(dx: 2, dy: 2)); ctx.setStrokeColor(rgb(0xF2F5F8)); ctx.setLineWidth(14); ctx.strokePath()
ctx.addEllipse(in: mouth.insetBy(dx: 9, dy: 9)); ctx.setStrokeColor(rgb(0x7A828C)); ctx.setLineWidth(4); ctx.strokePath()

// radar waves out of the open end
let c = CGPoint(x: x1 + 20, y: cy)
for (i, r) in [CGFloat(110), 190, 270].enumerated() {
    let a = CGFloat(34) * .pi / 180
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x3DFFA6, 0.8))
    ctx.setStrokeColor(rgb(0x5CFFB4, 1 - CGFloat(i) * 0.22)); ctx.setLineWidth(28 - CGFloat(i) * 5); ctx.setLineCap(.round)
    ctx.addArc(center: c, radius: r, startAngle: -a, endAngle: a, clockwise: false); ctx.strokePath()
    ctx.restoreGState()
}

let img = ctx.makeImage()!
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
