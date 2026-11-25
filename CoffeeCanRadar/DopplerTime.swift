import Accelerate
import CoreGraphics
import Foundation

// Doppler vs. time for the radar run as an unmodulated CW radar (Vtune held fixed), after
// MIT's read_data_doppler.m: the IF channel is cut into dwells of Tp seconds, the mean is
// subtracted, and each dwell's zero-padded FFT gives one row of velocity v = f·λ/2.
// Dwells may overlap (a sliding window): a new row every hop = Tp·(1 − overlap).
// The IF is real, so approaching and receding targets look the same (speed only).

/// Settings the Doppler-vs-time processing depends on; a change re-processes the history.
struct DTSettings: Equatable {
    var dwellMs: Double
    var overlap: Double
    var carrierMHz: Double
    var zeroPad: Int
    var window: WindowType
    var sva: Bool
    var pga: Bool
    var pgaMinVelocity: Double
    var pgaIterations: Int
    var method: DTMethod
    var orderRule: PencilOrderRule
    var maxTargets: Int
    var display: PencilDisplay
    var esterThreshold: Double
    var thresholdDB: Double
    var peakWidth: Double
    var forwardBackward: Bool
    var maxVelocity: Double
    var subtractMean: Bool
    var ifOnLeft: Bool

    init(_ p: RadarParams) {
        dwellMs = min(2000, max(20, p.dtDwellMs))
        overlap = min(0.9375, max(0, p.dtOverlap))
        carrierMHz = max(100, p.dtCarrierMHz)
        zeroPad = max(1, p.dtZeroPad)
        window = p.dtWindow
        sva = p.dtSVA
        pga = p.dtPGA
        pgaMinVelocity = max(0, p.dtPGAMinVelocity)
        pgaIterations = max(1, p.pgaIterations)
        method = p.dtMethod
        orderRule = p.dtOrderRule
        maxTargets = max(1, p.dtMaxTargets)
        display = p.dtPencilDisplay
        esterThreshold = p.esterThreshold
        thresholdDB = p.pencilThresholdDB
        peakWidth = p.pencilPeakWidth
        forwardBackward = p.pencilForwardBackward
        maxVelocity = max(1, p.dtMaxVelocity)
        subtractMean = p.dtSubtractMean
        ifOnLeft = p.syncOnRight
    }

    var lambda: Double { speedOfLight / (carrierMHz * 1e6) }
}

/// Sizes that follow from the settings and the sample rate.
struct DTGeometry: Equatable {
    let fs: Double
    let n: Int            // samples per dwell, N = Tp*FS
    let hop: Int          // samples from one dwell's start to the next (N without overlap)
    let m: Int            // power of two >= N (analytic signal, PGA, pencil decimation)
    let log2m: Int
    let nfft: Int         // power of two >= zeroPad*N (displayed spectrum)
    let log2nfft: Int
    let binHz: Double
    let cols: Int         // spectrum bins shown, 0 ... max velocity
    let mpsPerCol: Double
    let lambda: Double

    init(_ s: DTSettings, fs: Double) {
        self.fs = fs
        n = max(16, Int((s.dwellMs / 1000 * fs).rounded()))
        hop = max(1, min(n, Int((Double(n) * (1 - s.overlap)).rounded())))
        log2m = Int(ceil(log2(Double(n))))
        m = 1 << log2m
        log2nfft = min(DopplerTimeDSP.maxLog2, max(log2m, Int(ceil(log2(Double(s.zeroPad * n))))))
        nfft = 1 << log2nfft
        binHz = fs / Double(nfft)
        lambda = s.lambda
        mpsPerCol = binHz * lambda / 2
        cols = max(4, min(nfft / 2, Int(2 * s.maxVelocity / lambda / binHz) + 1))
    }

    var dwellSeconds: Double { Double(n) / fs }
    var hopSeconds: Double { Double(hop) / fs }
    /// Number of whole dwells in `count` samples.
    func dwells(in count: Int) -> Int { count < n ? 0 : (count - n) / hop + 1 }
}

