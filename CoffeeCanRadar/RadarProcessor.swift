import Accelerate
import CoreGraphics
import Foundation

/// Half-width (taps per side) of the windowed-sinc interpolator.
let kernelHalf = 16

/// sinc(u) tapered by a Blackman window spanning +/- kernelHalf samples.
@inline(__always) func sincKernel(_ u: Double) -> Double {
    if u == 0 { return 1 }
    if abs(u) >= Double(kernelHalf) { return 0 }
    let pu = Double.pi * u
    let wx = Double.pi * (u / Double(kernelHalf) + 1)
    return sin(pu) / pu * (0.42 - 0.5 * cos(wx) + 0.08 * cos(2 * wx))
}

/// Band-limited value of x at fractional index t.
@inline(__always) func interpolate(_ x: UnsafeMutablePointer<Float>, at t: Double) -> Double {
    let n0 = Int(floor(t))
    let f = t - Double(n0)
    if f == 0 { return Double(x[n0]) }
    var s = 0.0
    for m in (-kernelHalf + 1)...kernelHalf {
        s += Double(x[n0 + m]) * sincKernel(f - Double(m))
    }
    return s
}

struct ScopeSnapshot {
    var left: [Float]
    var right: [Float]
    var pre: Int          // samples before the trigger
    var fs: Double
    var n: Int
}

struct EdgeSnapshot {
    var samples: [Float]  // original samples at -span ... +span around the integer trigger
    var fine: [Float]     // sinc-interpolated curve, `upsample` points per sample
    var upsample: Int
    var edgeOffset: Double  // interpolated edge relative to the integer trigger (samples)
    var threshold: Double
    var span: Int
}

/// One range-Doppler map: slow-time FFT of the newest `pulses` complex range profiles.
struct RangeDopplerSnapshot {
    var image: CGImage            // width = range bins from 0, height = Doppler bins, most approaching at the top
    var pulses: Int
    var velocityStep: Double      // m/s per Doppler bin
    var topVelocity: Double       // m/s at the centre of the top row (+ = approaching)
    var peak: (range: Double, velocity: Double, db: Double)?   // strongest cell off zero Doppler
    var slowPhase: [Float]?       // slow-time (Doppler) PGA correction (rad) per pulse, when on
    var rows: Int = 0             // image rows (Doppler cells x super-resolution upsampling)
    var ms: Double = 0            // time to build the map
    var db: [Float] = []          // the map in dB, [row][range bin]
}

/// Everything one range-Doppler map needs, copied off the DSP queue.
struct RangeDopplerInput {
    var m: Int, log2m: Int, nr: Int, n: Int, nfft: Int
    var metersPerBin: Double
    var params: RadarParams
    var analytic: Bool              // fast-time samples are analytic (range PGA on) rather than the real IF
    var generation: Int
    var bre: [Double] = [], bim: [Double] = []   // complex range profiles, [range bin][pulse]
    var fre: [Double] = [], fim: [Double] = []   // fast-time samples, [pulse][sample]
}

struct ProcessorSnapshot {
    var derived: Derived
    var generation: Int
    var pulseCount: Int
    var traceDB: [Float]?
    var holdDB: [Float]?
    var newRows: [[Float]] = []
    var scope: ScopeSnapshot?
    var edge: EdgeSnapshot?
    var pulseRateHz: Double?
    var periodMs: Double?
    var jitterIntegerUs: Double?
    var jitterInterpUs: Double?
    var peakL: Float = 0
    var peakR: Float = 0
    /// RMS / peak over the last second of the trigger and IF channels (after any swap).
    /// A square-wave sync is close to 1; an IF signal is much lower.
    var squarenessTrigger: Double?
    var squarenessIF: Double?
    /// Range PGA phase-error estimate (rad) over the N fast-time samples, when enabled.
    var pgaPhase: [Float]?
    var pgaUpdates = 0
    var pgaAccepted = 0
    var pgaAgreement: Double?
    var pgaResidualRMS: Double?
    /// Matrix pencil targets (range in metres, power in dBFS) and model order, when in use.
    var pencilTargets: [(range: Double, db: Double)] = []
    var pencilOrder: Int?
    var pencilMs: Double?
    var rangeDoppler: RangeDopplerSnapshot?
    var rdCollected = 0
}

/// Triggers on the sync channel (left by default), extracts IF pulses from the other
/// channel and computes their FFT, following read_data_RTI.m.
/// Not thread-safe: use from one serial queue.
final class RadarProcessor {
    private(set) var params = RadarParams()
    private(set) var fs: Double = 48000
    private(set) var d: Derived
    var paused = false

