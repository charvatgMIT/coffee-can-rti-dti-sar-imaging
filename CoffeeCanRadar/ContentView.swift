import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 310)
            Divider()
            VStack(spacing: 10) {
                StatsBar()
                RangeSlider()
                PlotCard(title: model.params.rangeMethod == .matrixPencil
                            ? "Range profile: matrix pencil \(model.params.pencilDisplay.rawValue.lowercased()) (dB vs. range)\(model.params.pgaEnabled ? " · PGA on" : "") · ▼ = estimated targets"
                            : "Range profile: FFT of IF channel (dBFS vs. range)\(model.params.pgaEnabled ? " · PGA on" : "")",
                         detail: model.params.rangeMethod == .matrixPencil
                            ? "N=\(model.derived.n), model order \(model.pencilOrder.map(String.init) ?? "–"), \(model.pencilTargets.count) targets, \(String(format: "%.1f", model.pencilMs ?? 0)) ms/pulse"
                            : "N=\(model.derived.n), FFT \(model.derived.nfft), \(String(format: "%.3f", model.derived.metersPerBin * model.params.rangeUnit.perMeter)) \(model.params.rangeUnit.abbreviation)/bin") {
                    FFTPlot()
                }
                .frame(minHeight: 220)
                HStack(spacing: 10) {
                PlotCard(title: "Range vs. time intensity (newest at top)",
                         detail: "\(model.pulseCount) pulses · colour \(Int(model.params.dbTop - model.params.rtiDbRange))…\(Int(model.params.dbTop)) dB") {
                    VStack(spacing: 4) {
                        RTIPlot()
                        HStack {
                            Text("Dynamic range")
                            Slider(value: Binding(get: { model.params.rtiDbRange }, set: { model.params.rtiDbRange = $0.rounded() }), in: 10...100)
                                .frame(maxWidth: 320)
                            Text("\(Int(model.params.rtiDbRange)) dB").monospacedDigit().frame(width: 48, alignment: .trailing)
                            Spacer(minLength: 24)
                            Text("Time span")
                            // logarithmic: fine control over short spans
                            Slider(value: Binding(get: { log10(model.rtiViewSecondsShown) },
                                                  set: { v in
                                                      let s = pow(10, v)
                                                      let r = s < 10 ? (s * 10).rounded() / 10 : s.rounded()
                                                      model.params.rtiViewSeconds = r >= model.params.rtiSeconds ? 0 : r
                                                  }),
                                   in: log10(0.5)...log10(model.params.rtiSeconds))
                                .frame(maxWidth: 320)
                            Text(model.rtiViewSecondsShown < 10 ? String(format: "%.1f s", model.rtiViewSecondsShown)
                                                                : String(format: "%.0f s", model.rtiViewSecondsShown))
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                            Spacer()
                        }
                        .font(.caption)
                        .controlSize(.small)
                    }
                }
                    if model.params.rdEnabled { RangeDopplerCard() }
                }
                .frame(minHeight: 200)
                HStack(spacing: 10) {
                    PlotCard(title: "Last triggered pulse: sync (blue) / IF (orange)") { ScopePlot() }
                    if model.params.pgaEnabled || (model.params.rdEnabled && (model.params.rdRangePGA || model.params.rdDopplerPGA)) {
                        PGACard().frame(width: 340)
                    }
                    PlotCard(title: "Rising-edge zoom: samples ● and interpolation",
                             detail: model.edge.map { "\($0.upsample)× · edge at \(String(format: "%+.3f", $0.edgeOffset)) samples" } ?? "") {
                        EdgePlot()
                    }
                    .frame(width: 380)
                }
                .frame(height: 200)
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Input", selection: $model.selectedDeviceID) {
                    if model.devices.isEmpty { Text("No audio inputs").tag(AudioDeviceID(0)) }
                    ForEach(model.devices) { d in
                        Text("\(d.name) (\(d.inputChannels) ch, \(Int(d.sampleRate / 1000)) kHz)").tag(d.id)
                    }
                }
                .frame(minWidth: 260)
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the list of audio inputs")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.source == .none {
                    Button { model.startLive() } label: { Label("Start", systemImage: "play.fill") }
                        .keyboardShortcut("r", modifiers: .command)
                    Button { model.startSimulation() } label: { Label("Simulate", systemImage: "waveform") }
                } else {
                    Button { model.paused.toggle() } label: {
                        Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play" : "pause")
                    }
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: .command)
                }
            }
        }
        .navigationTitle("Coffee Can Radar RTI")
    }
}