/// One dwell's spectrum: dB (amplitude of the real sine) per velocity bin, plus what the options did.
struct DTRow {
    var db: [Float]
    var order: Int?                                   // matrix pencil model order
    var pga: Bool?                                    // PGA: nil = off or no dominant mover, true = applied
    var lines: [(velocity: Double, db: Double)] = []  // matrix pencil: each pole in the band
}

/// The per-dwell signal processing. Not thread safe: use from one queue.
final class DopplerTimeDSP {
    static let maxLog2 = 20
    private var setupStorage: FFTSetupD?
    private var setupLog2 = 0
    private var setup: FFTSetupD { setupStorage! }
    private var windowCache: (n: Int, type: WindowType, w: [Double], sum: Double)?
    private var pencilCache: MatrixPencil?

    deinit { if let s = setupStorage { vDSP_destroy_fftsetupD(s) } }

    private func prepare(_ g: DTGeometry) {
        let need = max(g.log2nfft, g.log2m)
        guard need > setupLog2 else { return }
        if let s = setupStorage { vDSP_destroy_fftsetupD(s) }
        setupStorage = vDSP_create_fftsetupD(vDSP_Length(need), FFTRadix(kFFTRadix2))
        setupLog2 = need
    }

    private func window(_ type: WindowType, n: Int) -> (w: [Double], sum: Double) {
        if let c = windowCache, c.n == n, c.type == type { return (c.w, c.sum) }
        var p = RadarParams()
        p.window = type
        let w = makeWindow(p, n: n)
        let sum = w.reduce(0, +)
        windowCache = (n, type, w, sum)
        return (w, sum)
    }

    private static func db(_ re: Double, _ im: Double, _ scale: Double) -> Float {
        Float(10 * log10((re * re + im * im) * scale * scale + 1e-30))
    }

    /// Processes one dwell `x` (mean already removed), length g.n.
    func process(_ x: [Double], s: DTSettings, g: DTGeometry) -> DTRow {
        prepare(g)
        let n = g.n
        // MIT path: FFT of the real dwell. A real sine of amplitude A peaks at A*sum(w)/2.
        if !s.pga && s.method == .fft {
            var re: [Double], im: [Double], scale: Double
            if s.sva {
                (re, im) = svaSpectrum(setup: setup, re: x, im: [Double](repeating: 0, count: n), n: n, log2n: g.log2nfft)
                scale = 2 / Double(n)
            } else {
                let (w, sum) = window(s.window, n: n)
                re = [Double](repeating: 0, count: g.nfft); im = re
                for t in 0..<n { re[t] = x[t] * w[t] }
                fftInPlace(setup, &re, &im, log2n: g.log2nfft)
                scale = 2 / sum
            }
            return DTRow(db: (0..<g.cols).map { DopplerTimeDSP.db(re[$0], im[$0], scale) })
        }

        // Analytic signal (positive frequencies only): a real sine of amplitude A becomes A·e^{jφ(t)}.
        let m = g.m
        var ar = [Double](repeating: 0, count: m), ai = ar
        for t in 0..<n { ar[t] = x[t] }
        fftInPlace(setup, &ar, &ai, log2n: g.log2m)
        for k in 1..<(m / 2) { ar[k] *= 2; ai[k] *= 2 }
        for k in (m / 2 + 1)..<m { ar[k] = 0; ai[k] = 0 }
        fftInPlace(setup, &ar, &ai, log2n: g.log2m, inverse: true)
        var zr = (0..<n).map { ar[$0] / Double(m) }, zi = (0..<n).map { ai[$0] / Double(m) }

        var pgaApplied: Bool?
        if s.pga { pgaApplied = dwellPGA(re: &zr, im: &zi, s: s, g: g) }

        if s.method == .matrixPencil {
            var row = pencil(re: zr, im: zi, s: s, g: g)
            row.pga = pgaApplied
            return row
        }
        var re: [Double], im: [Double], scale: Double
        if s.sva {
            (re, im) = svaSpectrum(setup: setup, re: zr, im: zi, n: n, log2n: g.log2nfft)
            scale = 1 / Double(n)
        } else {
            let (w, sum) = window(s.window, n: n)
            re = [Double](repeating: 0, count: g.nfft); im = re
            for t in 0..<n { re[t] = zr[t] * w[t]; im[t] = zi[t] * w[t] }
            fftInPlace(setup, &re, &im, log2n: g.log2nfft)
            scale = 1 / sum
        }
        return DTRow(db: (0..<g.cols).map { DopplerTimeDSP.db(re[$0], im[$0], scale) }, pga: pgaApplied)
    }