    // sample history: bufL holds the trigger (sync) channel, bufR the IF channel
    private var bufL: UnsafeMutablePointer<Float>
    private var bufR: UnsafeMutablePointer<Float>
    private var cap: Int
    private var w = 0                       // write position
    private var scan = kernelHalf + 2       // next sample to test for an edge
    private var below = 0                   // consecutive samples below threshold
    private var abs0 = 0                    // absolute index of bufL[0]

    // triggers
    private var edgeHistory: [(i: Int, t: Double)] = []
    private var lastEdge: (i: Int, t: Double)?
    private var edgeIsNew = false

    // per-pulse state
    private var meanPulse: [Double] = []
    private var nMean = 0
    private var prevPulse: [Double]?
    private var avgPow: [Double] = []
    private var holdPow: [Double] = []
    private var pendingRows: [[Float]] = []
    private var pulseCount = 0
    private var generation = 0
    private var window: [Double] = []
    private var windowScale = 1.0
    private var fftSetup: FFTSetupD?
    private var fftLog2n = 0
    private var fftIn: [Double] = []
    private var splitRe: [Double] = []
    private var splitIm: [Double] = []
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var sqCount = 0
    private var sqSum = (trigger: 0.0, ifc: 0.0)
    private var sqMax = (trigger: Float(0), ifc: Float(0))
    private var squareness: (trigger: Double, ifc: Double)?
    private var pga: RangePGA?
    private var cplxRe: [Double] = []
    private var cplxIm: [Double] = []
    private var pencil: MatrixPencil?
    private var pencilTargets: [(range: Double, db: Double)] = []
    private var pencilOrder: Int?
    private var pencilMs: Double?
    // range-Doppler: ring of complex range profiles (bins 0 ..< nfft/2), newest at rdNewest
    private let rdCap = 256
    private var rdBins = 0
    private var rdRe: [Float] = []
    private var rdIm: [Float] = []
    private var rdNewest = 0
    private var rdCount = 0
    private var rdRangeWindow: [Double] = []
    private var rdRangeScale = 1.0
    private var rdBufRe: [Double] = []
    private var rdBufIm: [Double] = []
    private var rdDirty = false
    private var rdLastBuild: UInt64 = 0
    // fast-time samples of the same pulses (for matrix pencil in range), and whether they are analytic
    private var rdFastRe: [Float] = []
    private var rdFastIm: [Float] = []
    private var rdFastN = 0
    private var rdAnalytic = false
    // maps are built on their own queue
    private let rdQueue = DispatchQueue(label: "org.coffeecanradar.CoffeeCanRadar.rangedoppler", qos: .userInitiated)
    private let rdLock = NSLock()
    private var rdBusy = false
    private var rdLastMs = 0.0
    private var rdResult: (generation: Int, snapshot: RangeDopplerSnapshot)?

    init() {
        d = Derived(RadarParams(), fs: 48000)
        cap = 8 * 48000
        bufL = .allocate(capacity: cap)
        bufR = .allocate(capacity: cap)
        bufL.initialize(repeating: 0, count: cap)
        bufR.initialize(repeating: 0, count: cap)
        resetProcessing()
    }

    deinit {
        bufL.deallocate()
        bufR.deallocate()
        if let s = fftSetup { vDSP_destroy_fftsetupD(s) }
    }

    func update(params p: RadarParams, fs newFs: Double) {
        let old = (params: params, fs: fs, d: d)
        params = p
        fs = newFs
        d = Derived(p, fs: newFs)
        if newFs != old.fs {
            reallocate(capacity: Int(8 * newFs))
            resetBuffer()
        } else if p.syncOnRight != old.params.syncOnRight {
            resetBuffer()
        }
        // The display range (nBins) is only a crop, so changing it keeps the history.
        if newFs != old.fs || p.syncOnRight != old.params.syncOnRight || d.n != old.d.n || d.nfft != old.d.nfft
            || p.window != old.params.window || p.taylorNbar != old.params.taylorNbar
            || p.taylorSidelobeDB != old.params.taylorSidelobeDB || p.pgaEnabled != old.params.pgaEnabled
            || p.svaEnabled != old.params.svaEnabled || p.rangeMethod != old.params.rangeMethod
            || p.pencilL != old.params.pencilL || p.pencilDisplay != old.params.pencilDisplay {
            resetProcessing()
        } else if p.background != old.params.background {
            meanPulse = []; nMean = 0; prevPulse = nil
            pga = nil
        } else if p.pgaPulses != old.params.pgaPulses {
            pga = nil
        }
        if p.rdRangePGA != old.params.rdRangePGA { rdCount = 0 }
        rdDirty = true   // recolour / rebuild the range-Doppler map with the new settings
    }

    func resetPGA() { pga = nil }

