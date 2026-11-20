import SwiftUI

/// The SAR imaging tab (right of the SAR sidebar), formerly the Coffee Can SAR window.
struct SARPane: View {
    @EnvironmentObject var model: SARModel
    @AppStorage("sarTab") private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $tab) {
                    Text("SAR image").tag(0)
                    Text("Range profiles").tag(1)
                    Text("K-space").tag(2)
                    Text("Autofocus").tag(3)
                    Text("How it works").tag(4)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 600)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.fileURL?.lastPathComponent ?? "no recording").font(.callout).foregroundStyle(.secondary)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                .lineLimit(2)
            Card(title: title, detail: detail) {
                switch tab {
                case 1: ProfilePlot()
                case 2: KSpacePlot()
                case 3: AutofocusPlots()
                case 4: HowItWorksSAR()
                default: SARPlot()
                }
            }
        }
    }

    private var title: String {
        switch tab {
        case 1: return "Range profile at each aperture position (after mean subtraction and Hann window)"
        case 2: return "Wavenumber domain after Stolt interpolation, |S(Kx, Ky)| (range migration only)"
        case 3: return "Autofocus: estimated phase errors (removed before image formation)"
        case 4: return "Processing chain"
        default:
            return (model.result?.algorithm ?? model.params.algorithm) == .rma
                ? "SAR image: range migration algorithm (MIT SBAND_RMA_IFP.m)"
                : "SAR image: backprojection (AFRL bpBasic.m, Gorham & Moore 2010)"
        }
    }

    private var detail: String {
        guard let r = model.result else { return "" }
        let top: Double
        switch tab {
        case 1: top = r.rangeProfiles.maxDB
        case 2: guard let k = r.kSpace else { return "" }; top = k.maxDB
        case 3, 4: return ""
        default: top = r.image.maxDB
        }
        return String(format: "colour %.0f…%.0f dB", top - model.params.dbRange, top)
    }
}

struct Card<Content: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            content
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}

// MARK: - Plots

/// Crossrange (x) vs downrange (y, far at the top), equal feet per pixel in both directions.
struct SARPlot: View {
    @EnvironmentObject var model: SARModel

    var body: some View {
        let img = model.sarImage, r = model.result, p = model.params
        Canvas { ctx, size in
            let cr = r?.image.crossRange ?? (-p.crossRangeFt, p.crossRangeFt)
            let dr = r?.image.downRange ?? (p.downStartFt, p.downStopFt)
            // keep 1 ft = 1 ft: shrink the plot box to the scene's aspect ratio
            let marginW: CGFloat = 62 + 70, marginH: CGFloat = 40
            let sx = (size.width - marginW) / CGFloat(cr.1 - cr.0), sy = (size.height - marginH) / CGFloat(dr.1 - dr.0)
            let k = max(0.01, min(sx, sy))
            let w = CGFloat(cr.1 - cr.0) * k + 62, h = CGFloat(dr.1 - dr.0) * k + marginH
            var c = ctx
            c.translateBy(x: max(0, (size.width - w - 70) / 2), y: 0)
            let ax = drawAxes(c, size: CGSize(width: w, height: h), x: cr, y: dr, xLabel: "crossrange (ft)", yLabel: "downrange (ft)")
            if let img {
                c.draw(Image(decorative: img, scale: 1).interpolation(.medium), in: ax.rect)
            } else {
                c.draw(Text(model.fileURL == nil ? "Open a recording to form an image" : "Processing…").font(.caption).foregroundStyle(.secondary),
                       at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
            }
            strokeBorder(c, ax)
            if let r {
                drawColorBar(c, rect: CGRect(x: ax.rect.maxX + 14, y: ax.rect.minY, width: 12, height: ax.rect.height),
                             top: r.image.maxDB, range: p.dbRange)
            }
        }
    }
}

struct ProfilePlot: View {
    @EnvironmentObject var model: SARModel