    // MARK: PGA

    /// Phase gradient autofocus on the dominant mover of one dwell (prominent-point PGA).
    ///
    /// With no range dimension there is one "range bin": the strongest line between the minimum
    /// velocity and the maximum shown is circularly shifted to zero Doppler, windowed (the window
    /// shrinks each iteration), and transformed back; the sample-to-sample phase change of what is
    /// left is the phase that smears the line (acceleration, oscillator drift, vibration). Its
    /// integral, less its linear trend (so the target keeps its velocity), is removed. The result is
    /// kept only if the spectrum gets sharper. Returns true when applied, nil when there was no
    /// dominant line (at least 20 dB above the median of the band).
    private func dwellPGA(re zr: inout [Double], im zi: inout [Double], s: DTSettings, g: DTGeometry) -> Bool? {
        let n = g.n, m = g.m, binM = g.fs / Double(m)
        let kLo = max(1, Int(ceil(2 * s.pgaMinVelocity / g.lambda / binM)))
        let kHi = min(m / 2 - 1, Int(Double(g.cols) * g.binHz / binM))
        guard kHi > kLo + 8 else { return nil }
        var gr = zr, gi = zi
        var width = max(16, Int(150 / binM))          // ±75 Hz to start
        let minWidth = max(8, Int(20 / binM))         // ±10 Hz at the end
        var re = [Double](repeating: 0, count: m), im = re, sr = re, si = re
        for it in 0..<s.pgaIterations {
            for k in 0..<m { re[k] = k < n ? gr[k] : 0; im[k] = k < n ? gi[k] : 0 }
            fftInPlace(setup, &re, &im, log2n: g.log2m)
            var kp = kLo, best = -1.0
            var band: [Double] = []
            band.reserveCapacity(kHi - kLo + 1)
            for k in kLo...kHi {
                let p = re[k] * re[k] + im[k] * im[k]
                band.append(p)
                if p > best { best = p; kp = k }
            }
            if it == 0 {
                band.sort()
                guard best > 100 * band[band.count / 2] else { return nil }
            }
            for k in 0..<m { sr[k] = 0; si[k] = 0 }
            let half = width / 2
            for dk in -half...half {
                let src = (kp + dk + m) % m, dst = (dk + m) % m
                sr[dst] = re[src]; si[dst] = im[src]
            }
            fftInPlace(setup, &sr, &si, log2n: g.log2m, inverse: true)
            var residual = [Double](repeating: 0, count: n)
            for t in 1..<n {
                let cr = sr[t] * sr[t - 1] + si[t] * si[t - 1], ci = si[t] * sr[t - 1] - sr[t] * si[t - 1]
                residual[t] = residual[t - 1] + atan2(ci, cr)
            }
            removeLinearTrend(&residual)
            for t in 0..<n {
                let c = cos(residual[t]), sn = sin(residual[t])
                let a = gr[t], b = gi[t]
                gr[t] = a * c + b * sn; gi[t] = b * c - a * sn
            }
            width = max(minWidth, Int(Double(width) * 0.6))
            if rms(residual) < 0.005 { break }
        }
        guard sharpness(gr, gi, g: g, band: kLo...kHi) > sharpness(zr, zi, g: g, band: kLo...kHi) * 1.001 else { return false }
        zr = gr; zi = gi
        return true
    }

    /// sum|X|^4 / (sum|X|^2)^2 over the band: larger is more focused.
    private func sharpness(_ zr: [Double], _ zi: [Double], g: DTGeometry, band: ClosedRange<Int>) -> Double {
        var re = [Double](repeating: 0, count: g.m), im = re
        for t in 0..<g.n { re[t] = zr[t]; im[t] = zi[t] }
        fftInPlace(setup, &re, &im, log2n: g.log2m)
        var s2 = 0.0, s4 = 0.0
        for k in band { let p = re[k] * re[k] + im[k] * im[k]; s2 += p; s4 += p * p }
        return s2 > 0 ? s4 / (s2 * s2) : 0
    }