/// Range PGA (fast time) or range-Doppler slow-time PGA phase estimate.
struct PGACard: View {
    @EnvironmentObject var model: RadarModel
    @State private var showDoppler = false

    var body: some View {
        let p = model.params
        let rangeOn = p.pgaEnabled || (p.rdEnabled && p.rdRangePGA), dopplerOn = p.rdEnabled && p.rdDopplerPGA
        let doppler = dopplerOn && (showDoppler || !rangeOn)
        let slow = model.rangeDoppler?.slowPhase
        PlotCard(title: doppler ? "Doppler PGA phase error" : "Range PGA phase error",
                 detail: doppler ? (slow.map { String(format: "%.2f rad rms", rms($0.map(Double.init))) } ?? "")
                                 : (model.pgaAgreement.map { String(format: "accepted %d of %d · halves agree %.2f", model.pgaAccepted, model.pgaUpdates, $0) } ?? "")) {
            VStack(spacing: 2) {
                if rangeOn && dopplerOn {
                    Picker("", selection: $showDoppler) {
                        Text("Range (fast time)").tag(false)
                        Text("Doppler (slow time)").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini)
                }
                if doppler { SlowPGAPlot() } else { PGAPlot() }
            }
        }
    }
}

struct RangeDopplerCard: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let unit = model.params.rangeUnit, p = model.rangeDoppler?.peak
        let pgaTag = [model.params.rdRangePGA ? "range" : nil, model.params.rdDopplerPGA ? "Doppler" : nil].compactMap { $0 }.joined(separator: " + ")
        let sr = model.params.rdSuperRes
        let srTag = sr == .off ? "" : " · " + sr.rawValue.lowercased()
        let ms = model.rangeDoppler.map { String(format: " · %.0f ms", $0.ms) } ?? ""
        PlotCard(title: "Range-Doppler (\(model.params.rdPulses) pulses, \(String(format: "%.2f", Double(model.params.rdPulses) * 2 * model.params.tpMs / 1000)) s)\(srTag)\(pgaTag.isEmpty ? "" : " · PGA: " + pgaTag)",
                 detail: (p.map { String(format: "○ %.1f %@, %+.2f %@/s @ %.0f dB", $0.range * unit.perMeter, unit.abbreviation,
                                        $0.velocity * unit.perMeter, unit.abbreviation, $0.db) } ?? "") + ms) {
            VStack(spacing: 4) {
                RangeDopplerPlot()
                HStack {
                    Text("Dynamic range")
                    Slider(value: Binding(get: { model.params.rdDbRange }, set: { model.params.rdDbRange = $0.rounded() }), in: 10...100)
                        .frame(maxWidth: 240)
                    Text("\(Int(model.params.rdDbRange)) dB").monospacedDigit().frame(width: 48, alignment: .trailing)
                    Spacer()
                }
                .font(.caption)
                .controlSize(.small)
            }
        }
    }
}

struct PlotCard<Content: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder let content: Content

    init(title: String, detail: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

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

struct StatsBar: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let d = model.derived, s = model.stats, unit = model.params.rangeUnit
        let clip = s.levelL > 0.99 || s.levelR > 0.99
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatTile(title: "Sample rate / N", value: "\(String(format: "%.1f", d.fs / 1000)) kHz / \(d.n)")
                StatTile(title: "Range res. / max range",
                         value: "\(String(format: "%.1f", d.rangeRes * unit.fine.perMeter)) \(unit.fine.abbreviation) / \(String(format: "%.1f", d.maxRange * unit.perMeter)) \(unit.abbreviation)")
                StatTile(title: "Pulse rate",
                         value: s.pulseRateHz.map { String(format: "%.2f Hz (%.3f ms)", $0, s.periodMs ?? 0) } ?? "–")
                StatTile(title: "Period jitter σ: integer → interp.",
                         value: s.jitterIntegerUs.map { String(format: "%.2f → %.2f µs", $0, s.jitterInterpUs ?? 0) } ?? "–")
                StatTile(title: "Peak level L / R",
                         value: "\(dbfs(s.levelL)) / \(dbfs(s.levelR)) dBFS" + (clip ? "  CLIP" : ""),
                         warning: clip)
                StatTile(title: "Strongest return",
                         value: s.peakRange.map { String(format: "%.2f %@ @ %.1f dB", $0 * unit.perMeter, unit.abbreviation, s.peakDB ?? 0) } ?? "–")
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                .lineLimit(2)
            if let sug = model.suggestion {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(sug.message).font(.callout)
                    Button(sug.action) { model.applySuggestion() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
        }
    }

    private func dbfs(_ v: Float) -> String { v > 0 ? String(format: "%.1f", 20 * log10(v)) : "−∞" }
}