    /// Audio was dropped: the next samples don't follow on, so re-acquire the trigger.
    func discontinuity() { resetBuffer() }

    /// Start over with an empty buffer and fresh averages (used when a source starts).
    func restart() {
        resetBuffer()
        resetProcessing()
    }

    func clearHold() {
        holdPow = avgPow
        generation += 1
        pendingRows.removeAll()
    }

    private func reallocate(capacity: Int) {
        bufL.deallocate(); bufR.deallocate()
        cap = max(capacity, 48000)
        bufL = .allocate(capacity: cap); bufR = .allocate(capacity: cap)
        bufL.initialize(repeating: 0, count: cap)
        bufR.initialize(repeating: 0, count: cap)
    }

    private func resetBuffer() {
        w = 0; scan = kernelHalf + 2; below = 0; abs0 = 0
        edgeHistory.removeAll(); lastEdge = nil; edgeIsNew = false
        peakL = 0; peakR = 0
        sqCount = 0; sqSum = (0, 0); sqMax = (0, 0); squareness = nil
    }

    private func resetProcessing() {
        meanPulse = []; nMean = 0; prevPulse = nil
        avgPow = []; holdPow = []; pendingRows = []
        pulseCount = 0
        generation += 1
        // SVA chooses its own weighting per bin, so it starts from unwindowed (rectangular) data.
        window = params.svaEnabled ? [Double](repeating: 1, count: d.n) : makeWindow(params, n: d.n)
        windowScale = 2 / window.reduce(0, +)     // sine of amplitude 1 -> 0 dBFS
        pga = nil
        pencil = nil; pencilTargets = []; pencilOrder = nil
        rdCount = 0; rdNewest = 0; rdRangeWindow = []
        cplxRe = [Double](repeating: 0, count: d.nfft)
        cplxIm = [Double](repeating: 0, count: d.nfft)
        if fftSetup == nil || fftLog2n != d.log2n {
            if let s = fftSetup { vDSP_destroy_fftsetupD(s) }
            fftSetup = vDSP_create_fftsetupD(vDSP_Length(d.log2n), FFTRadix(kFFTRadix2))
            fftLog2n = d.log2n
        }
        fftIn = [Double](repeating: 0, count: d.nfft)
        splitRe = [Double](repeating: 0, count: d.nfft / 2)
        splitIm = [Double](repeating: 0, count: d.nfft / 2)
    }

    // MARK: input

    func push(_ left: [Float], _ right: [Float]) {
        if paused { return }
        let (trig, ifc) = params.syncOnRight ? (right, left) : (left, right)
        let n = min(trig.count, ifc.count)
        guard n > 0 else { return }
        if w + n > cap {
            let keep = max(0, scan - d.n - 4 * kernelHalf - 64)
            if keep > 0 {
                memmove(bufL, bufL + keep, (w - keep) * MemoryLayout<Float>.size)
                memmove(bufR, bufR + keep, (w - keep) * MemoryLayout<Float>.size)
                w -= keep; scan -= keep; abs0 += keep
                if let e = lastEdge { lastEdge = e.i - keep >= 0 ? (e.i - keep, e.t - Double(keep)) : nil }
            }
            if w + n > cap {   // fell hopelessly behind: start over
                abs0 += w; w = 0; scan = kernelHalf + 2; below = 0; lastEdge = nil
            }
        }
        trig.withUnsafeBufferPointer { (bufL + w).update(from: $0.baseAddress!, count: n) }
        ifc.withUnsafeBufferPointer { (bufR + w).update(from: $0.baseAddress!, count: n) }
        var mx: Float = 0, ms: Float = 0
        vDSP_maxmgv(bufL + w, 1, &mx, vDSP_Length(n)); peakL = max(peakL, mx)
        vDSP_measqv(bufL + w, 1, &ms, vDSP_Length(n))
        sqMax.trigger = max(sqMax.trigger, mx); sqSum.trigger += Double(ms) * Double(n)
        vDSP_maxmgv(bufR + w, 1, &mx, vDSP_Length(n)); peakR = max(peakR, mx)
        vDSP_measqv(bufR + w, 1, &ms, vDSP_Length(n))
        sqMax.ifc = max(sqMax.ifc, mx); sqSum.ifc += Double(ms) * Double(n)
        sqCount += n
        if Double(sqCount) >= fs {
            let c = Double(sqCount)
            squareness = (sqMax.trigger > 0 ? sqrt(sqSum.trigger / c) / Double(sqMax.trigger) : 0,
                          sqMax.ifc > 0 ? sqrt(sqSum.ifc / c) / Double(sqMax.ifc) : 0)
            sqCount = 0; sqSum = (0, 0); sqMax = (0, 0)
        }
        w += n
        detectEdges()
    }