    // MARK: matrix pencil

    /// Matrix pencil (Hua & Sarkar TLS) on the dwell's analytic signal, band-limited to 0 ... max
    /// velocity and decimated in the frequency domain so the fit has a few hundred samples.
    private func pencil(re zr: [Double], im zi: [Double], s: DTSettings, g: DTGeometry) -> DTRow {
        let n = g.n, m = g.m, binM = g.fs / Double(m)
        var re = [Double](repeating: 0, count: m), im = re
        for t in 0..<n { re[t] = zr[t]; im[t] = zi[t] }
        fftInPlace(setup, &re, &im, log2n: g.log2m)
        // keep bins 0 ..< kb (the shown band plus a margin), centred at c0, in a kp-point spectrum
        let fHi = Double(g.cols) * g.binHz * 1.05 + 2 * binM
        let kb = min(m / 2, Int(ceil(fHi / binM)) + 1)
        var kp = 64
        while Double(kp) < 1.25 * Double(kb) { kp *= 2 }
        kp = min(kp, m)
        let log2kp = Int(log2(Double(kp)))
        let c0 = kb / 2
        var yr = [Double](repeating: 0, count: kp), yi = yr
        for k in 0..<kb { let d = (k - c0 + kp) % kp; yr[d] = re[k]; yi[d] = im[k] }
        fftInPlace(setup, &yr, &yi, log2n: log2kp, inverse: true)
        let nd = min(kp, Int(Double(n) * Double(kp) / Double(m)))
        let fsd = g.fs * Double(kp) / Double(m)
        let fc0 = Double(c0) * binM
        let dr = (0..<nd).map { yr[$0] / Double(m) }, di = (0..<nd).map { yi[$0] / Double(m) }
        var row = DTRow(db: [Float](repeating: -300, count: g.cols))
        guard nd >= 12 else { return row }
        if pencilCache?.n != nd { pencilCache = MatrixPencil(n: nd, pencil: nd / 3) }
        guard let mp = pencilCache,
              let r = mp.analyze(re: dr, im: di, maxOrder: s.maxTargets, thresholdDB: s.thresholdDB, rule: s.orderRule,
                                 pairs: false, esterThreshold: s.esterThreshold, forwardBackward: s.forwardBackward),
              r.order > 0 else { return row }
        row.order = r.order
        let fShow = Double(g.cols) * g.binHz
        for k in 0..<r.order {
            let f = r.poles[k].arg / (2 * .pi) * fsd + fc0
            if f >= 0 && f <= fShow { row.lines.append((f * g.lambda / 2, 10 * log10(r.power[k] + 1e-30))) }
        }
        switch s.display {
        case .pseudospectrum:
            let top = r.power.prefix(r.order).max() ?? 0
            let omegas = (0..<g.cols).map { 2 * Double.pi * (Double($0) * g.binHz - fc0) / fsd }
            let eps = 2 * Double.pi * g.binHz / fsd * max(0.1, s.peakWidth), eps2 = eps * eps
            let s2 = MatrixPencil.sigmaMin2(schur: r.schur, order: r.order, omegas: omegas)
            row.db = (0..<g.cols).map { Float(10 * log10(top * eps2 / (s2[$0] + eps2) + 1e-30)) }
        case .amplitudeWeighted:
            for l in row.lines {
                let c = Int((l.velocity / g.mpsPerCol).rounded())
                for cc in max(0, c - 1)...min(g.cols - 1, c + 1) { row.db[cc] = max(row.db[cc], Float(l.db) - (cc == c ? 0 : 6)) }
            }
        }
        return row
    }
}

// MARK: - Engine: history, live input, recordings

