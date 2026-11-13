import SwiftUI

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

// MARK: - Range profile

struct FFTPlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let d = model.derived, p = model.params, unit = model.params.rangeUnit
        let trace = model.trace, hold = model.hold, st = model.stats
        Canvas { ctx, size in
            let top = p.dbTop, bottom = p.dbTop - max(10, p.dbRange)
            let uf = unit.perMeter
            let ax = drawAxes(ctx, size: size, x: (0, d.rShow * uf), y: (bottom, top), xLabel: "range (\(unit.abbreviation))", yLabel: "dBFS")
            var c = ctx
            c.clip(to: Path(ax.rect))
            func line(_ db: [Float]) -> Path {
                var path = Path()
                for k in 0..<min(db.count, d.nBins) {
                    let pt = CGPoint(x: ax.px(Double(k) * d.metersPerBin * uf), y: ax.py(min(top, max(bottom, Double(db[k])))))
                    k == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                return path
            }
            if let hold { c.stroke(line(hold), with: .color(.gray), lineWidth: 1) }
            if let trace { c.stroke(line(trace), with: .color(.accentColor), lineWidth: 1.4) }
            if p.rangeMethod == .matrixPencil {
                for t in model.pencilTargets where t.range <= d.rShow {
                    let x = ax.px(t.range * uf), y = ax.py(min(top, max(bottom, t.db)))
                    var tri = Path()
                    tri.move(to: CGPoint(x: x, y: y - 1)); tri.addLine(to: CGPoint(x: x - 4, y: y - 8)); tri.addLine(to: CGPoint(x: x + 4, y: y - 8)); tri.closeSubpath()
                    c.fill(tri, with: .color(.red))
                }
            }
            if let r = st.peakRange, let db = st.peakDB {
                let pt = CGPoint(x: ax.px(r * uf), y: ax.py(min(top, max(bottom, db))))
                c.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(.orange))
            }
            strokeBorder(ctx, ax)
        }
    }
}

// MARK: - RTI

struct RTIPlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let d = model.derived, img = model.rtiImage, unit = model.params.rangeUnit
        let period = 2 * model.params.tpMs / 1000   // nominal sync period, so the axis does not jitter
        let ageMax = Double(model.rti.height * model.rti.pulsesPerRow) * period
        let top = model.params.dbTop, range = max(10, model.params.rtiDbRange)
        Canvas { ctx, size in
            let barSpace: CGFloat = 64
            let ax = drawAxes(ctx, size: CGSize(width: max(80, size.width - barSpace), height: size.height),
                              x: (0, d.rShow * unit.perMeter), y: (0, ageMax), xLabel: "range (\(unit.abbreviation))", yLabel: "age (s)", yDown: true)
            // The image holds every range bin; crop it to the bins shown.
            if let full = img, let img = full.cropping(to: CGRect(x: 0, y: 0, width: min(full.width, d.nBins), height: full.height)) {
                let frac = min(1, Double(img.width) * d.metersPerBin / d.rShow)
                ctx.draw(Image(decorative: img, scale: 1).interpolation(.low),
                         in: CGRect(x: ax.rect.minX, y: ax.rect.minY, width: ax.rect.width * frac, height: ax.rect.height))
            }
            strokeBorder(ctx, ax)
            drawColorBar(ctx, rect: CGRect(x: ax.rect.maxX + 14, y: ax.rect.minY, width: 12, height: ax.rect.height),
                         top: top, range: range)
        }
    }
}

// MARK: - Range-Doppler

