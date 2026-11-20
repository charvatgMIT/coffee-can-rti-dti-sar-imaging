import Foundation

let speedOfLight = 3e8   // (m/s), as in read_data_RTI.m

enum Background: String, CaseIterable, Identifiable, Codable {
    case mean = "Subtract mean pulse"
    case none = "None"
    case twoPulse = "2-pulse canceller"
    var id: String { rawValue }
}

enum WindowType: String, CaseIterable, Identifiable, Codable {
    case rect = "Rectangular"
    case hann = "Hann"
    case blackman = "Blackman"
    case taylor = "Taylor"
    var id: String { rawValue }
}

enum RangeMethod: String, CaseIterable, Identifiable, Codable {
    case fft = "FFT"
    case matrixPencil = "Matrix pencil"
    var id: String { rawValue }
}

/// How the matrix pencil chooses its model order (number of scattering centres).
enum PencilOrderRule: String, CaseIterable, Identifiable, Codable {
    case ester = "ESTER (adaptive)"
    case gap = "Largest singular-value gap (adaptive)"
    case threshold = "Singular-value threshold"
    var id: String { rawValue }
}

/// Range-Doppler map estimator.
enum RDSuperRes: String, CaseIterable, Identifiable, Codable {
    case off = "FFT"
    case doppler = "Matrix pencil in Doppler"
    case range = "Matrix pencil in range"
    case both = "Matrix pencil in range and Doppler"
    var id: String { rawValue }
}

/// Doppler-vs-time (CW) spectrum estimator.
enum DTMethod: String, CaseIterable, Identifiable, Codable {
    case fft = "FFT"
    case matrixPencil = "Matrix pencil"
    var id: String { rawValue }
}

enum PencilDisplay: String, CaseIterable, Identifiable, Codable {
    case pseudospectrum = "Pseudospectrum"
    case amplitudeWeighted = "Amplitude-weighted lines"
    var id: String { rawValue }
}

/// User-adjustable settings. Defaults follow read_data_RTI.m.
struct RadarParams: Equatable, Codable {
    var tpMs: Double = 5             // up-ramp (pulse) time
    var band: Band = .full
    var fStartMHz: Double = VCO.minMHz
    var fStopMHz: Double = VCO.maxMHz
    var syncOnRight = false          // swap channels: sync on the RIGHT input, IF on the LEFT
    var invert = true                // trig = -Y(:,1), s = -Y(:,2)
    var threshold: Double = 0
    var holdoff = 11                 // samples that must be low before a rising edge
    var interpolation = 16           // edge upsampling factor (>= 10)
    var align = true                 // resample IF to start at the sub-sample edge
    var background: Background = .mean
    var meanLength = 200
    var window: WindowType = .rect
    var taylorNbar = 4                  // Taylor window: number of nearly constant-level sidelobes
    var taylorSidelobeDB: Double = 30   // Taylor window: peak sidelobe level below the mainlobe (dB)
    var rangeMethod: RangeMethod = .fft
    var pencilDisplay: PencilDisplay = .pseudospectrum
    var pencilOrderRule: PencilOrderRule = .ester
    var esterThreshold: Double = 0.3   // ESTER: keep the largest order whose 1/E^2 is at least this fraction of the best
    var autoTop = false              // keep the plot's top dB just above the strongest return
    var pencilForwardBackward = true // forward-backward averaging in the matrix pencil
    var pencilMaxTargets = 8         // model order cap (targets; a real pulse needs two poles each)
    var pencilThresholdDB: Double = 40   // singular values further below the largest are noise
    var pencilL = 0                  // pencil parameter L, 0 = N/3
    var pencilPeakWidth: Double = 1  // pseudospectrum peak half-width (FFT bins)
    var svaEnabled = false           // spatially variant apodization in range (replaces the window)
    var zeroPad = 4                  // zpad = 8*N/2 = 4N
    var traceAveraging = 1
    var peakHold = false
    var dbTop: Double = -10
    var dbRange: Double = 80
    var rtiDbRange: Double = 80      // waterfall colour range (dB below the top)
    var maxRangeShown: Double = 0    // 0 = full range
    var rtiSeconds: Double = 30      // RTI history length
    var rtiViewSeconds: Double = 0   // waterfall time span shown (0 = the whole history)
    var rangeUnit: RangeUnit = .feet // display only; processing is in metres
    var pgaEnabled = false           // range (fast-time) phase gradient autofocus
    var pgaPulses = 64               // pulses per PGA estimate
    var pgaIterations = 8
    var pgaMinRange: Double = 1.0    // ignore returns closer than this (DC / feed-through)
    var pgaMinAgreement: Double = 0.8   // reject estimates whose two half-block estimates correlate less than this
    var rdEnabled = true             // range-Doppler map
    var rdPulses = 64                // pulses per Doppler FFT (coherent processing interval)
    var rdWindow: WindowType = .hann // slow-time (Doppler) window
    var rdDbRange: Double = 40       // range-Doppler colour range (dB below the top)
    var rdRangePGA = true            // range-Doppler: fast-time (range) PGA correction
    var rdDopplerPGA = true          // range-Doppler: slow-time (Doppler) PGA correction
    var rdSuperRes: RDSuperRes = .both   // range-Doppler: FFT or matrix pencil super-resolution
    var rdOrderRule: PencilOrderRule = .ester   // range-Doppler pencil: model order rule
    var rdShowScatterers = false     // range-Doppler: mark the counted scatterers with ×
    // Doppler vs. time (unmodulated CW), after read_data_doppler.m
    var dtDwellMs: Double = 250      // Tp = 0.250 s per Doppler spectrum
    var dtCarrierMHz: Double = 2590  // fc (VCO Vtune at +5 V; 2495 MHz at +3.2 V stays in the ISM band)
    var dtZeroPad = 4                // zpad = 8*N/2 = 4N
    var dtWindow: WindowType = .rect
    var dtSVA = false
    var dtPGA = false
    var dtPGAMinVelocity: Double = 1 // PGA ignores slower returns (clutter near zero Doppler), m/s
    var dtMethod: DTMethod = .fft
    var dtOrderRule: PencilOrderRule = .ester
    var dtMaxTargets = 8
    var dtPencilDisplay: PencilDisplay = .pseudospectrum
    var dtMaxVelocity: Double = 40   // xlim([0 40])
    var dtDbRange: Double = 35       // imagesc(..., [-35, 0])
    var dtSubtractMean = true        // sif = sif - mean(s)
    var dtHistorySeconds: Double = 60   // live history kept
}