/// What the Doppler-vs-time display shows.
struct DTSnapshot {
    var image: CGImage?
    var rows: [[Float]] = []           // dB per dwell, oldest first
    var lines: [[(velocity: Double, db: Double)]] = []
    var maxDB: Float = 0               // strongest cell (the colour scale is relative to it, as in MIT's script)
    var dwellSeconds: Double = 0.25
    var hopSeconds: Double = 0.25      // time between rows (dwell start to dwell start)
    var secondsPerPixel: Double = 0.25 // live: the image's time per pixel row (it is drawn one row per screen pixel)
    var mpsPerCol: Double = 0
    var cols: Int = 0
    var fileName: String?              // nil = live input
    var msPerDwell: Double?
    var medianOrder: Double?
    var pgaApplied = 0
    var pgaTried = 0
    var pgaDominant = 0
    var waitingSamples = 0             // live: samples collected toward the next row
    var samplesPerDwell = 0            // live: samples needed per new row (the hop)
    var ifRMS: Double = 0              // level of the channel used as IF
    var otherRMS: Double = 0           // level of the other channel (to spot swapped inputs)
}

/// Keeps the IF samples and one spectrum per dwell; re-processes everything when a setting
/// changes. Runs on its own queue (all methods except `request`).
final class DopplerTimeEngine {
    private let dsp = DopplerTimeDSP()
    private let lock = NSLock()
    private var pending: RadarParams?
    private var pendingPixelRows: Int?
    private var pixelRows = 400          // the plot's height in screen pixels: the image never has more rows
    private var dropped = 0              // live rows trimmed so far (keeps the row groups fixed as the plot scrolls)
    private var s = DTSettings(RadarParams())
    private var dbRange = 35.0
    private var topOffset = 0.0         // colour-scale top re the strongest cell
    private var historySeconds = 60.0
    private var liveFs = 48000.0
    private var g = DTGeometry(DTSettings(RadarParams()), fs: 48000)

    private var samples: [Float] = []    // the IF channel: the live history, or the whole recording
    private var rows: [DTRow] = []       // dwell i = samples[i*hop ..< i*hop + n]
    private var rowMs: [Double] = []
    private var fileName: String?
    private var fileL: [Float] = [], fileR: [Float] = []
    private var fileFs = 44100.0
    private var fileMean: Double = 0
    private var levelL = 0.0, levelR = 0.0  // RMS of each input: the whole recording, or smoothed live

    var onSnapshot: ((DTSnapshot) -> Void)?

    /// Thread safe: remembers the newest settings; `applyPending` (on the queue) uses them.
    func request(_ p: RadarParams) { lock.lock(); pending = p; lock.unlock() }

    /// Thread safe: the plot's height in screen pixels; `applyPending` redraws the image to fit.
    func requestPixelRows(_ px: Int) { lock.lock(); pendingPixelRows = max(40, min(4000, px)); lock.unlock() }

    func applyPending() {
        lock.lock(); let p = pending, px = pendingPixelRows; pending = nil; pendingPixelRows = nil; lock.unlock()
        if let px, px != pixelRows { pixelRows = px; if p == nil { publish() } }
        guard let p else { return }
        let ns = DTSettings(p)
        let rangeChanged = p.dtDbRange != dbRange || p.dtTopOffsetDB != topOffset
        dbRange = p.dtDbRange
        topOffset = p.dtTopOffsetDB
        historySeconds = p.dtHistorySeconds
        if ns != s {
            let channelChanged = ns.ifOnLeft != s.ifOnLeft
            s = ns
            if fileName != nil {
                if channelChanged { selectFileChannel() }
            } else if channelChanged {
                samples.removeAll()
            }
            reprocessAll()
        } else if rangeChanged {
            publish()
        } else {
            trimLive()
            publish()
        }
    }

    private var fs: Double { fileName != nil ? fileFs : liveFs }

    // live

    func startLive(fs: Double) {
        liveFs = fs
        guard fileName == nil else { return }
        samples.removeAll()
        reprocessAll()
    }

    /// A gap in the live audio: drop the partial dwell.
    func discontinuity() {
        guard fileName == nil else { return }
        // keep only what the dwells already made used (with overlap, the next dwell still spans the gap)
        let used = rows.isEmpty ? 0 : (rows.count - 1) * g.hop + g.n
        if samples.count > used { samples.removeLast(samples.count - used) }
    }

