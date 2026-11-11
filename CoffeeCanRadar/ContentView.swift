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
                PlotCard(title: "Range profile: FFT of IF channel (dBFS vs. range)\(model.params.pgaEnabled ? " · PGA on" : "")",
                         detail: "N=\(model.derived.n), FFT \(model.derived.nfft), \(String(format: "%.3f", model.derived.metersPerBin * model.params.rangeUnit.perMeter)) \(model.params.rangeUnit.abbreviation)/bin") {
                    FFTPlot()
                }
                .frame(minHeight: 220)
                PlotCard(title: "Range vs. time intensity (newest at top)",
                         detail: "\(model.pulseCount) pulses · colour \(Int(model.params.dbTop - model.params.dbRange))…\(Int(model.params.dbTop)) dB") {
                    RTIPlot()
                }
                .frame(minHeight: 200)
                HStack(spacing: 10) {
                    PlotCard(title: "Last triggered pulse: sync (blue) / IF (orange)") { ScopePlot() }
                    if model.params.pgaEnabled {
                        PlotCard(title: "PGA phase error estimate",
                                 detail: model.pgaAgreement.map { String(format: "accepted %d of %d · halves agree %.2f", model.pgaAccepted, model.pgaUpdates, $0) } ?? "") {
                            PGAPlot()
                        }
                        .frame(width: 340)
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
            Section("Display") {
                Picker("Range units", selection: $model.params.rangeUnit) {
                    ForEach(RangeUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                NumberRow(title: "Max range shown (\(model.params.rangeUnit.abbreviation), 0 = all)", value: model.inDisplayUnits(\.maxRangeShown))
                NumberRow(title: "Top (dB)", value: $model.params.dbTop)
                NumberRow(title: "Dynamic range (dB)", value: $model.params.dbRange)
                Picker("RTI history", selection: $model.params.rtiSeconds) {
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