struct RangeDopplerPlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let d = model.derived, unit = model.params.rangeUnit, rd = model.rangeDoppler
        let top = model.params.dbTop, range = max(10, model.params.rdDbRange)
        let m = max(8, model.params.rdPulses)
        let dv = wavelength(model.params) / 2 / (Double(m) * 2 * model.params.tpMs / 1000)
        let collected = model.rdCollected
        let showX = model.params.rdShowScatterers
        Canvas { ctx, size in
            let barSpace: CGFloat = 64
            let uf = unit.perMeter
            let step = rd?.velocityStep ?? dv
            let vTop = (rd?.topVelocity ?? Double(m / 2) * dv) + step / 2
            let vBottom = vTop - Double(rd?.rows ?? m) * step
            let ax = drawAxes(ctx, size: CGSize(width: max(80, size.width - barSpace), height: size.height),
                              x: (0, d.rShow * uf), y: (vBottom, vTop),   // velocity always in m/s
                              xLabel: "range (\(unit.abbreviation))", yLabel: "velocity (m/s, + = approaching)")
            if let rd {
                let frac = min(1, Double(rd.image.width) * d.metersPerBin / d.rShow)
                ctx.draw(Image(decorative: rd.image, scale: 1).interpolation(.none),
                         in: CGRect(x: ax.rect.minX, y: ax.rect.minY, width: ax.rect.width * frac, height: ax.rect.height))
                var c = ctx
                c.clip(to: Path(ax.rect))
                let y0 = ax.py(0)
                c.stroke(Path { $0.move(to: CGPoint(x: ax.rect.minX, y: y0)); $0.addLine(to: CGPoint(x: ax.rect.maxX, y: y0)) },
                         with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                for s in rd.scatterers where showX && s.range <= d.rShow {
                    let pt = CGPoint(x: ax.px(s.range * uf), y: ax.py(s.velocity))
                    c.stroke(Path { $0.move(to: CGPoint(x: pt.x - 3, y: pt.y - 3)); $0.addLine(to: CGPoint(x: pt.x + 3, y: pt.y + 3))
                                    $0.move(to: CGPoint(x: pt.x - 3, y: pt.y + 3)); $0.addLine(to: CGPoint(x: pt.x + 3, y: pt.y - 3)) },
                             with: .color(.white), lineWidth: 1)
                }
                if let p = rd.peak, p.range <= d.rShow {
                    let pt = CGPoint(x: ax.px(p.range * uf), y: ax.py(p.velocity))
                    c.stroke(Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 1.5)
                }
            } else {
                ctx.draw(Text(model.source == .none ? "Start capture to build the range-Doppler map"
                                                    : "Collecting pulses… \(min(collected, m)) of \(m)")
                            .font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
            }
            strokeBorder(ctx, ax)
            drawColorBar(ctx, rect: CGRect(x: ax.rect.maxX + 14, y: ax.rect.minY, width: 12, height: ax.rect.height),
                         top: top, range: range)
        }
    }
}

// MARK: - Scope

struct ScopePlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let snap = model.scope
        Canvas { ctx, size in
            guard let s = snap, s.left.count > 1 else {
                let ax = drawAxes(ctx, size: size, x: (0, 20), y: (-1, 1), xLabel: "time from trigger (ms)", yLabel: "full scale")
                strokeBorder(ctx, ax); return
            }
            let n = s.left.count
            let a = 1.0   // the ADC's full scale: Core Audio delivers samples in -1 ... +1
            let tmin = -Double(s.pre) / s.fs * 1e3, tmax = Double(n - s.pre) / s.fs * 1e3
            let ax = drawAxes(ctx, size: size, x: (tmin, tmax), y: (-a, a), xLabel: "time from trigger (ms)", yLabel: "full scale")
            var c = ctx
            c.clip(to: Path(ax.rect))
            let step = max(1, n / Int(max(200, ax.rect.width * 2)))
            for (arr, color) in [(s.left, Color.accentColor), (s.right, Color.orange)] {
                var path = Path()
                var k = 0
                while k < n {
                    let pt = CGPoint(x: ax.px(tmin + Double(k) / s.fs * 1e3), y: ax.py(Double(arr[k])))
                    k == 0 ? path.move(to: pt) : path.addLine(to: pt)
                    k += step
                }
                c.stroke(path, with: .color(color), lineWidth: 1.1)
            }
            let tEnd = Double(s.n) / s.fs * 1e3
            for t in [0, tEnd] {
                c.stroke(Path { $0.move(to: CGPoint(x: ax.px(t), y: ax.rect.minY)); $0.addLine(to: CGPoint(x: ax.px(t), y: ax.rect.maxY)) },
                         with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            strokeBorder(ctx, ax)
        }
    }
}

// MARK: - Edge zoom

