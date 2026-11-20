import SwiftUI

/// "How it works" tab: the SAR app's processing chain, drawn from the current settings.
struct HowItWorksSAR: View {
    var body: some View {
        ScrollView { HowItWorksSARContent().padding(.vertical, 4) }
    }
}

struct HowItWorksSARContent: View {
    @EnvironmentObject var model: SARModel

    var body: some View {
        let p = model.params
        let positions = model.result.map { "\($0.parsed.positions) positions" } ?? "one per burst"
        let bp = p.algorithm == .backprojection
        let crossPencil = p.superRes.inCrossrange && bp
        let theta = gratingLobeFreeAngle(p) * 180 / .pi
        let svaKind = p.svaMode == .dual ? "dual apodization (smaller of unweighted and Hann)"
            : "\(p.svaMode == .joint ? "joint I/Q" : "I and Q separately")\(p.svaHannCap ? ", limited by the Hann image" : "")"
        let rows: [[DiagramBlock]] = [
            [DiagramBlock(title: "Recording (.wav)", detail: "Coffee Can Radar on a rail: sync on the \(p.syncOnRight ? "right" : "left") channel, IF on the \(p.syncOnRight ? "left" : "right")\(p.invert ? ", both inverted" : ""); the radar is moved \(String(format: "%g", p.spacingInches)) in between bursts", kind: .input)],
            [DiagramBlock(title: "Find aperture positions", detail: "a position starts where the sync returns after ≥ \(String(format: "%g", p.trpSeconds)) s of silence (MIT SBAND_RMA_opendata.m): \(positions)")],
            [DiagramBlock(title: "Sync edges", detail: p.alignment == .interpolated
                            ? "rising edge after ≥ \(p.holdoff) low samples, upsampled \(p.interpolation)× with a windowed sinc and refined linearly (as in the RTI app); each up-chirp resampled to start there"
                            : "MIT rule: the integer sample where the sync peaks after a rising edge")],
            [DiagramBlock(title: "Average up-chirps", detail: p.chirpsPerPosition > 0 ? "the first \(p.chirpsPerPosition) complete up-chirps at every position, the same number everywhere"
                                                                                        : "MIT: every chirp in the first Trp (varies by position)"),
             DiagramBlock(title: "Hilbert transform", detail: "ifft, keep one half, fft: N/2 complex samples per position, the phase history over \(Int(p.fStartMHz))–\(Int(p.fStopMHz)) MHz")],
            [DiagramBlock(title: "Aperture mean subtraction", detail: p.mitMean ? "MIT's running mean (leaves about 37% of the antenna leakage)" : "exact mean over the aperture: removes the antenna leakage", active: p.subtractMean)],
            [DiagramBlock(title: "Range PGA", detail: "one phase per frequency sample, shared by every sweep (VCO nonlinearity)", active: p.rangePGA),
             DiagramBlock(title: "Crossrange autofocus", detail: "one phase per position, so each adds coherently to the strongest scatterers", active: p.crossPGA)],
            [DiagramBlock(title: "Range super-resolution", detail: "matrix pencil per position extends the band \(p.bweFactor)×, measured samples kept in the middle", active: p.superRes.inRange)],
            [DiagramBlock(title: "Backprojection", detail: "AFRL bpBasic.m (Gorham & Moore): per position, the zero-padded range profile is interpolated at each pixel's range, phase-corrected and summed", active: bp),
             DiagramBlock(title: "Range migration", detail: "MIT SBAND_RMA_IFP.m: Hann window, along-track FFT, matched filter, Stolt interpolation, 2-D inverse FFT", active: !bp)],
            [DiagramBlock(title: "Crossrange super-resolution", detail: "per-pixel matrix pencil over the positions' focused contributions; keeps the power near zero frequency (backprojection only)", active: crossPencil),
             DiagramBlock(title: "SVA", detail: svaKind + "; local carrier removed first", active: p.sva && !crossPencil)],
            [DiagramBlock(title: "Range scaling", detail: "× range^(3/2) by \(p.scaleBySlantRange ? "true range from the aperture centre" : "downrange (MIT)")", active: p.rangeScaling),
             DiagramBlock(title: "Grating-lobe blanking", detail: theta >= 89.9 ? "no grating lobes at this spacing: full ±90°" : String(format: "beyond ±%.1f° (aliases from the %g-inch spacing)", theta, p.spacingInches), active: p.blankGratingLobes && theta < 89.9)],
            [DiagramBlock(title: "SAR image", detail: "crossrange vs downrange in ft, equal scale, \(Int(p.dbRange)) dB colour range", kind: .output),
             DiagramBlock(title: "Range profiles", detail: "every position's range profile", kind: .output),
             DiagramBlock(title: "K-space", detail: "after Stolt interpolation (range migration)", active: !bp, kind: .output),
             DiagramBlock(title: "Autofocus", detail: "estimated phase errors", active: p.rangePGA || p.crossPGA, kind: .output)],
        ]
        VStack(alignment: .leading, spacing: 12) {
            Text("How SAR imaging works").font(.title3.weight(.semibold))
            Text("The blocks follow your current settings: coloured blocks are in use, grey dashed ones are switched off.")
                .font(.callout).foregroundStyle(.secondary)
            DiagramLegend()
            BlockDiagram(rows: rows)
            AboutCard(appName: AboutInfo.appName)
        }
    }
}
