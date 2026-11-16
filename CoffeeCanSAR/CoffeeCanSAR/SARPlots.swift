import SwiftUI

// Plot helpers copied from Coffee Can Radar RTI (Plots.swift), so this app stands alone.

enum Jet {
    static let jet: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
        let v = Double(i) / 255
        let c = { (x: Double) in UInt8(min(1, max(0, 1.5 - abs(4 * v - x))) * 255) }
        return [c(3), c(2), c(1), 255]
    }
}

// MARK: - Axes

struct PlotAxes {
    let rect: CGRect
    let x0: Double, x1: Double, y0: Double, y1: Double
    var yDown = false   // y0 at the top

    func px(_ v: Double) -> CGFloat { rect.minX + CGFloat((v - x0) / (x1 - x0)) * rect.width }
    func py(_ v: Double) -> CGFloat {
        let f = CGFloat((v - y0) / (y1 - y0))
        return yDown ? rect.minY + f * rect.height : rect.maxY - f * rect.height
    }
}

func niceStep(_ span: Double, _ count: Double) -> Double {
    let raw = span / max(1, count)
    let p = pow(10, floor(log10(raw)))
    let m = raw / p
    return (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * p
}

private func tickLabel(_ v: Double, _ step: Double) -> String {
    let decimals = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3
    return String(format: "%.\(decimals)f", abs(v) < step * 1e-6 ? 0 : v)
}

/// Draws background, grid, tick labels and axis titles; returns the data-to-view mapping.
func drawAxes(_ ctx: GraphicsContext, size: CGSize, x: (Double, Double), y: (Double, Double),
              xLabel: String, yLabel: String, yDown: Bool = false) -> PlotAxes {
    let rect = CGRect(x: 52, y: 6, width: max(10, size.width - 62), height: max(10, size.height - 40))
    let x1 = x.1 > x.0 ? x.1 : x.0 + 1, y1 = y.1 > y.0 ? y.1 : y.0 + 1
    let ax = PlotAxes(rect: rect, x0: x.0, x1: x1, y0: y.0, y1: y1, yDown: yDown)
    ctx.fill(Path(rect), with: .color(Color(nsColor: .textBackgroundColor)))

    let grid = GraphicsContext.Shading.color(.secondary.opacity(0.22))
    let sx = niceStep(x1 - x.0, Double(rect.width / 80))
    var v = (x.0 / sx).rounded(.up) * sx
    while v <= x1 + sx * 1e-6 {
        let px = ax.px(v)
        ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: rect.minY)); $0.addLine(to: CGPoint(x: px, y: rect.maxY)) },
                   with: grid, lineWidth: 0.5)
        ctx.draw(Text(tickLabel(v, sx)).font(.system(size: 10)).foregroundStyle(.secondary),
                 at: CGPoint(x: px, y: rect.maxY + 3), anchor: .top)
        v += sx
    }
    let sy = niceStep(y1 - y.0, Double(rect.height / 36))
    v = (y.0 / sy).rounded(.up) * sy
    while v <= y1 + sy * 1e-6 {
        let py = ax.py(v)
        ctx.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: py)); $0.addLine(to: CGPoint(x: rect.maxX, y: py)) },
                   with: grid, lineWidth: 0.5)
        ctx.draw(Text(tickLabel(v, sy)).font(.system(size: 10)).foregroundStyle(.secondary),
                 at: CGPoint(x: rect.minX - 4, y: py), anchor: .trailing)
        v += sy
    }
    ctx.draw(Text(xLabel).font(.system(size: 11)).foregroundStyle(.secondary),
             at: CGPoint(x: rect.midX, y: size.height - 2), anchor: .bottom)
    var rc = ctx
    rc.translateBy(x: 10, y: rect.midY)
    rc.rotate(by: .degrees(-90))
    rc.draw(Text(yLabel).font(.system(size: 11)).foregroundStyle(.secondary), at: .zero, anchor: .center)
    return ax
}

func strokeBorder(_ ctx: GraphicsContext, _ ax: PlotAxes) {
    ctx.stroke(Path(ax.rect), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
}

/// Vertical jet colour bar: `top` dB at the top, `top - range` at the bottom.
func drawColorBar(_ ctx: GraphicsContext, rect: CGRect, top: Double, range: Double) {
    let steps = 128
    let h = rect.height / CGFloat(steps)
    for s in 0..<steps {
        let i = Int((Double(steps - 1 - s) / Double(steps - 1) * 255).rounded())
        let c = Color(red: Double(Jet.jet[i * 4]) / 255, green: Double(Jet.jet[i * 4 + 1]) / 255,
                      blue: Double(Jet.jet[i * 4 + 2]) / 255)
        ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY + CGFloat(s) * h, width: rect.width, height: h + 0.5)), with: .color(c))
    }
    ctx.stroke(Path(rect), with: .color(.secondary.opacity(0.5)), lineWidth: 1)
    let lo = top - range
    let step = niceStep(range, Double(rect.height / 36))
    var v = (lo / step).rounded(.up) * step
    while v <= top + step * 1e-6 {
        let y = rect.maxY - CGFloat((v - lo) / range) * rect.height
        ctx.stroke(Path { $0.move(to: CGPoint(x: rect.maxX, y: y)); $0.addLine(to: CGPoint(x: rect.maxX + 3, y: y)) },
                   with: .color(.secondary), lineWidth: 1)
        ctx.draw(Text(String(format: "%.0f", v)).font(.system(size: 10)).foregroundStyle(.secondary),
                 at: CGPoint(x: rect.maxX + 5, y: y), anchor: .leading)
        v += step
    }
    ctx.draw(Text("dB").font(.system(size: 10)).foregroundStyle(.secondary),
             at: CGPoint(x: rect.midX, y: rect.maxY + 4), anchor: .top)
}