/// Quantities that follow from the settings and the sample rate.
struct Derived: Equatable {
    var fs: Double
    var n: Int                 // samples per pulse, N = Tp*FS
    var log2n: Int
    var nfft: Int
    var bandwidth: Double
    var rangeRes: Double       // c/(2*BW)
    var maxRange: Double       // rr*N/2
    var metersPerBin: Double
    var rShow: Double
    var nBins: Int             // FFT bins drawn (0 ... rShow); all nfft/2 bins are computed

    init(_ p: RadarParams, fs: Double) {
        self.fs = fs
        let tp = p.tpMs * 1e-3
        n = max(16, Int((tp * fs).rounded()))
        log2n = Int(ceil(log2(Double(max(1, p.zeroPad) * n))))
        nfft = 1 << log2n
        bandwidth = max(1, (p.fStopMHz - p.fStartMHz) * 1e6)
        rangeRes = speedOfLight / (2 * bandwidth)
        maxRange = rangeRes * Double(n) / 2
        metersPerBin = (fs / Double(nfft)) * speedOfLight * tp / (2 * bandwidth)
        rShow = p.maxRangeShown > 0 ? min(p.maxRangeShown, maxRange) : maxRange
        nBins = max(2, min(nfft / 2, Int(ceil(rShow / metersPerBin)) + 1))
    }
}

/// Window applied to each pulse before the FFT (MATLAB's ifft in read_data_RTI.m).
func makeWindow(_ p: RadarParams, n: Int) -> [Double] {
    switch p.window {
    case .rect:
        return [Double](repeating: 1, count: n)
    case .hann:
        return (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
    case .blackman:
        return (0..<n).map {
            let x = 2 * Double.pi * Double($0) / Double(n - 1)
            return 0.42 - 0.5 * cos(x) + 0.08 * cos(2 * x)
        }
    case .taylor:
        return taylorWindow(n: n, nbar: p.taylorNbar, sidelobeDB: p.taylorSidelobeDB)
    }
}

/// Taylor window, as MATLAB's taylorwin(n, nbar, -sidelobeDB).
func taylorWindow(n: Int, nbar: Int, sidelobeDB: Double) -> [Double] {
    let nbar = max(1, nbar)
    let a = acosh(pow(10, abs(sidelobeDB) / 20)) / Double.pi
    let sp2 = Double(nbar * nbar) / (a * a + pow(Double(nbar) - 0.5, 2))
    let mi = Array(1..<max(1, nbar))
    let fm: [Double] = mi.map { m in
        let md = Double(m)
        let numer = mi.reduce(1.0) { $0 * (1 - md * md / sp2 / (a * a + pow(Double($1) - 0.5, 2))) }
        let denom = 2 * mi.filter { $0 != m }.reduce(1.0) { $0 * (1 - md * md / Double($1 * $1)) }
        return (m % 2 == 1 ? 1.0 : -1.0) * numer / denom
    }
    return (0..<n).map { k in
        let xi = (Double(k) - 0.5 * Double(n) + 0.5) / Double(n)
        return 1 + 2 * zip(mi, fm).reduce(0.0) { $0 + $1.1 * cos(2 * Double.pi * Double($1.0) * xi) }
    }
}

/// Centre-frequency wavelength (m), for converting Doppler to velocity.
func wavelength(_ p: RadarParams) -> Double {
    speedOfLight / max(1, (p.fStartMHz + p.fStopMHz) / 2 * 1e6)
}

/// Units for showing range. All processing stays in metres.
enum RangeUnit: String, CaseIterable, Identifiable, Codable {
    case feet = "Feet"
    case meters = "Metres"
    var id: String { rawValue }

    /// Display units per metre.
    var perMeter: Double { self == .feet ? 1 / 0.3048 : 1 }
    var abbreviation: String { self == .feet ? "ft" : "m" }
    /// Small unit for range resolution: inches or centimetres.
    var fine: (perMeter: Double, abbreviation: String) { self == .feet ? (1 / 0.0254, "in") : (100, "cm") }
}