struct StatTile: View {
    let title: String
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 14).monospacedDigit())
                .foregroundStyle(warning ? Color.red : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}

struct SettingsSidebar: View {
    @EnvironmentObject var model: RadarModel

    /// Tuning voltages for f start / f stop on the VCO's typical +25 °C curve.
    private var vcoSummary: String {
        let p = model.params
        let bw = String(format: "BW %.1f MHz", p.fStopMHz - p.fStartMHz)
        guard let v0 = VCO.volts(atMHz: p.fStartMHz), let v1 = VCO.volts(atMHz: p.fStopMHz) else {
            return String(format: "%@. Outside the %@ range (%.1f–%.1f MHz for 0–5 V).",
                          bw, VCO.name, VCO.minMHz, VCO.maxMHz)
        }
        return String(format: "%@. %@ tuning ≈ %.2f–%.2f V (typ. +25 °C curve).", bw, VCO.name, v0, v1)
    }

    /// Doppler resolution and unambiguous velocity for the current settings.
    private var rdSummary: String {
        let p = model.params, u = p.rangeUnit
        let pri = 2 * p.tpMs / 1000, lam = wavelength(p)
        let vMax = lam / (4 * pri), dv = lam / 2 / (Double(p.rdPulses) * pri)
        return String(format: "One pulse every %.0f ms (%.0f Hz), λ = %.1f cm: velocities up to ±%.2f %@/s are unambiguous, resolution %.3f %@/s. ",
                      pri * 1000, 1 / pri, lam * 100, vMax * u.perMeter, u.abbreviation, dv * u.perMeter, u.abbreviation)
            + "Each range bin of the newest pulses gets a slow-time FFT; + is approaching. The background setting in Processing applies first: \"Subtract mean pulse\" or the 2-pulse canceller remove stationary clutter (the canceller also weights the map by 2|sin(πf·T)|). With PGA on, the PGA-corrected pulses are used."
    }