    // MARK: trigger

    private func detectEdges() {
        let sg: Float = params.invert ? -1 : 1
        let th = Float(params.threshold)
        let need = d.n + kernelHalf + 2
        while scan < w - need {
            let i = scan
            if sg * bufL[i] > th {
                // MATLAB: start(ii) == 1 & mean(start(ii-11:ii-1)) == 0
                if below >= params.holdoff && i >= kernelHalf + 2 { onEdge(i) }
                below = 0
            } else {
                below += 1
            }
            scan += 1
        }
    }

    private func onEdge(_ i: Int) {
        let sg: Double = params.invert ? -1 : 1
        let th = params.threshold
        let u = max(10, params.interpolation)

        // Upsample the rising edge between samples i-1 (below) and i (above) by u,
        // then refine linearly between the two upsampled points that straddle the threshold.
        var pt = Double(i - 1)
        var pv = sg * Double(bufL[i - 1])
        var tEdge = Double(i)
        for j in 1...u {
            let t = Double(i - 1) + Double(j) / Double(u)
            let v = j == u ? sg * Double(bufL[i]) : sg * interpolate(bufL, at: t)
            if v > th {
                tEdge = pt + (th - pv) / (v - pv) / Double(u)
                break
            }
            pt = t; pv = v
        }
        edgeHistory.append((abs0 + i, Double(abs0) + tEdge))
        if edgeHistory.count > 128 { edgeHistory.removeFirst(edgeHistory.count - 128) }
        lastEdge = (i, tEdge)
        edgeIsNew = true

        // Extract the IF pulse s(t0 ... t0+N-1).
        let n = d.n
        var pulse = [Double](repeating: 0, count: n)
        let t0 = params.align ? tEdge : Double(i)
        let n0 = Int(floor(t0))
        let f = t0 - Double(n0)
        if f == 0 {
            for k in 0..<n { pulse[k] = sg * Double(bufR[n0 + k]) }
        } else {
            let taps = (0..<(2 * kernelHalf)).map { sincKernel(f - Double($0 - kernelHalf + 1)) }
            for k in 0..<n {
                let base = bufR + (n0 + k - kernelHalf + 1)
                var s = 0.0
                for m in 0..<(2 * kernelHalf) { s += Double(base[m]) * taps[m] }
                pulse[k] = sg * s
            }
        }
        processPulse(pulse)
    }

    // MARK: per pulse

