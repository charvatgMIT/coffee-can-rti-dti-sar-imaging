import SwiftUI

/// Strongest bin at or above `minVelocity`, refined with a parabolic fit: (m/s, dB).
func dtPeak(_ row: [Float], mpsPerCol: Double, minVelocity: Double) -> (velocity: Double, db: Double)? {
    let first = max(1, Int(ceil(minVelocity / max(1e-9, mpsPerCol))))
    guard first < row.count - 1 else { return nil }
    var kb = first
    for k in first..<row.count where row[k] > row[kb] { kb = k }
    var kf = Double(kb)
    if kb > 0 && kb + 1 < row.count {
        let a = Double(row[kb - 1]), b = Double(row[kb]), c = Double(row[kb + 1])
        let den = a - 2 * b + c
        if den < 0 { kf += 0.5 * (a - c) / den }
    }
    return (kf * mpsPerCol, Double(row[kb]))
}

private let mphPerMps = 2.236936

private func dbfs(_ rms: Double) -> String { rms > 0 ? String(format: "%.1f dBFS", 20 * log10(rms)) : "−∞ dBFS" }

/// "Doppler vs. time" tab: the CW Doppler-time intensity plot and one dwell's spectrum.
struct DopplerTimeTab: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let p = model.params, dt = model.dt
        let ifSide = p.syncOnRight ? "left" : "right"
        let source: String = {
            if let name = dt?.fileName {
                return String(format: "Recording: %@, %.1f s (%d dwells), IF from the %@ channel", name,
                              Double(dt?.rows.count ?? 0) * (dt?.dwellSeconds ?? 0), dt?.rows.count ?? 0, ifSide)
            }
            guard model.source == .live, let dt else { return "Live input idle: press Start for the UCA222, or open a recording." }
            return String(format: "Live: IF on the %@ input · next dwell %.0f%%", ifSide,
                          100 * Double(dt.waitingSamples) / Double(max(1, dt.samplesPerDwell)))
        }()
        let method = p.dtMethod == .matrixPencil ? "matrix pencil" + (dt?.medianOrder.map { String(format: " (order %.0f)", $0) } ?? "")
            : p.dtSVA ? "FFT + SVA" : "FFT, \(p.dtWindow.rawValue.lowercased()) window"
        let pga = p.dtPGA ? dt.map { " · PGA on \($0.pgaApplied) of \($0.pgaTried) dwells" } ?? " · PGA" : ""
        let ms = dt?.msPerDwell.map { String(format: " · %.1f ms/dwell", $0) } ?? ""
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { model.chooseDopplerRecording() } label: { Label("Open recording…", systemImage: "folder") }
                Button { model.showDopplerLive() } label: { Label("Live input", systemImage: "mic") }
                    .disabled(dt?.fileName == nil)
                Text(source).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.dtBusy {
                    ProgressView().controlSize(.small)
                    Text("Processing…").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            HStack(spacing: 8) {
                Text("IF input")
                Picker("IF input", selection: $model.params.syncOnRight) {
                    Text("Right").tag(false)
                    Text("Left").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                Button { model.params.syncOnRight.toggle() } label: { Label("Swap channels", systemImage: "arrow.left.arrow.right") }
                    .controlSize(.small)
                if let dt, dt.ifRMS > 0 || dt.otherRMS > 0 {
                    Text(String(format: "level: IF (%@) %@, other (%@) %@", ifSide, dbfs(dt.ifRMS), p.syncOnRight ? "right" : "left", dbfs(dt.otherRMS)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            .font(.callout)
            if let dt, dt.otherRMS > 1e-4, dt.otherRMS > 4 * dt.ifRMS {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("The \(p.syncOnRight ? "right" : "left") input is \(Int((20 * log10(dt.otherRMS / max(dt.ifRMS, 1e-9))).rounded())) dB stronger than the \(ifSide) one: the IF is probably on the \(p.syncOnRight ? "right" : "left").")
                    Button("Use the \(p.syncOnRight ? "right" : "left") input for the IF") { model.params.syncOnRight.toggle() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Spacer()
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            PlotCard(title: "Doppler vs. time (CW), speed toward or away: \(method)\(pga)",
                     detail: String(format: "Tp %.0f ms · %.3f m/s per bin · colour −%.0f…0 dB re strongest", (dt?.dwellSeconds ?? p.dtDwellMs / 1000) * 1000,
                                    dt?.mpsPerCol ?? 0, p.dtDbRange) + ms) {
                VStack(spacing: 4) {
                    DTIPlot()
                    HStack {
                        Text("Dynamic range")
                        Slider(value: Binding(get: { model.params.dtDbRange }, set: { model.params.dtDbRange = $0.rounded() }), in: 10...80)
                            .frame(maxWidth: 260)
                        Text("\(Int(p.dtDbRange)) dB").monospacedDigit().frame(width: 48, alignment: .trailing)
                        Spacer(minLength: 24)
                        Text("Max velocity")
                        Slider(value: Binding(get: { model.params.dtMaxVelocity }, set: { model.params.dtMaxVelocity = $0.rounded() }), in: 5...100)
                            .frame(maxWidth: 260)
                        Text("\(Int(p.dtMaxVelocity)) m/s").monospacedDigit().frame(width: 60, alignment: .trailing)
                        Spacer()
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
            .frame(minHeight: 300)
            DopplerSpectrumCard()
                .frame(minHeight: 170, maxHeight: 250)
        }
    }
}

struct DopplerSpectrumCard: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let dt = model.dt, p = model.params
        let idx = dt.map { model.dtSelectedRow ?? ($0.rows.count - 1) }
        let row = idx.flatMap { i in dt.flatMap { i >= 0 && i < $0.rows.count ? $0.rows[i] : nil } }
        let peak = row.flatMap { dtPeak($0, mpsPerCol: dt?.mpsPerCol ?? 1, minVelocity: max(0.5, p.dtPGAMinVelocity)) }
        let when: String = {
            guard let dt, let i = idx, i >= 0 else { return "" }
            if dt.fileName != nil { return String(format: " at t = %.2f s%@", Double(i) * dt.dwellSeconds, model.dtSelectedRow == nil ? " (last; click the plot above to pick a time)" : "") }
            return " (newest dwell)"
        }()
        PlotCard(title: "Doppler spectrum\(when), dB re strongest",
                 detail: peak.map { String(format: "strongest ≥ %.1f m/s: %.2f m/s (%.1f mph) @ %.1f dB", max(0.5, p.dtPGAMinVelocity),
                                           $0.velocity, $0.velocity * mphPerMps, $0.db - Double(dt?.maxDB ?? 0)) } ?? "") {
            DopplerSpectrumPlot(row: row, lines: idx.flatMap { i in dt.flatMap { i >= 0 && i < $0.lines.count ? $0.lines[i] : nil } } ?? [],
                                peak: peak)
        }
    }
}

struct DopplerSpectrumPlot: View {
    @EnvironmentObject var model: RadarModel
    let row: [Float]?
    let lines: [(velocity: Double, db: Double)]
    let peak: (velocity: Double, db: Double)?

    var body: some View {
        let dt = model.dt, p = model.params
        let top = Double(dt?.maxDB ?? 0), range = max(10, p.dtDbRange) + 15
        let vmax = Double(dt?.cols ?? 1) * (dt?.mpsPerCol ?? 1)
        Canvas { ctx, size in
            let ax = drawAxes(ctx, size: size, x: (0, max(1, vmax)), y: (-range, 3), xLabel: "velocity (m/s)", yLabel: "dB")
            var c = ctx
            c.clip(to: Path(ax.rect))
            if let row, let dt {
                var path = Path()
                for k in row.indices {
                    let pt = CGPoint(x: ax.px(Double(k) * dt.mpsPerCol), y: ax.py(max(-range - 1, Double(row[k]) - top)))
                    k == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                c.stroke(path, with: .color(.accentColor), lineWidth: 1.2)
                for l in lines {
                    let x = ax.px(l.velocity), y = ax.py(min(3, max(-range, l.db - top)))
                    var tri = Path()
                    tri.move(to: CGPoint(x: x, y: y - 1)); tri.addLine(to: CGPoint(x: x - 4, y: y - 8)); tri.addLine(to: CGPoint(x: x + 4, y: y - 8)); tri.closeSubpath()
                    c.fill(tri, with: .color(.red))
                }
                if let peak {
                    let pt = CGPoint(x: ax.px(peak.velocity), y: ax.py(peak.db - top))
                    c.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)), with: .color(.orange))
                }
            }
            strokeBorder(ctx, ax)
        }
    }
}

/// Doppler-time intensity: velocity across, time down (a recording, as MIT's plot) or age down (live).
struct DTIPlot: View {
    @EnvironmentObject var model: RadarModel
    private let barSpace: CGFloat = 64

    /// The data rectangle drawAxes uses for a canvas of this size.
    private func plotRect(_ size: CGSize) -> CGRect {
        CGRect(x: 52, y: 6, width: max(10, size.width - barSpace - 62), height: max(10, size.height - 40))
    }

    var body: some View {
        let dt = model.dt, p = model.params
        let live = dt?.fileName == nil
        let rows = dt?.rows.count ?? 0
        let dwell = dt?.dwellSeconds ?? p.dtDwellMs / 1000
        let span = live ? max(p.dtHistorySeconds, dwell) : max(dwell, Double(rows) * dwell)
        let vmax = Double(dt?.cols ?? 1) * (dt?.mpsPerCol ?? 1)
        let range = max(10, p.dtDbRange)
        let sel = model.dtSelectedRow
        let waiting = model.source == .live ? "Collecting the first dwell…" : "Press Start (live CW input) or open a recording"
        Canvas { ctx, size in
            let ax = drawAxes(ctx, size: CGSize(width: max(80, size.width - barSpace), height: size.height),
                              x: (0, max(1, vmax)), y: (0, span), xLabel: "velocity (m/s)",
                              yLabel: live ? "age (s)" : "time (s)", yDown: true)
            if let img = dt?.image {
                let frac = min(1, Double(rows) * dwell / span)
                ctx.draw(Image(decorative: img, scale: 1).interpolation(.none),
                         in: CGRect(x: ax.rect.minX, y: ax.rect.minY, width: ax.rect.width, height: ax.rect.height * frac))
                if !live, let sel {
                    let y = ax.py((Double(sel) + 0.5) * dwell)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: ax.rect.minX, y: y)); $0.addLine(to: CGPoint(x: ax.rect.maxX, y: y)) },
                               with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            } else {
                ctx.draw(Text(waiting).font(.caption).foregroundStyle(.secondary), at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
            }
            strokeBorder(ctx, ax)
            drawColorBar(ctx, rect: CGRect(x: ax.rect.maxX + 14, y: ax.rect.minY, width: 12, height: ax.rect.height),
                         top: 0, range: range)
        }
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        guard !live, rows > 0 else { return }
                        let r = plotRect(geo.size)
                        let t = Double((g.location.y - r.minY) / r.height) * span
                        model.dtSelectedRow = min(rows - 1, max(0, Int(t / dwell)))
                    })
            }
        }
    }
}