struct EdgePlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let snap = model.edge
        Canvas { ctx, size in
            guard let e = snap else {
                let ax = drawAxes(ctx, size: size, x: (-4, 4), y: (-1, 1), xLabel: "samples from integer trigger", yLabel: "full scale")
                strokeBorder(ctx, ax); return
            }
            let lo = -1.0, hi = 1.0   // the ADC's full scale
            let span = Double(e.span)
            let ax = drawAxes(ctx, size: size, x: (-span, span), y: (lo, hi),
                              xLabel: "samples from integer trigger (MATLAB ii)", yLabel: "full scale")
            var c = ctx
            c.clip(to: Path(ax.rect))
            let dash = StrokeStyle(lineWidth: 1, dash: [3, 3])
            c.stroke(Path { $0.move(to: CGPoint(x: ax.rect.minX, y: ax.py(e.threshold))); $0.addLine(to: CGPoint(x: ax.rect.maxX, y: ax.py(e.threshold))) },
                     with: .color(.secondary), style: dash)
            c.stroke(Path { $0.move(to: CGPoint(x: ax.px(0), y: ax.rect.minY)); $0.addLine(to: CGPoint(x: ax.px(0), y: ax.rect.maxY)) },
                     with: .color(.secondary), style: dash)
            var path = Path()
            for (j, v) in e.fine.enumerated() {
                let pt = CGPoint(x: ax.px(-span + Double(j) / Double(e.upsample)), y: ax.py(Double(v)))
                j == 0 ? path.move(to: pt) : path.addLine(to: pt)
                c.fill(Path(CGRect(x: pt.x - 1, y: pt.y - 1, width: 2, height: 2)), with: .color(.accentColor.opacity(0.45)))
            }
            c.stroke(path, with: .color(.accentColor), lineWidth: 1.2)
            for (j, v) in e.samples.enumerated() {
                let pt = CGPoint(x: ax.px(Double(j) - span), y: ax.py(Double(v)))
                c.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(.primary))
            }
            let xe = ax.px(e.edgeOffset)
            c.stroke(Path { $0.move(to: CGPoint(x: xe, y: ax.rect.minY)); $0.addLine(to: CGPoint(x: xe, y: ax.rect.maxY)) },
                     with: .color(.orange), lineWidth: 2)
            strokeBorder(ctx, ax)
        }
    }
}

// MARK: - PGA phase error

struct PGAPlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let phase = model.pgaPhase, d = model.derived
        let waiting = model.pgaUpdates == 0 ? "Collecting pulses…" : "No estimate has passed the checks yet"
        Canvas { ctx, size in
            let tEnd = Double(d.n) / d.fs * 1e3
            guard let phi = phase, phi.count > 1 else {
                let ax = drawAxes(ctx, size: size, x: (0, tEnd), y: (-1, 1), xLabel: "time in sweep (ms)", yLabel: "rad")
                ctx.draw(Text(waiting).font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
                strokeBorder(ctx, ax); return
            }
            let mx = max(0.2, Double(phi.map { abs($0) }.max() ?? 1) * 1.1)
            let ax = drawAxes(ctx, size: size, x: (0, tEnd), y: (-mx, mx), xLabel: "time in sweep (ms)", yLabel: "rad")
            var c = ctx
            c.clip(to: Path(ax.rect))
            var path = Path()
            for (t, v) in phi.enumerated() {
                let pt = CGPoint(x: ax.px(Double(t) / d.fs * 1e3), y: ax.py(Double(v)))
                t == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            c.stroke(path, with: .color(.purple), lineWidth: 1.4)
            strokeBorder(ctx, ax)
        }
    }
}

/// Slow-time (Doppler) PGA correction per pulse of the newest range-Doppler map.
struct SlowPGAPlot: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let phase = model.rangeDoppler?.slowPhase
        let pri = 2 * model.params.tpMs / 1000
        Canvas { ctx, size in
            let tEnd = Double(max(2, phase?.count ?? model.params.rdPulses) - 1) * pri
            guard let phi = phase, phi.count > 1 else {
                let ax = drawAxes(ctx, size: size, x: (0, tEnd), y: (-1, 1), xLabel: "time across map (s)", yLabel: "rad")
                ctx.draw(Text("Waiting for a range-Doppler map…").font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
                strokeBorder(ctx, ax); return
            }
            let mx = max(0.2, Double(phi.map { abs($0) }.max() ?? 1) * 1.1)
            let ax = drawAxes(ctx, size: size, x: (0, tEnd), y: (-mx, mx), xLabel: "time across map (s)", yLabel: "rad")
            var c = ctx
            c.clip(to: Path(ax.rect))
            var path = Path()
            for (j, v) in phi.enumerated() {
                let pt = CGPoint(x: ax.px(Double(j) * pri), y: ax.py(Double(v)))
                j == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            c.stroke(path, with: .color(.teal), lineWidth: 1.4)
            strokeBorder(ctx, ax)
        }
    }
}

/// Vertical jet colour bar: `top` dB at the top, `top - range` at the bottom.
func drawColorBar(_ ctx: GraphicsContext, rect: CGRect, top: Double, range: Double) {
    let steps = 128
    let h = rect.height / CGFloat(steps)
    for s in 0..<steps {
        let i = Int((Double(steps - 1 - s) / Double(steps - 1) * 255).rounded())
        let c = Color(red: Double(RTIBuffer.jet[i * 4]) / 255, green: Double(RTIBuffer.jet[i * 4 + 1]) / 255,
                      blue: Double(RTIBuffer.jet[i * 4 + 2]) / 255)
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