    var body: some View {
        let img = model.profileImage, r = model.result, p = model.params
        Canvas { ctx, size in
            let ax = drawAxes(ctx, size: CGSize(width: max(80, size.width - 70), height: size.height),
                              x: (0, r?.rangeProfileMaxFt ?? p.downStopFt), y: (0, Double(r?.parsed.positions ?? 1)),
                              xLabel: "range (ft)", yLabel: "aperture position", yDown: true)
            if let img { ctx.draw(Image(decorative: img, scale: 1).interpolation(.low), in: ax.rect) }
            strokeBorder(ctx, ax)
            if let r {
                drawColorBar(ctx, rect: CGRect(x: ax.rect.maxX + 14, y: ax.rect.minY, width: 12, height: ax.rect.height),
                             top: r.rangeProfiles.maxDB, range: p.dbRange)
            }
        }
    }
}

struct KSpacePlot: View {
    @EnvironmentObject var model: SARModel

    var body: some View {
        let img = model.kImage, r = model.result, p = model.params
        let kxMax = Double.pi / p.deltaX
        Canvas { ctx, size in
            let ax = drawAxes(ctx, size: CGSize(width: max(80, size.width - 70), height: size.height),
                              x: (p.kStart, p.kStop), y: (-kxMax, kxMax), xLabel: "Ky (rad/m)", yLabel: "Kx (rad/m)", yDown: true)
            if let img { ctx.draw(Image(decorative: img, scale: 1).interpolation(.low), in: ax.rect) }
            else if model.result != nil {
                ctx.draw(Text("Backprojection doesn't use the wavenumber domain. Choose Range migration to see it.").font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
            }
            strokeBorder(ctx, ax)
            if let k = r?.kSpace {
                drawColorBar(ctx, rect: CGRect(x: ax.rect.maxX + 14, y: ax.rect.minY, width: 12, height: ax.rect.height),
                             top: k.maxDB, range: p.dbRange)
            }
        }
    }
}

struct AutofocusPlots: View {
    @EnvironmentObject var model: SARModel

    var body: some View {
        let d = model.result?.parsed, p = model.params
        VStack(spacing: 8) {
            PhasePlot(values: d?.rangePhase, x0: p.fStartMHz, x1: p.fStopMHz, xLabel: "transmit frequency (MHz)",
                      title: "Range PGA: phase error shared by every sweep (VCO nonlinearity)",
                      empty: p.rangePGA ? "Process to estimate" : "Range PGA is off", color: .purple)
            PhasePlot(values: d?.crossPhase, x0: 1, x1: Double(max(2, d?.positions ?? 2)), xLabel: "aperture position",
                      title: "Crossrange autofocus: phase error of each aperture position",
                      empty: p.crossPGA ? "Process to estimate" : "Crossrange autofocus is off", color: .teal)
        }
    }
}

struct PhasePlot: View {
    let values: [Double]?
    let x0: Double, x1: Double
    let xLabel: String, title: String, empty: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title + (values.map { String(format: " · %.2f rad rms", rms($0)) } ?? "")).font(.caption).foregroundStyle(.secondary)
            Canvas { ctx, size in
                guard let v = values, v.count > 1 else {
                    let ax = drawAxes(ctx, size: size, x: (x0, x1), y: (-1, 1), xLabel: xLabel, yLabel: "rad")
                    ctx.draw(Text(empty).font(.caption).foregroundStyle(.secondary), at: CGPoint(x: ax.rect.midX, y: ax.rect.midY))
                    strokeBorder(ctx, ax); return
                }
                let mx = max(0.2, (v.map { abs($0) }.max() ?? 1) * 1.1)
                let ax = drawAxes(ctx, size: size, x: (x0, x1), y: (-mx, mx), xLabel: xLabel, yLabel: "rad")
                var c = ctx
                c.clip(to: Path(ax.rect))
                var path = Path()
                for (i, y) in v.enumerated() {
                    let pt = CGPoint(x: ax.px(x0 + (x1 - x0) * Double(i) / Double(v.count - 1)), y: ax.py(y))
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                    if v.count < 200 { c.fill(Path(ellipseIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)), with: .color(color)) }
                }
                c.stroke(path, with: .color(color), lineWidth: 1.4)
                strokeBorder(ctx, ax)
            }
        }
    }
}

// MARK: - Settings