    func push(_ left: [Float], _ right: [Float]) {
        guard fileName == nil else { return }
        func rmsOf(_ x: [Float]) -> Double { x.isEmpty ? 0 : (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot() }
        let a = 0.05
        levelL = levelL * (1 - a) + a * rmsOf(left)
        levelR = levelR * (1 - a) + a * rmsOf(right)
        samples.append(contentsOf: s.ifOnLeft ? left : right)
        var added = false
        while samples.count >= rows.count * g.hop + g.n {
            processDwell(rows.count)
            added = true
        }
        if added { trimLive(); publish() }
    }

    private func trimLive() {
        guard fileName == nil else { return }
        let keep = max(1, Int(historySeconds / g.hopSeconds))
        if rows.count > keep {
            let drop = rows.count - keep
            rows.removeFirst(drop); rowMs.removeFirst(min(drop, rowMs.count))
            samples.removeFirst(drop * g.hop)
            dropped += drop
        }
    }

    // recordings

    func loadFile(name: String, left: [Float], right: [Float], fs: Double) {
        fileName = name
        fileL = left; fileR = right; fileFs = fs
        func rmsOf(_ x: [Float]) -> Double { x.isEmpty ? 0 : (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot() }
        levelL = rmsOf(left); levelR = rmsOf(right)
        selectFileChannel()
        reprocessAll()
    }

    func showLive() {
        guard fileName != nil else { return }
        fileName = nil
        fileL = []; fileR = []
        levelL = 0; levelR = 0
        samples.removeAll()
        reprocessAll()
    }

    private func selectFileChannel() {
        samples = s.ifOnLeft || fileR.isEmpty ? fileL : fileR
        // read_data_doppler.m: sif = sif - mean(s), the mean of the whole recording
        fileMean = samples.isEmpty ? 0 : samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
    }

    // processing

    private func reprocessAll() {
        g = DTGeometry(s, fs: fs)
        rows.removeAll(); rowMs.removeAll(); dropped = 0
        let count = g.dwells(in: samples.count)
        if count > 8 {
            // dwells in parallel, each worker with its own DSP state
            var out = [DTRow?](repeating: nil, count: count)
            var ms = [Double](repeating: 0, count: count)
            let chunks = max(1, min(count, ProcessInfo.processInfo.activeProcessorCount * 2))
            let (ss, gg) = (s, g)
            let mean: Double? = fileName != nil ? fileMean : nil
            samples.withUnsafeBufferPointer { sp in
                out.withUnsafeMutableBufferPointer { op in
                    ms.withUnsafeMutableBufferPointer { mp in
                        DispatchQueue.concurrentPerform(iterations: chunks) { c in
                            let dsp = DopplerTimeDSP()
                            for i in stride(from: c, to: count, by: chunks) {
                                let t0 = DispatchTime.now().uptimeNanoseconds
                                let x = DopplerTimeEngine.dwell(sp, i, gg, ss, fileMean: mean)
                                op[i] = dsp.process(x, s: ss, g: gg)
                                mp[i] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                            }
                        }
                    }
                }
            }
            rows = out.map { $0! }
            rowMs = ms
        } else {
            for i in 0..<count { processDwell(i) }
        }
        trimLive()
        publish()
    }

    private static func dwell(_ sp: UnsafeBufferPointer<Float>, _ i: Int, _ g: DTGeometry, _ s: DTSettings, fileMean: Double?) -> [Double] {
        var x = (0..<g.n).map { Double(sp[i * g.hop + $0]) }
        if s.subtractMean {
            let mean = fileMean ?? x.reduce(0, +) / Double(g.n)
            for t in x.indices { x[t] -= mean }
        }
        return x
    }

    private func processDwell(_ i: Int) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let x = samples.withUnsafeBufferPointer { DopplerTimeEngine.dwell($0, i, g, s, fileMean: fileName != nil ? fileMean : nil) }
        let row = dsp.process(x, s: s, g: g)
        if i == rows.count { rows.append(row) } else { rows[i] = row }
        rowMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        if rowMs.count > rows.count { rowMs.removeFirst(rowMs.count - rows.count) }
    }

    func publish() {
        var snap = DTSnapshot()
        snap.rows = rows.map(\.db)
        snap.lines = rows.map(\.lines)
        snap.dwellSeconds = g.dwellSeconds
        snap.hopSeconds = g.hopSeconds
        snap.mpsPerCol = g.mpsPerCol
        snap.cols = g.cols
        snap.fileName = fileName
        snap.samplesPerDwell = rows.isEmpty ? g.n : g.hop
        (snap.ifRMS, snap.otherRMS) = s.ifOnLeft ? (levelL, levelR) : (levelR, levelL)
        snap.waitingSamples = max(0, samples.count - (rows.isEmpty ? 0 : (rows.count - 1) * g.hop + g.n))
        let recent = rowMs.suffix(40)
        snap.msPerDwell = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
        let orders = rows.compactMap(\.order).sorted()
        snap.medianOrder = orders.isEmpty ? nil : Double(orders[orders.count / 2])
        snap.pgaTried = s.pga ? rows.count : 0
        snap.pgaDominant = rows.filter { $0.pga != nil }.count
        snap.pgaApplied = rows.filter { $0.pga == true }.count
        snap.maxDB = rows.lazy.compactMap { $0.db.max() }.max() ?? 0
        // rows per image row: fixed by the span shown (the live history, or the whole recording)
        let spanRows = fileName == nil ? max(rows.count, Int(historySeconds / g.hopSeconds)) : rows.count
        let perRow = max(1, (spanRows + pixelRows - 1) / pixelRows)
        // fewer rows than pixels: each row repeated a whole number of times
        let repeatRows = perRow == 1 ? max(1, pixelRows / max(1, spanRows)) : 1
        snap.secondsPerPixel = Double(perRow) * g.hopSeconds / Double(repeatRows)
        snap.image = makeImage(snap.rows, cols: g.cols, top: snap.maxDB + Float(topOffset), newestFirst: fileName == nil,
                               perRow: perRow, repeatRows: repeatRows, firstIndex: fileName == nil ? dropped : 0)
        onSnapshot?(snap)
    }

    /// Jet-coloured image, width = velocity bins, newest at the top when live, time running down
    /// from the top for a recording (as MIT's imagesc plot). Each image row combines `perRow` dwells
    /// (the strongest value in each bin, so brief movers stay visible), so the image is no taller
    /// than the plot: drawing a taller image drops a different set of rows each time it scrolls,
    /// which flickers. Groups are fixed by the dwell's absolute index (`firstIndex` = index of rows[0]).
    private func makeImage(_ rows: [[Float]], cols: Int, top: Float, newestFirst: Bool, perRow: Int, repeatRows: Int, firstIndex: Int) -> CGImage? {
        guard !rows.isEmpty, cols > 0 else { return nil }
        // group g holds absolute dwells g*perRow ..< (g+1)*perRow
        let g0 = firstIndex / perRow, g1 = (firstIndex + rows.count - 1) / perRow
        let h = g1 - g0 + 1
        var combined = [[Float]](repeating: [Float](repeating: -.infinity, count: cols), count: h)
        for (i, src) in rows.enumerated() {
            let gi = (firstIndex + i) / perRow - g0
            for k in 0..<min(cols, src.count) where src[k] > combined[gi][k] { combined[gi][k] = src[k] }
        }
        let lo = top - Float(dbRange), cs = Float(255 / max(1, dbRange))
        let hOut = h * repeatRows
        var rgba = [UInt8](repeating: 255, count: hOut * cols * 4)
        for r in 0..<hOut {
            let gr = r / repeatRows
            let src = combined[newestFirst ? h - 1 - gr : gr]
            for k in 0..<cols {
                let c = Int(max(0, min(255, ((src[k] - lo) * cs).rounded()))) * 4
                let i = (r * cols + k) * 4
                rgba[i] = RTIBuffer.jet[c]; rgba[i + 1] = RTIBuffer.jet[c + 1]; rgba[i + 2] = RTIBuffer.jet[c + 2]
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: cols, height: hOut, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