/// Sidebar settings for the Doppler-vs-time tab.
struct DopplerTimeSettings: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let p = model.params
        let lam = speedOfLight / (max(100, p.dtCarrierMHz) * 1e6)
        let tp = max(0.02, p.dtDwellMs / 1000)
        let vco = VCO.volts(atMHz: p.dtCarrierMHz).map { String(format: "Vtune ≈ %.2f V on the %@ typical curve. ", $0, VCO.name) } ?? "Outside the VCO's 0–5 V range. "
        Section("Doppler vs. time (CW)") {
            Picker("IF input", selection: $model.params.syncOnRight) {
                Text("Right (as MIT's recordings)").tag(false)
                Text("Left").tag(true)
            }
            Text("Run the radar unmodulated: hold the VCO's Vtune at a fixed voltage instead of the ramp. Only the IF (\(p.syncOnRight ? "left" : "right") input; this is the same channel swap as Sync input under Trigger) is used, cut into dwells of Tp as in MIT's read_data_doppler.m. The IF is real, so approaching and receding targets both show as positive speed.")
                .font(.caption).foregroundStyle(.secondary)
            NumberRow(title: "Carrier fc (MHz)", value: $model.params.dtCarrierMHz)
            HStack {
                Button("+5 V: 2590 MHz") { model.params.dtCarrierMHz = 2590 }
                Button("+3.2 V (ISM): 2495 MHz") { model.params.dtCarrierMHz = 2495 }
            }
            .controlSize(.small)
            Text(vco + String(format: "λ = %.2f cm.", lam * 100)).font(.caption).foregroundStyle(.secondary)
            NumberRow(title: "Dwell Tp (ms)", value: $model.params.dtDwellMs)
            NumberRow(title: "Max velocity shown (m/s)", value: $model.params.dtMaxVelocity)
            Picker("Spectrum", selection: $model.params.dtMethod) {
                ForEach(DTMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            if p.dtMethod == .matrixPencil {
                Picker("Model order", selection: $model.params.dtOrderRule) {
                    ForEach(PencilOrderRule.allCases) { Text($0.rawValue).tag($0) }
                }
                IntRow(title: "Max targets (cap)", value: $model.params.dtMaxTargets)
                Picker("Display", selection: $model.params.dtPencilDisplay) {
                    ForEach(PencilDisplay.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Each dwell's analytic IF is band-limited to 0 … max velocity and decimated (in the frequency domain) to a few hundred samples, then fitted as a sum of complex exponentials (TLS matrix pencil, one pole per mover). ▼ marks the poles on the spectrum. ESTER threshold, forward–backward averaging, the singular-value threshold and the peak half-width come from Range estimator. Window and SVA don't apply.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("SVA (spatially variant apodization)", isOn: $model.params.dtSVA)
                Picker("Window", selection: $model.params.dtWindow) {
                    ForEach(WindowType.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(p.dtSVA)
                if p.dtSVA {
                    Text("SVA picks a weighting per velocity bin between rectangular and Hann: rectangular-window resolution with Hann-level sidelobes, so a loud car doesn't hide a quieter one beside it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Zero-pad (× N)", selection: $model.params.dtZeroPad) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("PGA on the strongest mover", isOn: $model.params.dtPGA)
            if p.dtPGA {
                NumberRow(title: "Ignore slower than (m/s)", value: $model.params.dtPGAMinVelocity)
                Text("Prominent-point phase gradient autofocus in each dwell: the strongest line above this speed (if it stands 20 dB above the median) is shifted to zero Doppler, windowed and its phase wander (acceleration, oscillator drift, vibration) estimated and removed, keeping its mean velocity. Iterations come from Range autofocus. A dwell's correction is kept only if its spectrum gets sharper. It focuses that mover; others in the same dwell get the same correction.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Subtract mean (DC)", isOn: $model.params.dtSubtractMean)
            Picker("Live history kept", selection: $model.params.dtHistorySeconds) {
                ForEach([30.0, 60, 120, 300], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            Text(String(format: "Doppler resolution 1/Tp = %.1f Hz = %.3f m/s (%.2f mph). %.0f m/s is a %.0f Hz Doppler. The colour scale is relative to the strongest cell shown, as in MIT's plot (−35…0 dB).",
                        1 / tp, lam / (2 * tp), lam / (2 * tp) * mphPerMps, p.dtMaxVelocity, 2 * p.dtMaxVelocity / lam))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