    var body: some View {
        Form {
            Section("Radar") {
                NumberRow(title: "Up-ramp time Tp (ms)", value: $model.params.tpMs)
                Picker("Band", selection: $model.params.band) {
                    ForEach(Band.allCases) { Text($0.rawValue).tag($0) }
                }
                NumberRow(title: "f start (MHz)", value: $model.params.fStartMHz)
                NumberRow(title: "f stop (MHz)", value: $model.params.fStopMHz)
                Text(vcoSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Trigger (\(model.params.syncOnRight ? "right" : "left") channel)") {
                Picker("Sync input", selection: $model.params.syncOnRight) {
                    Text("Left (IF on right)").tag(false)
                    Text("Right (IF on left)").tag(true)
                }
                Toggle("Invert inputs (trig = −sync, s = −IF)", isOn: $model.params.invert)
                NumberRow(title: "Threshold", value: $model.params.threshold)
                IntRow(title: "Samples low before edge", value: $model.params.holdoff)
                Picker("Edge interpolation", selection: $model.params.interpolation) {
                    ForEach([10, 16, 32, 64, 128], id: \.self) { Text("\($0)×").tag($0) }
                }
                Toggle("Align IF to the sub-sample edge", isOn: $model.params.align)
                Text("The rising edge is upsampled with a windowed-sinc interpolator, then refined linearly between the upsampled points. With alignment on, each IF pulse is resampled to start exactly at the interpolated edge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Range estimator") {
                Picker("Method", selection: $model.params.rangeMethod) {
                    ForEach(RangeMethod.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.params.rangeMethod == .matrixPencil {
                    Picker("Display", selection: $model.params.pencilDisplay) {
                        ForEach(PencilDisplay.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Model order", selection: $model.params.pencilOrderRule) {
                        ForEach(PencilOrderRule.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Forward–backward averaging", isOn: $model.params.pencilForwardBackward)
                    IntRow(title: model.params.pencilOrderRule == .threshold ? "Max targets" : "Max targets (cap)", value: $model.params.pencilMaxTargets)
                    switch model.params.pencilOrderRule {
                    case .ester:
                        NumberRow(title: "ESTER threshold (0–1, higher = fewer)", value: $model.params.esterThreshold)
                    case .threshold:
                        NumberRow(title: "Signal threshold (dB below largest σ)", value: $model.params.pencilThresholdDB)
                    case .gap:
                        EmptyView()
                    }
                    IntRow(title: "Pencil parameter L (0 = N/3)", value: $model.params.pencilL)
                    NumberRow(title: "Peak half-width (FFT bins)", value: $model.params.pencilPeakWidth)
                    Text("Fits each pulse as a sum of complex exponentials (Hua & Sarkar TLS matrix pencil), two per target for the real IF (one with PGA on). The model order is chosen every pulse: ESTER keeps the largest order whose signal subspace is still shift-invariant (robust to coloured noise and clutter); the gap rule cuts at the biggest drop in singular values; the threshold rule counts singular values within a fixed dB of the largest. Forward–backward averaging adds the time-reversed, conjugated pulse to the data matrix, which decorrelates coherent returns such as multipath and reduces noise. The pseudospectrum is 1/σmin(E − zI) around the unit circle, scaled so its peaks sit at the strongest target's power; amplitude-weighted lines put a peak of each target's fitted power at its range. ▼ marks each estimated target. The window and SVA settings don't apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Processing") {
                Picker("Background", selection: $model.params.background) {
                    ForEach(Background.allCases) { Text($0.rawValue).tag($0) }
                }
                IntRow(title: "Mean length (pulses)", value: $model.params.meanLength)
                Toggle("SVA (spatially variant apodization)", isOn: $model.params.svaEnabled)
                    .help("Chooses the weighting per range bin: rectangular-window resolution with Hann-level sidelobes.")
                Picker("Window", selection: $model.params.window) {
                    ForEach(WindowType.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.params.svaEnabled)
                if model.params.svaEnabled {
                    Text("SVA replaces the window: each range bin gets its own weighting between rectangular and Hann.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.params.window == .taylor {
                    IntRow(title: "Taylor n̄", value: $model.params.taylorNbar)
                    NumberRow(title: "Taylor sidelobes (dB below peak)", value: $model.params.taylorSidelobeDB)
                }
                Picker("Zero-pad (× N)", selection: $model.params.zeroPad) {
                    ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) }
                }
                IntRow(title: "Trace averaging (pulses)", value: $model.params.traceAveraging)
                Toggle("Peak hold", isOn: $model.params.peakHold)
            }
            Section("Range autofocus (PGA)") {
                Toggle("Phase gradient autofocus", isOn: $model.params.pgaEnabled)
                if model.params.pgaEnabled {
                    Picker("Pulses per estimate", selection: $model.params.pgaPulses) {
                        ForEach([16, 32, 64, 128, 256], id: \.self) { Text("\($0)").tag($0) }
                    }
                    IntRow(title: "Iterations", value: $model.params.pgaIterations)
                    NumberRow(title: "Ignore returns closer than (\(model.params.rangeUnit.abbreviation))", value: model.inDisplayUnits(\.pgaMinRange))
                    NumberRow(title: "Min. half-block agreement", value: $model.params.pgaMinAgreement)
                    Button("Reset PGA estimate") { model.resetPGA() }
                        .controlSize(.small)
                }
                Text("Estimates the phase error every sweep shares (mostly VCO tuning nonlinearity) from the strongest return in each pulse, and removes it before the FFT. An estimate is kept only if both halves of the block agree and the profiles get sharper. The error grows with range, so the correction is exact near the dominant target and approximate elsewhere. Works best with one strong target (e.g. a corner reflector) in view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Range-Doppler") {
                Toggle("Show range-Doppler map", isOn: $model.params.rdEnabled)
                if model.params.rdEnabled {
                    Picker("Pulses per Doppler FFT", selection: $model.params.rdPulses) {
                        ForEach([16, 32, 64, 128, 256], id: \.self) {
                            Text("\($0) (\(String(format: "%.2f", Double($0) * 2 * model.params.tpMs / 1000)) s)").tag($0)
                        }
                    }
                    Picker("Doppler window", selection: $model.params.rdWindow) {
                        ForEach(WindowType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Super-resolution", selection: $model.params.rdSuperRes) {
                        ForEach(RDSuperRes.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Matrix pencil uses the settings under Range estimator (model order rule, max targets, forward–backward, peak half-width). In Doppler it fits each range bin's pulses and draws the pseudospectrum 4× finer than the FFT cells; in range it fits the Doppler-filtered samples of each pulse; with both, a cell is bright only where the two agree. Cells more than 10 dB below the colour scale are skipped, and the map's build time is shown in its header.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Range PGA (fast time)", isOn: $model.params.rdRangePGA)
                        .help("Removes the sweep-shared phase error (VCO nonlinearity) before the range FFT, for this map only.")
                    Toggle("Doppler PGA (slow time)", isOn: $model.params.rdDopplerPGA)
                        .help("Removes the pulse-to-pulse phase error shared by every range bin before the Doppler FFT.")
                    Text("PGA on the map is separate from the range-profile PGA switch below, and uses its settings (pulses per estimate, iterations, minimum range). Range PGA: the fast-time phase error every sweep shares, estimated over many pulses from the strongest return. Doppler PGA: each map's pulses are re-estimated: each range bin's strongest Doppler cell is moved to zero Doppler (so true velocities are kept), and the pulse-to-pulse phase changes common to all range bins (oscillator phase noise, radar vibration) are removed, keeping no linear trend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(rdSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display") {
                Picker("Range units", selection: $model.params.rangeUnit) {
                    ForEach(RangeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                NumberRow(title: "Max range shown (\(model.params.rangeUnit.abbreviation), 0 = all)", value: model.inDisplayUnits(\.maxRangeShown))
                NumberRow(title: "Top (dB)", value: $model.params.dbTop)
                Toggle("Track top automatically", isOn: $model.params.autoTop)
                NumberRow(title: "Range-profile dynamic range (dB)", value: $model.params.dbRange)
                NumberRow(title: "Waterfall dynamic range (dB)", value: $model.params.rtiDbRange)
                Picker("RTI history kept", selection: $model.params.rtiSeconds) {
                    ForEach([10.0, 30, 60, 120, 300], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                HStack {
                    Button("Auto scale") { model.autoScale() }
                    Button("Clear RTI / hold") { model.clearHold() }
                }
                .controlSize(.small)
            }
            Section {
                Button("Restore default settings") { model.resetSettings() }
                    .controlSize(.small)
            } footer: {
                Text("Settings are remembered between launches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct NumberRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}

struct IntRow: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
    }
}

/// Max range shown on both range plots. Display only: the full spectrum is kept.
struct RangeSlider: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let d = model.derived
        let lower = min(d.maxRange, max(1, 8 * d.metersPerBin))
        let value = Binding<Double>(
            get: { model.params.maxRangeShown > 0 ? min(model.params.maxRangeShown, d.maxRange) : d.maxRange },
            set: { model.params.maxRangeShown = $0 >= d.maxRange * 0.999 ? 0 : ($0 * 10).rounded() / 10 })
        HStack(spacing: 8) {
            Text("Max range").font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: lower...max(lower + 1, d.maxRange))
            Text(String(format: "%.1f %@", value.wrappedValue * model.params.rangeUnit.perMeter, model.params.rangeUnit.abbreviation))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Button("Full") { model.params.maxRangeShown = 0 }
                .controlSize(.small)
                .disabled(model.params.maxRangeShown == 0)
        }
    }
}