    private func processPulse(_ pulse: [Double]) {
        let n = d.n
        var x = pulse
        switch params.background {
        case .mean:
            // running mean: cumulative until meanLength pulses, then exponential
            if meanPulse.count != n { meanPulse = [Double](repeating: 0, count: n); nMean = 0 }
            nMean = min(nMean + 1, max(1, params.meanLength))
            let a = 1 / Double(nMean)
            for k in 0..<n {
                meanPulse[k] += a * (pulse[k] - meanPulse[k])
                x[k] = pulse[k] - meanPulse[k]
            }
            prevPulse = pulse
        case .none:
            prevPulse = pulse
        case .twoPulse:
            guard let prev = prevPulse, prev.count == n else { prevPulse = pulse; return }
            for k in 0..<n { x[k] = pulse[k] - prev[k] }
            prevPulse = pulse
        }

        guard let setup = fftSetup else { return }
        let nfft = d.nfft
        let nb = nfft / 2
        var pow = [Double](repeating: 0, count: nb)

        // Range PGA runs when the range profile uses it or the range-Doppler map does.
        let rdPGA = params.rdEnabled && params.rdRangePGA
        var corrected: (re: [Double], im: [Double])?
        if params.pgaEnabled || rdPGA {
            if pga == nil || pga!.n != n { pga = RangePGA(n: n) }
            let p = pga!
            var a = p.analytic(x)
            let mPerBin = d.metersPerBin * Double(nfft) / Double(p.m)   // range per bin of the PGA grid
            let lo = Int(ceil(params.pgaMinRange / mPerBin))
            let hi = max(lo + 1, Int(d.rShow / mPerBin))
            p.add(a, blockSize: max(4, params.pgaPulses), iterations: params.pgaIterations, bins: lo...hi,
                  minAgreement: params.pgaMinAgreement)
            p.correct(&a)
            corrected = a
        }
        if rdPGA, let a = corrected { recordDoppler(re: a.re, im: a.im) } else { recordDoppler(re: x, im: nil) }

        if params.pgaEnabled, let a = corrected {
            // Complex path: analytic signal -> PGA phase correction -> window -> FFT.
            if params.rangeMethod == .matrixPencil {
                pencilProfile(re: a.re, im: a.im, real: false, into: &pow)
                accumulate(pow)
                return
            }
            if params.svaEnabled {
                let y = svaSpectrum(setup: setup, re: a.re, im: a.im, n: n, log2n: d.log2n)
                let s2 = windowScale * windowScale / 4
                for k in 0..<nb { pow[k] = (y.re[k] * y.re[k] + y.im[k] * y.im[k]) * s2 }
                accumulate(pow)
                return
            }
            for k in 0..<nfft {
                cplxRe[k] = k < n ? a.re[k] * window[k] : 0
                cplxIm[k] = k < n ? a.im[k] * window[k] : 0
            }
            fftInPlace(setup, &cplxRe, &cplxIm, log2n: d.log2n)
            // analytic sine of amplitude A peaks at A * sum(w): same 0 dBFS reference as below
            let s2 = windowScale * windowScale / 4
            for k in 0..<nb { pow[k] = (cplxRe[k] * cplxRe[k] + cplxIm[k] * cplxIm[k]) * s2 }
            accumulate(pow)
            return
        }

        if params.rangeMethod == .matrixPencil {
            pencilProfile(re: x, im: [Double](repeating: 0, count: n), real: true, into: &pow)
            accumulate(pow)
            return
        }

        if params.svaEnabled {
            // Real input through a complex FFT: a sine of amplitude A peaks at A*N/2.
            let y = svaSpectrum(setup: setup, re: x, im: [Double](repeating: 0, count: n), n: n, log2n: d.log2n)
            let s2 = windowScale * windowScale
            for k in 0..<nb { pow[k] = (y.re[k] * y.re[k] + y.im[k] * y.im[k]) * s2 }
            accumulate(pow)
            return
        }

        for k in 0..<nfft { fftIn[k] = k < n ? x[k] * window[k] : 0 }
        splitRe.withUnsafeMutableBufferPointer { rp in
            splitIm.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                fftIn.withUnsafeBufferPointer { inp in
                    inp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: nfft / 2) {
                        vDSP_ctozD($0, 2, &sc, 1, vDSP_Length(nfft / 2))
                    }
                }
                vDSP_fft_zripD(setup, &sc, 1, vDSP_Length(d.log2n), FFTDirection(FFT_FORWARD))
            }
        }

        // vDSP's real FFT output is 2x the DFT; bin 0 packs DC (real) and Nyquist (imag).
        let s2 = windowScale * windowScale / 4
        pow[0] = splitRe[0] * splitRe[0] * s2
        for k in 1..<nb { pow[k] = (splitRe[k] * splitRe[k] + splitIm[k] * splitIm[k]) * s2 }
        accumulate(pow)
    }

    /// Matrix pencil range profile for one pulse: pseudospectrum or amplitude-weighted lines
    /// on the FFT range grid, scaled to dBFS like the FFT.
    private func pencilProfile(re: [Double], im: [Double], real: Bool, into pow: inout [Double]) {
        let n = d.n, nfft = d.nfft
        let lp = params.pencilL > 0 ? params.pencilL : n / 3
        if pencil == nil || pencil!.n != n || pencil!.l != max(2, min(lp, n - 2)) { pencil = MatrixPencil(n: n, pencil: lp) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let targets = max(1, params.pencilMaxTargets)
        guard let r = pencil!.analyze(re: re, im: im, maxOrder: real ? 2 * targets : targets,
                                      thresholdDB: params.pencilThresholdDB, rule: params.pencilOrderRule,
                                      pairs: real, esterThreshold: params.esterThreshold,
                                      forwardBackward: params.pencilForwardBackward) else {
            for k in pow.indices { pow[k] = 0 }
            return
        }
        // A real sine of amplitude A is a conjugate pair of amplitude A/2: power 4|a|^2 = A^2.
        let scale = real ? 4.0 : 1.0
        var found: [(range: Double, db: Double, k: Int)] = []
        for k in 0..<r.order {
            let ang = r.poles[k].arg
            guard ang > 0 else { continue }
            let range = ang / (2 * .pi) * Double(nfft) * d.metersPerBin
            found.append((range, 10 * log10(r.power[k] * scale + 1e-20), k))
        }
        let eps = 2 * Double.pi / Double(nfft) * max(0.1, params.pencilPeakWidth)
        let eps2 = eps * eps
        let omegas = (0..<pow.count).map { 2 * Double.pi * Double($0) / Double(nfft) }
        switch params.pencilDisplay {
        case .pseudospectrum:
            let top = (found.map { r.power[$0.k] }.max() ?? 0) * scale
            let s2 = MatrixPencil.sigmaMin2(schur: r.schur, order: r.order, omegas: omegas)
            for k in pow.indices { pow[k] = top * eps2 / (s2[k] + eps2) }
        case .amplitudeWeighted:
            for k in pow.indices { pow[k] = 0 }
            for f in found {
                let p = r.poles[f.k], u = Cx(p.re / p.mag, p.im / p.mag), pk = r.power[f.k] * scale
                for b in pow.indices {
                    let dz = Cx(cos(omegas[b]), sin(omegas[b])) - u
                    pow[b] += pk * eps2 / (dz.abs2 + eps2)
                }
            }
        }
        pencilTargets = found.map { ($0.range, $0.db) }
        pencilOrder = r.order
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        pencilMs = pencilMs.map { 0.9 * $0 + 0.1 * ms } ?? ms
    }

    // MARK: range-Doppler

    /// Stores this pulse's complex range profile (windowed FFT, amplitude in dBFS units) for
    /// the Doppler FFT. `im` is nil for the real IF and the analytic signal's imaginary part with PGA.
    private func recordDoppler(re: [Double], im: [Double]?) {
        guard params.rdEnabled, let setup = fftSetup else { return }
        let n = d.n, nfft = d.nfft, nb = nfft / 2
        if rdBins != nb || rdRe.count != rdCap * nb || rdFastN != n || rdAnalytic != (im != nil) {
            rdBins = nb
            rdRe = [Float](repeating: 0, count: rdCap * nb)
            rdIm = rdRe
            rdFastN = n
            rdAnalytic = im != nil
            rdFastRe = [Float](repeating: 0, count: rdCap * n)
            rdFastIm = rdFastRe
            rdCount = 0; rdNewest = 0
        }
        if rdRangeWindow.count != n {
            // The range window is the one chosen in Processing, even with SVA or the matrix pencil.
            rdRangeWindow = makeWindow(params, n: n)
            rdRangeScale = 2 / rdRangeWindow.reduce(0, +)
            rdBufRe = [Double](repeating: 0, count: nfft)
            rdBufIm = rdBufRe
        }
        for k in 0..<nfft {
            rdBufRe[k] = k < n ? re[k] * rdRangeWindow[k] : 0
            rdBufIm[k] = k < n ? (im?[k] ?? 0) * rdRangeWindow[k] : 0
        }
        fftInPlace(setup, &rdBufRe, &rdBufIm, log2n: d.log2n)
        // a real sine of amplitude A peaks at A*sum(w)/2; its analytic signal at A*sum(w)
        let g = im == nil ? rdRangeScale : rdRangeScale / 2
        rdNewest = (rdNewest + 1) % rdCap
        let base = rdNewest * nb
        for k in 0..<nb {
            rdRe[base + k] = Float(rdBufRe[k] * g)
            rdIm[base + k] = Float(rdBufIm[k] * g)
        }
        let fb = rdNewest * n
        for t in 0..<n {
            rdFastRe[fb + t] = Float(re[t])
            rdFastIm[fb + t] = Float(im?[t] ?? 0)
        }
        rdCount = min(rdCount + 1, rdCap)
        rdDirty = true
    }

    /// Starts a new range-Doppler map on its own queue (at most 10 a second, never two at once)
    /// and returns the last finished one, if it hasn't been handed out yet.
    private func buildRangeDoppler() -> RangeDopplerSnapshot? {
        rdLock.lock()
        let done = rdResult, busy = rdBusy
        rdResult = nil
        rdLock.unlock()
        let finished = done?.generation == generation ? done?.snapshot : nil
        if let f = finished { rdLastMs = f.ms }
        let now = DispatchTime.now().uptimeNanoseconds
        let log2m = max(3, min(Int(log2(Double(max(8, params.rdPulses)))), Int(log2(Double(rdCap)))))
        let m = 1 << log2m
        // at most 10 maps a second, and at most half a core when the pencil makes maps slow
        let interval = UInt64(max(100, 2 * rdLastMs) * 1e6)
        guard params.rdEnabled, rdDirty, !busy, now - rdLastBuild >= interval, rdCount >= m, rdBins > 0,
              rdFastN == d.n else { return finished }
        rdDirty = false
        rdLastBuild = now
        let nr = min(d.nBins, rdBins), n = d.n
        // slow-time block [range bin][pulse] and fast-time block [pulse][sample], oldest pulse first
        var input = RangeDopplerInput(m: m, log2m: log2m, nr: nr, n: n, nfft: d.nfft, metersPerBin: d.metersPerBin,
                                      params: params, analytic: rdAnalytic, generation: generation)
        input.bre = [Double](repeating: 0, count: m * nr); input.bim = input.bre
        let needFast = params.rdSuperRes == .range || params.rdSuperRes == .both
        if needFast { input.fre = [Double](repeating: 0, count: m * n); input.fim = input.fre }
        for j in 0..<m {
            let slot = ((rdNewest - (m - 1) + j) % rdCap + rdCap) % rdCap
            let src = slot * rdBins
            for kb in 0..<nr {
                input.bre[kb * m + j] = Double(rdRe[src + kb])
                input.bim[kb * m + j] = Double(rdIm[src + kb])
            }
            if needFast {
                for t in 0..<n {
                    input.fre[j * n + t] = Double(rdFastRe[slot * n + t])
                    input.fim[j * n + t] = Double(rdFastIm[slot * n + t])
                }
            }
        }
        rdLock.lock(); rdBusy = true; rdLock.unlock()
        rdQueue.async { [weak self] in
            let snap = RangeDopplerBuilder.compute(input)
            guard let self else { return }
            self.rdLock.lock()
            self.rdResult = snap.map { (input.generation, $0) }
            self.rdBusy = false
            self.rdLock.unlock()
        }
        return finished
    }

    /// Phase gradient autofocus along slow time (Jakowatz/Eichel). Estimates the phase error that every
    /// range bin shares from pulse to pulse (oscillator phase noise, vibration of the radar) and removes it
    /// from the block in place. re/im hold [range bin][pulse] with `m` pulses per bin. Each range bin's
    /// strongest Doppler cell is shifted to zero Doppler (so a target's own velocity is not an error), the
    /// cells around it are windowed, and the pulse-to-pulse phase differences are summed over range bins.
    /// Returns the total correction (rad, linear trend removed).
    static func slowTimePGA(setup: FFTSetupD, re: inout [Double], im: inout [Double], m: Int, log2m: Int,
                             bins: Range<Int>, iterations: Int) -> [Double] {
        var total = [Double](repeating: 0, count: m)
        guard bins.count > 0, m >= 8 else { return total }
        // use range bins within 20 dB of the strongest
        let energy = bins.map { kb in (0..<m).reduce(0.0) { $0 + re[kb * m + $1] * re[kb * m + $1] + im[kb * m + $1] * im[kb * m + $1] } }
        guard let emax = energy.max(), emax > 0 else { return total }
        let use = zip(bins, energy).filter { $0.1 >= emax * 0.01 }.map(\.0)
        var cr = [[Double]](repeating: [Double](repeating: 0, count: m), count: use.count), ci = cr
        var gr = [Double](repeating: 0, count: m), gi = gr
        for _ in 0..<iterations {
            // centre each bin's strongest Doppler cell
            var avg = [Double](repeating: 0, count: m)
            for (u, kb) in use.enumerated() {
                for j in 0..<m { gr[j] = re[kb * m + j]; gi[j] = im[kb * m + j] }
                fftInPlace(setup, &gr, &gi, log2n: log2m)
                var q0 = 0, best = -1.0
                for q in 0..<m { let p = gr[q] * gr[q] + gi[q] * gi[q]; if p > best { best = p; q0 = q } }
                for q in 0..<m {
                    let s = (q + q0) % m
                    cr[u][q] = gr[s]; ci[u][q] = gi[s]
                    avg[q] += gr[s] * gr[s] + gi[s] * gi[s]
                }
            }
            // window: 1.5x the extent where the average centred spectrum is within 10 dB of its peak
            var ext = 0
            while ext < m / 2 - 1 && (avg[(ext + 1) % m] > 0.1 * avg[0] || avg[(m - ext - 1) % m] > 0.1 * avg[0]) { ext += 1 }
            let half = min(m / 2, max(1, Int((1.5 * Double(ext + 1)).rounded(.up))))
            // phase gradient summed over range bins
            var sr = [Double](repeating: 0, count: m), si = sr
            for u in use.indices {
                for q in 0..<m {
                    let signed = q <= m / 2 ? q : q - m
                    let keep = abs(signed) <= half
                    gr[q] = keep ? cr[u][q] : 0; gi[q] = keep ? ci[u][q] : 0
                }
                fftInPlace(setup, &gr, &gi, log2n: log2m, inverse: true)
                for j in 1..<m {   // conj(h[j-1]) * h[j]
                    sr[j] += gr[j - 1] * gr[j] + gi[j - 1] * gi[j]
                    si[j] += gr[j - 1] * gi[j] - gi[j - 1] * gr[j]
                }
            }
            var phi = [Double](repeating: 0, count: m)
            for j in 1..<m { phi[j] = phi[j - 1] + atan2(si[j], sr[j]) }
            removeLinearTrend(&phi)
            for j in 0..<m {
                total[j] += phi[j]
                let c = cos(phi[j]), sn = -sin(phi[j])
                for kb in 0..<(re.count / m) {
                    let i = kb * m + j
                    let a = re[i], b = im[i]
                    re[i] = a * c - b * sn; im[i] = a * sn + b * c
                }
            }
            if rms(phi) < 0.01 { break }
        }
        removeLinearTrend(&total)
        return total
    }

    /// Trace averaging, peak hold and RTI rows for one pulse's power spectrum.
    private func accumulate(_ pow: [Double]) {
        let nb = pow.count
        if avgPow.count != nb {
            avgPow = pow; holdPow = pow
        } else {
            let a = 1 / Double(max(1, params.traceAveraging))
            for k in 0..<nb {
                avgPow[k] += a * (pow[k] - avgPow[k])
                if avgPow[k] > holdPow[k] { holdPow[k] = avgPow[k] }
            }
        }
        pendingRows.append(pow.map { Float(10 * log10($0 + 1e-20)) })
        if pendingRows.count > 256 { pendingRows.removeFirst(pendingRows.count - 256) }
        pulseCount += 1
    }

    // MARK: output

    func takeSnapshot() -> ProcessorSnapshot {
        var s = ProcessorSnapshot(derived: d, generation: generation, pulseCount: pulseCount)
        if !avgPow.isEmpty {
            s.traceDB = avgPow.map { Float(10 * log10($0 + 1e-20)) }
            if params.peakHold { s.holdDB = holdPow.map { Float(10 * log10($0 + 1e-20)) } }
        }
        s.newRows = pendingRows
        pendingRows.removeAll(keepingCapacity: true)

        if edgeIsNew, let e = lastEdge {
            edgeIsNew = false
            s.scope = makeScope(e.i)
            s.edge = makeEdge(e.i, e.t)
        }

        if edgeHistory.count > 4 {
            var di: [Double] = [], dt: [Double] = []
            for k in 1..<edgeHistory.count {
                di.append(Double(edgeHistory[k].i - edgeHistory[k - 1].i))
                dt.append(edgeHistory[k].t - edgeHistory[k - 1].t)
            }
            let mean = dt.reduce(0, +) / Double(dt.count)
            s.pulseRateHz = fs / mean
            s.periodMs = mean / fs * 1e3
            s.jitterIntegerUs = stdDev(di) / fs * 1e6
            s.jitterInterpUs = stdDev(dt) / fs * 1e6
        }
        // peaks are reported for the physical inputs
        (s.peakL, s.peakR) = params.syncOnRight ? (peakR, peakL) : (peakL, peakR)
        peakL = 0; peakR = 0
        s.squarenessTrigger = squareness?.trigger
        s.squarenessIF = squareness?.ifc
        if params.rangeMethod == .matrixPencil {
            s.pencilTargets = pencilTargets
            s.pencilOrder = pencilOrder
            s.pencilMs = pencilMs
        }
        if params.rdEnabled {
            s.rangeDoppler = buildRangeDoppler()
            s.rdCollected = rdCount
        }
        if params.pgaEnabled || (params.rdEnabled && params.rdRangePGA), let p = pga {
            s.pgaPhase = p.phase?.map { Float($0) }
            s.pgaUpdates = p.updates
            s.pgaAccepted = p.accepted
            s.pgaAgreement = p.updates > 0 ? p.lastAgreement : nil
            s.pgaResidualRMS = p.updates > 0 ? p.lastResidualRMS : nil
        }
        return s
    }

    private func makeScope(_ i: Int) -> ScopeSnapshot? {
        let sg: Float = params.invert ? -1 : 1
        let pre = Int(Double(d.n) * 0.15)
        let a = max(0, i - pre), b = min(w, i + d.n + kernelHalf)
        guard b > a else { return nil }
        let left = (a..<b).map { sg * bufL[$0] }
        let right = (a..<b).map { sg * bufR[$0] }
        return ScopeSnapshot(left: left, right: right, pre: i - a, fs: fs, n: d.n)
    }

    private func makeEdge(_ i: Int, _ t: Double) -> EdgeSnapshot? {
        let span = 4
        guard i - span - kernelHalf >= 0, i + span + kernelHalf < w else { return nil }
        let sg: Double = params.invert ? -1 : 1
        let u = max(10, params.interpolation)
        let samples = (-span...span).map { Float(sg * Double(bufL[i + $0])) }
        let fine = (0...(2 * span * u)).map { j in
            Float(sg * interpolate(bufL, at: Double(i - span) + Double(j) / Double(u)))
        }
        return EdgeSnapshot(samples: samples, fine: fine, upsample: u, edgeOffset: t - Double(i),
                            threshold: params.threshold, span: span)
    }
}

func stdDev(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return 0 }
    let m = a.reduce(0, +) / Double(a.count)
    return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count))
}
