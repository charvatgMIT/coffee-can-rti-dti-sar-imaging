import SwiftUI

/// "How it works" tab: the RTI app's processing chain, drawn from the current settings.
struct HowItWorksRTI: View {
    var body: some View {
        ScrollView { HowItWorksRTIContent().padding(.vertical, 4) }
    }
}

struct HowItWorksRTIContent: View {
    @EnvironmentObject var model: RadarModel

    var body: some View {
        let p = model.params, d = model.derived
        let sync = p.syncOnRight ? "right" : "left", ifc = p.syncOnRight ? "left" : "right"
        let pencil = p.rangeMethod == .matrixPencil
        let window = p.svaEnabled ? "SVA (per-bin weighting, rectangular to Hann)"
            : p.window == .taylor ? "Taylor window (n̄ = \(p.taylorNbar), \(Int(p.taylorSidelobeDB)) dB)" : "\(p.window.rawValue) window"
        let main: [[DiagramBlock]] = [
            [DiagramBlock(title: "Audio input", detail: "UCA222 (USB Audio CODEC), \(Int(d.fs)) Hz stereo: sync on the \(sync) input, IF on the \(ifc)\(p.invert ? ", both inverted" : "")", active: model.source != .simulation, kind: .input),
             DiagramBlock(title: "Simulator", detail: "synthetic sync and IF: fixed targets and a walking target with Doppler", active: model.source == .simulation, kind: .input)],
            [DiagramBlock(title: "Real-time guard", detail: "at most 0.5 s of audio may wait for processing; beyond that blocks are skipped and the status line says so")],
            [DiagramBlock(title: "Sync trigger", detail: "rising edge after ≥ \(p.holdoff) samples below the threshold; the edge is upsampled \(p.interpolation)× with a windowed sinc and refined linearly to the crossing")],
            [DiagramBlock(title: "Pulse extraction", detail: p.align ? "N = Tp·fs = \(d.n) samples (Tp = \(String(format: "%g", p.tpMs)) ms up-chirp), resampled to start exactly at the sub-sample edge"
                                                              : "N = \(d.n) samples from the integer trigger sample")],
            [DiagramBlock(title: "Background removal", detail: p.background == .mean ? "subtract the running mean pulse (\(p.meanLength) pulses)" : p.background == .twoPulse ? "2-pulse canceller (this pulse minus the last)" : "none",
                          active: p.background != .none)],
            [DiagramBlock(title: "Range PGA", detail: "analytic signal; phase error every sweep shares (VCO nonlinearity) estimated from the strongest return over \(p.pgaPulses) pulses and removed", active: p.pgaEnabled)],
            [DiagramBlock(title: "FFT range profile", detail: "\(window), zero pad \(p.zeroPad)×, \(d.nfft)-point FFT", active: !pencil),
             DiagramBlock(title: "Matrix pencil range profile", detail: "TLS pencil (Hua & Sarkar), model order: \(p.pencilOrderRule.rawValue)\(p.pencilForwardBackward ? ", forward–backward" : ""); \(p.pencilDisplay.rawValue.lowercased())", active: pencil)],
            [DiagramBlock(title: "Range profile", detail: "trace (\(p.traceAveraging)-pulse average)\(p.peakHold ? ", peak hold" : "")\(pencil ? ", ▼ estimated targets" : ""); top \(p.autoTop ? "tracked automatically" : "fixed")", kind: .output),
             DiagramBlock(title: "RTI waterfall", detail: "every pulse kept for \(Int(p.rtiSeconds)) s; dynamic range and time-span sliders", kind: .output)],
        ]
        let rd: [[DiagramBlock]] = [
            [DiagramBlock(title: "Complex range profiles", detail: "each pulse after background removal, windowed FFT; the last 256 kept", active: p.rdEnabled)],
            [DiagramBlock(title: "Range PGA (map)", detail: "fast-time phase error removed for the map only", active: p.rdEnabled && p.rdRangePGA),
             DiagramBlock(title: "Doppler PGA", detail: "pulse-to-pulse phase error shared by all range bins, re-estimated for every map", active: p.rdEnabled && p.rdDopplerPGA)],
            [DiagramBlock(title: "Slow-time FFT", detail: "\(p.rdPulses) pulses, \(p.rdWindow.rawValue) window", active: p.rdEnabled && p.rdSuperRes == .off),
             DiagramBlock(title: "Matrix pencil", detail: "\(p.rdSuperRes == .off ? "range, Doppler or both" : p.rdSuperRes.rawValue.replacingOccurrences(of: "Matrix pencil in ", with: "")); model order \(p.rdOrderRule.rawValue)", active: p.rdEnabled && p.rdSuperRes != .off)],
            [DiagramBlock(title: "Range-Doppler map", detail: "velocity in m/s (+ = approaching), strongest mover, model orders and scatterer count; built on its own thread", active: p.rdEnabled, kind: .output)],
        ]
        let mp = p.dtMethod == .matrixPencil
        let fileName = model.dt?.fileName
        let dtRows: [[DiagramBlock]] = [
            [DiagramBlock(title: "Audio input (CW)", detail: "the radar run unmodulated (Vtune fixed, fc = \(Int(p.dtCarrierMHz)) MHz): only the IF on the \(ifc) input; no sync needed", active: fileName == nil, kind: .input),
             DiagramBlock(title: "Recording (.wav)", detail: fileName.map { "\($0), IF channel \(ifc)" } ?? "e.g. MIT's \"Off of Newton Exit 17.wav\"", active: fileName != nil, kind: .input)],
            [DiagramBlock(title: "Dwells", detail: "N = Tp·fs = \(Int((p.dtDwellMs / 1000 * d.fs).rounded())) samples per Doppler spectrum (Tp = \(String(format: "%g", p.dtDwellMs)) ms)\(p.dtOverlap > 0 ? String(format: ", %.0f%% overlapped: a new row every %.0f ms", p.dtOverlap * 100, p.dtDwellMs * (1 - p.dtOverlap)) : "")\(p.dtSubtractMean ? "; mean subtracted (the whole recording's, as MIT's script)" : "")")],
            [DiagramBlock(title: "PGA (strongest mover)", detail: "per dwell: the dominant line's phase wander removed, keeping its mean velocity; kept only if sharper", active: p.dtPGA)],
            [DiagramBlock(title: "FFT", detail: "\(p.dtWindow.rawValue) window, zero pad \(p.dtZeroPad)×", active: !mp && !p.dtSVA),
             DiagramBlock(title: "SVA", detail: "per-bin weighting between rectangular and Hann", active: !mp && p.dtSVA),
             DiagramBlock(title: "Matrix pencil", detail: "band 0–\(Int(p.dtMaxVelocity)) m/s decimated, TLS pencil, model order \(p.dtOrderRule.rawValue)", active: mp)],
            [DiagramBlock(title: "Doppler vs. time", detail: "v = f·λ/2 (speed: the real IF can't tell approaching from receding), 0–\(Int(p.dtMaxVelocity)) m/s, \(Int(p.dtDbRange)) dB below the strongest", kind: .output),
             DiagramBlock(title: "Doppler spectrum", detail: "one dwell (newest, or the time clicked), strongest mover in m/s and mph", kind: .output)],
        ]
        let diag: [[DiagramBlock]] = [
            [DiagramBlock(title: "Diagnostics tab", detail: "last triggered pulse (sync and IF, full scale), rising-edge zoom with the interpolation, PGA phase estimates", kind: .output)],
        ]
        VStack(alignment: .leading, spacing: 12) {
                Text("How the RTI, range-Doppler and Doppler vs. time processing works").font(.title3.weight(.semibold))
                Text("The blocks follow your current settings: coloured blocks are in use, grey dashed ones are switched off.")
                    .font(.callout).foregroundStyle(.secondary)
                DiagramLegend()
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Range processing (every pulse)").font(.headline)
                        BlockDiagram(rows: main)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Range-Doppler branch (from background removal)").font(.headline)
                        BlockDiagram(rows: rd)
                        Text("Diagnostics").font(.headline).padding(.top, 8)
                        BlockDiagram(rows: diag)
                    }
                }
                Text("Doppler vs. time tab (CW, after MIT's read_data_doppler.m)").font(.headline).padding(.top, 4)
                BlockDiagram(rows: dtRows)
                Text("The SAR imaging tab has its own How it works view.").font(.callout).foregroundStyle(.secondary)
                AboutCard(appName: AboutInfo.appName)
        }
    }
}