struct SARSidebar: View {
    @EnvironmentObject var model: SARModel

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("File", value: model.fileURL?.lastPathComponent ?? "none")
                if let info = model.recordingInfo { LabeledContent("Length", value: info) }
                Button("Open…") { model.chooseFile() }.controlSize(.small)
            }
            Section("Parsing (SBAND_RMA_opendata.m)") {
                Picker("Sync input", selection: $model.params.syncOnRight) {
                    Text("Left (IF on right)").tag(false)
                    Text("Right (IF on left)").tag(true)
                }
                Toggle("Invert inputs", isOn: $model.params.invert)
                Num(title: "Up-chirp time Tp (ms)", value: $model.params.tpMs)
                Num(title: "Min. time per position Trp (s)", value: $model.params.trpSeconds)
                Num(title: "Sync threshold", value: $model.params.syncThreshold)
                IntNum(title: "Up-chirps per position (0 = MIT)", value: $model.params.chirpsPerPosition)
                Picker("Pulse alignment", selection: $model.params.alignment) {
                    ForEach(PulseAlignment.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.params.alignment == .interpolated {
                    Picker("Edge interpolation", selection: $model.params.interpolation) {
                        ForEach([10, 16, 32, 64, 128], id: \.self) { Text("\($0)×").tag($0) }
                    }
                    IntNum(title: "Samples low before edge", value: $model.params.holdoff)
                }
                Text("Every position averages exactly this many up-chirps (the first complete ones), so all positions have the same integration and noise level; uneven averaging across the aperture shows up as azimuth clutter. If a position has fewer, every position uses that smaller number. 0 reproduces MIT's script: all chirps in the first Trp, which varies by position.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.params.alignment == .interpolated
                     ? "A new aperture position starts where the sync channel comes back after at least Trp of silence. In each position, every rising sync edge is found as in the RTI app: upsampled with a windowed-sinc interpolator, refined linearly to the threshold crossing, and each up-chirp is resampled to start exactly at that sub-sample time. The chirps are averaged, then Hilbert-transformed to N/2 complex samples."
                     : "A new aperture position starts where the sync channel comes back after at least Trp of silence. In each position, every up-chirp is cut at the integer sample where the sync peaks after a rising edge (as SBAND_RMA_opendata.m does), averaged, then Hilbert-transformed to N/2 complex samples.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Radar") {
                Num(title: "f start (MHz)", value: $model.params.fStartMHz)
                Num(title: "f stop (MHz)", value: $model.params.fStopMHz)
                Toggle("1-inch spacing: full ±90° field of view", isOn: Binding(
                    get: { model.params.fullFOV },
                    set: { on in
                        model.params.fullFOV = on
                        // 1 inch is below lambda/4 at 2.59 GHz (1.14 in), so there are no grating lobes and the
                        // image can cover the whole half-plane: crossrange out to the farthest downrange
                        model.params.spacingInches = on ? 1 : 2
                        model.params.crossRangeFt = on ? model.params.downStopFt : 200
                    }))
                Num(title: "Antenna spacing (in)", value: $model.params.spacingInches)
                if model.params.fullFOV {
                    Label("Only for recordings made with 1-inch steps along the rail. MIT's example (towardswarehouse.wav) used 2-inch steps, so this setting puts its positions in the wrong places.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                    if model.params.algorithm == .rma {
                        Text(String(format: "Range migration can only show ±%.0f ft with this zero pad; backprojection shows the full field.", Double(model.params.zpad) * model.params.deltaX * feetPerMeter / 2))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.params.spacingInches > speedOfLight / (model.params.fStopMHz * 1e6) / 4 * feetPerMeter * 12 {
                    Label(String(format: "Suggestion: move the radar 1 inch between positions when recording. %.2g-inch steps are wider than λ/4 (%.2f in at %.0f MHz), so the aperture aliases beyond ±%.0f° and the image is blanked there. With 1-inch steps there are no grating lobes and the image covers the full ±90°; turn on \"1-inch spacing\" above for those recordings.",
                               model.params.spacingInches, speedOfLight / (model.params.fStopMHz * 1e6) / 4 * feetPerMeter * 12, model.params.fStopMHz,
                               gratingLobeFreeAngle(model.params) * 180 / .pi), systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Image formation") {
                Picker("Algorithm", selection: $model.params.algorithm) {
                    ForEach(SARAlgorithm.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Subtract mean over the aperture", isOn: $model.params.subtractMean)
                if model.params.subtractMean {
                    Toggle("Use MIT's running mean", isOn: $model.params.mitMean)
                        .help("SBAND_RMA_IFP.m recomputes the mean after each row it changes, which leaves about 37% of the common component (antenna leakage). Off: the exact mean is removed.")
                }
                Toggle("Range PGA (fast time)", isOn: $model.params.rangePGA)
                    .help("Removes the phase error every sweep shares (mostly VCO nonlinearity), one value per frequency sample.")
                Toggle("Crossrange autofocus (per position)", isOn: $model.params.crossPGA)
                    .help("Removes a phase error per aperture position (rail position errors, drift between positions).")
                if model.params.rangePGA || model.params.crossPGA {
                    IntNum(title: "Autofocus iterations", value: $model.params.pgaIterations)
                    Text("Both run before image formation, so they apply to either algorithm, and before SVA. Range PGA (as in the RTI app): each position's strongest return is centred and windowed, and the phase gradient over frequency is summed over positions. Crossrange: the strongest scatterers in a quick image are picked, and each position's phase is set to add coherently to them with the others (PGA's estimator on the backprojected phase histories). Linear trends are removed, so the image doesn't shift. The estimates are plotted under Autofocus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("SVA (spatially variant apodization)", isOn: $model.params.sva)
                    .help("Unweighted-data resolution with Hann-level sidelobes, in range and crossrange.")
                if model.params.sva {
                    Picker("SVA type", selection: $model.params.svaMode) {
                        ForEach(SVAMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.params.svaMode != .dual {
                        Toggle("Limit by the Hann image", isOn: $model.params.svaHannCap)
                            .help("Keeps each pixel no brighter than the gain-matched Hann image. Removes the slowly decaying unweighted range sidelobes that show as radial streaks at far range.")
                    }
                    Text("Joint I/Q picks one weight per complex pixel; separate I/Q (the original SVA) picks one each for I and Q, which is more aggressive but streakier on clutter. Dual apodization keeps the smaller of the unweighted and Hann images (robust, less sidelobe suppression). Limiting by the Hann image stops the slowly decaying unweighted range sidelobes of strong close-in returns from showing as radial streaks at far range, where the range^(3/2) scaling brightens them.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("SVA replaces the Hann windows (the data are processed unweighted). It runs on the complex image: for every pixel it looks one null away, c/2B along the line of sight from the aperture and λR/(2L·cos θ) across it, and picks, separately for I and Q, the raised-cosine weight between rectangular and Hann that gives the smallest output (Stankwitz, Dallaire & Fienup 1995).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.params.algorithm == .backprojection {
                    Toggle("Hann window over frequency", isOn: $model.params.bpHann)
                        .disabled(model.params.sva)
                    Picker("Range FFT size (Nfft)", selection: $model.params.bpNfft) {
                        ForEach([2048, 4096, 8192, 16384, 32768], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Num(title: "Pixel size (ft)", value: $model.params.bpPixelFt)
                    Num(title: "Reference range R0 (ft, 0 = scene middle)", value: $model.params.bpR0Ft)
                    Text("Backprojection (LeRoy Gorham, AFRL, bpBasic.m): for every aperture position, the zero-padded range profile fftshift(ifft(phase history, Nfft)) is linearly interpolated at each pixel's range from that antenna position, phase-corrected by exp(j4π·fmin·ΔR/c) and summed. Each position's averaged chirp is its phase history (sample k = frequency fstart + k·Δf), conjugated to AFRL's sign convention and referenced to R0, since the ±c/(4Δf) = ±100 m swath around R0 must cover the scene.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Num(title: "Scene centre Rs (ft, matched filter)", value: $model.params.rsFeet)
                    Picker("Cross-range zero pad", selection: $model.params.zpad) {
                        ForEach([1024, 2048, 4096], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Num(title: "Ky start (rad/m)", value: $model.params.kStart)
                    Num(title: "Ky stop (rad/m)", value: $model.params.kStop)
                    Toggle("Hann window after Stolt", isOn: $model.params.hannAfterStolt)
                    Text("Range migration algorithm (Carrara, Goodman & Majewski ch. 10): Hann window in fast time, symmetric zero pad and FFT along the aperture, matched filter exp(j·Rs·√(Kr²−Kx²)), Stolt interpolation to an even Ky grid, then a 4× zero-padded 2-D inverse FFT.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Super-resolution (matrix pencil)") {
                Picker("Matrix pencil", selection: $model.params.superRes) {
                    ForEach(SARSuperRes.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.params.superRes != .off {
                    Picker("Model order", selection: $model.params.pencilRule) {
                        ForEach(PencilOrderRule.allCases) { Text($0.rawValue).tag($0) }
                    }
                    IntNum(title: "Max scatterers per fit", value: $model.params.pencilMaxTargets)
                    Toggle("Forward–backward averaging", isOn: $model.params.pencilFB)
                    if model.params.superRes.inRange {
                        Picker("Range: extrapolate band to", selection: $model.params.bweFactor) {
                            ForEach([2, 3, 4], id: \.self) { Text("\($0)× (\(String(format: "%.0f", Double($0) * (model.params.fStopMHz - model.params.fStartMHz))) MHz)").tag($0) }
                        }
                    }
                    if model.params.superRes.inCrossrange {
                        Num(title: "Crossrange width kept (resolution cells)", value: $model.params.crossPeakWidth)
                    }
                    Text("Range: at each position the frequency samples are a sum of complex exponentials (one per scatterer). The pencil's poles and least-squares amplitudes extend the band on both sides (the measured samples stay in the middle), so image formation sees a wider band: finer range, phases intact. Crossrange (backprojection only): once focused on a pixel, the positions' contributions are close to a sum of exponentials over the aperture, the scatterer at the pixel at zero frequency and its neighbours offset; the pixel keeps only the fitted power within the kept width of zero frequency. Pixels below the colour scale are left as they are. The crossrange pencil fits every pixel, so it takes several seconds (the gap rule is about 3× faster than ESTER), and it replaces SVA. A narrower kept width separates closer scatterers but needs smaller pixels.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Display") {
                Num(title: "Crossrange ± (ft)", value: $model.params.crossRangeFt)
                Num(title: "Downrange from (ft)", value: $model.params.downStartFt)
                Num(title: "Downrange to (ft)", value: $model.params.downStopFt)
                Toggle("Blank grating-lobe angles", isOn: $model.params.blankGratingLobes)
                    .help("Greys out angles where aliases of the scene can appear because of the antenna spacing.")
                if model.params.blankGratingLobes {
                    Text(String(format: "Beyond ±%.1f° from broadside (blanked), aliases of scatterers inside can appear: with %.2g-inch spacing, a scatterer at θ also shows at sin θ ± λ/(2·dx). Inside ±θmax, with sin θmax = λ/(4·dx) at f stop, no scatterer inside aliases. 1-inch spacing would allow about ±90°.", gratingLobeFreeAngle(model.params) * 180 / .pi, model.params.spacingInches))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Scale by range^(3/2)", isOn: $model.params.rangeScaling)
                if model.params.rangeScaling {
                    Toggle("Use true range (MIT uses downrange)", isOn: $model.params.scaleBySlantRange)
                        .help("Scales each pixel by its distance from the aperture centre, √(x² + y²). MIT's script uses downrange y, which under-scales wide crossranges (5 dB at 200 ft across, 100 ft down).")
                }
                LabeledContent("Dynamic range") {
                    HStack {
                        Slider(value: Binding(get: { model.params.dbRange }, set: { model.params.dbRange = $0.rounded() }), in: 10...80)
                        Text("\(Int(model.params.dbRange)) dB").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section {
                Button("Process") { model.process() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.fileURL == nil || model.busy)
                Button("Restore default settings") { model.resetSettings() }.controlSize(.small)
            } footer: {
                Text("Settings are remembered. Changing a parsing setting re-parses the recording; others only re-form the image.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AboutSection(appName: AboutInfo.appName)
        }
        .formStyle(.grouped)
    }
}

struct IntNum: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number)
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
        }
    }
}

struct Num: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number)
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
        }
    }
}
