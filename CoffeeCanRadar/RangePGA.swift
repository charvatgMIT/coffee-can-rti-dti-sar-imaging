import Accelerate
import Foundation

/// In-place complex FFT of length 2^log2n with vDSP. The inverse is unscaled.
func fftInPlace(_ setup: FFTSetupD, _ re: inout [Double], _ im: inout [Double], log2n: Int, inverse: Bool = false) {
    re.withUnsafeMutableBufferPointer { rp in
        im.withUnsafeMutableBufferPointer { ip in
            var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zipD(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
        }
    }
}

/// Removes the least-squares line a + b*t (a range shift and a constant phase are not errors).
func removeLinearTrend(_ x: inout [Double]) {
    let n = Double(x.count)
    guard n > 1 else { return }
    let tMean = (n - 1) / 2
    let xMean = x.reduce(0, +) / n
    var num = 0.0, den = 0.0
    for (t, v) in x.enumerated() { num += (Double(t) - tMean) * (v - xMean); den += (Double(t) - tMean) * (Double(t) - tMean) }
    let b = num / den
    for t in x.indices { x[t] -= xMean + b * (Double(t) - tMean) }
}

func rms(_ x: [Double]) -> Double {
    x.isEmpty ? 0 : sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(x.count))
}

/// Phase gradient autofocus along fast time (range).
///
/// Every FMCW sweep shares the same phase error across its N samples (mostly VCO tuning
/// nonlinearity), which smears targets in range. PGA estimates it from a block of recent
/// pulses: for each pulse, centre the strongest return in the range profile, window it,
/// transform back to fast time, and average the sample-to-sample phase difference over
/// pulses. The integrated, detrended gradient is the phase error; iterating with a
/// shrinking window refines it.
final class RangePGA {
    let n: Int
    let log2m: Int
    let m: Int
    private let setup: FFTSetupD
    private var block: [(re: [Double], im: [Double])] = []
    private var sinceUpdate = 0
    private(set) var phase: [Double]?     // current estimate (rad), length n
    private(set) var updates = 0
    private(set) var lastResidualRMS = 0.0

    init(n: Int) {
        self.n = n
        log2m = Int(ceil(log2(Double(n))))
        m = 1 << log2m
        setup = vDSP_create_fftsetupD(vDSP_Length(log2m), FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// Analytic signal of a real pulse (negative frequencies removed).
    func analytic(_ x: [Double]) -> (re: [Double], im: [Double]) {
        var re = [Double](repeating: 0, count: m), im = [Double](repeating: 0, count: m)
        for k in 0..<min(n, x.count) { re[k] = x[k] }
        fftInPlace(setup, &re, &im, log2n: log2m)
        for k in 1..<(m / 2) { re[k] *= 2; im[k] *= 2 }
        for k in (m / 2 + 1)..<m { re[k] = 0; im[k] = 0 }
        fftInPlace(setup, &re, &im, log2n: log2m, inverse: true)
        let s = 1 / Double(m)
        return (Array(re[0..<n]).map { $0 * s }, Array(im[0..<n]).map { $0 * s })
    }

    /// Adds an (uncorrected) analytic pulse; re-estimates every quarter block once the block is full.
    ///
    /// The two halves of the block are estimated independently. A real sweep error is common
    /// to every pulse, so both halves find the same curve; noise or clutter gives unrelated
    /// curves. An estimate is kept only if the halves agree (correlation >= minAgreement)
    /// and it makes the block's range profiles sharper.
    func add(_ a: (re: [Double], im: [Double]), blockSize: Int, iterations: Int, bins: ClosedRange<Int>,
             minAgreement: Double) {
        block.append(a)
        if block.count > blockSize { block.removeFirst(block.count - blockSize) }
        sinceUpdate += 1
        guard block.count == blockSize, sinceUpdate >= max(4, blockSize / 4) else { return }
        sinceUpdate = 0
        let r = clampBins(bins)
        let half = block.count / 2
        let estA = estimate(Array(block[..<half]), iterations: iterations, bins: r)
        let estB = estimate(Array(block[half...]), iterations: iterations, bins: r)
        lastAgreement = correlation(estA, estB)
        let est = zip(estA, estB).map { 0.5 * ($0 + $1) }
        let candidate = phase.map { old in zip(old, est).map { 0.5 * ($0 + $1) } } ?? est   // smooth successive estimates
        updates += 1
        if lastAgreement >= minAgreement && sharpness(candidate, of: block, bins: r) > sharpness(phase, of: block, bins: r) * 1.001 {
            phase = candidate
            accepted += 1
        }
    }

    private(set) var accepted = 0
    private(set) var lastAgreement = 0.0

    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var ab = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { ab += (x - ma) * (y - mb); aa += (x - ma) * (x - ma); bb += (y - mb) * (y - mb) }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    private func clampBins(_ bins: ClosedRange<Int>) -> ClosedRange<Int> {
        let lo = max(1, min(bins.lowerBound, m / 2 - 2))
        return lo...max(lo + 1, min(bins.upperBound, m / 2 - 1))
    }

    /// Mean over `pulses` of sum|X|^4 / (sum|X|^2)^2 within `bins`: larger means more focused.
    private func sharpness(_ phi: [Double]?, of pulses: [(re: [Double], im: [Double])], bins: ClosedRange<Int>) -> Double {
        var re = [Double](repeating: 0, count: m), im = re
        var total = 0.0
        for pulse in pulses {
            for k in 0..<m { re[k] = 0; im[k] = 0 }
            for t in 0..<n {
                if let phi {
                    let c = cos(phi[t]), s = sin(phi[t])
                    re[t] = pulse.re[t] * c + pulse.im[t] * s
                    im[t] = pulse.im[t] * c - pulse.re[t] * s
                } else {
                    re[t] = pulse.re[t]; im[t] = pulse.im[t]
                }
            }
            fftInPlace(setup, &re, &im, log2n: log2m)
            var s2 = 0.0, s4 = 0.0
            for k in bins { let p = re[k] * re[k] + im[k] * im[k]; s2 += p; s4 += p * p }
            total += s2 > 0 ? s4 / (s2 * s2) : 0
        }
        return total / Double(max(1, pulses.count))
    }

    /// Multiplies a pulse by exp(-j * phase).
    func correct(_ a: inout (re: [Double], im: [Double])) {
        guard let phi = phase, phi.count == a.re.count else { return }
        for t in 0..<phi.count {
            let c = cos(phi[t]), s = sin(phi[t])
            let r = a.re[t], i = a.im[t]
            a.re[t] = r * c + i * s
            a.im[t] = i * c - r * s
        }
    }

    func estimate(_ pulses: [(re: [Double], im: [Double])], iterations: Int, bins: ClosedRange<Int>) -> [Double] {
        var g = pulses
        var phi = [Double](repeating: 0, count: n)
        var width = m / 4
        var re = [Double](repeating: 0, count: m), im = re
        var sr = re, si = re
        let lo = bins.lowerBound, hi = bins.upperBound
        for _ in 0..<max(1, iterations) {
            var accRe = [Double](repeating: 0, count: n), accIm = accRe
            for pulse in g {
                for k in 0..<m { re[k] = k < n ? pulse.re[k] : 0; im[k] = k < n ? pulse.im[k] : 0 }
                fftInPlace(setup, &re, &im, log2n: log2m)
                // keep only the selected range span (drops DC / feed-through near 0 m)
                for k in 0..<m where k < lo || k > hi { re[k] = 0; im[k] = 0 }
                var kp = lo, best = -1.0
                for k in lo...hi {
                    let p = re[k] * re[k] + im[k] * im[k]
                    if p > best { best = p; kp = k }
                }
                // circularly shift the strongest return to bin 0 and keep a window around it
                for k in 0..<m { sr[k] = 0; si[k] = 0 }
                let half = width / 2
                for dk in -half...half {
                    let src = (kp + dk + m) % m, dst = (dk + m) % m
                    sr[dst] = re[src]; si[dst] = im[src]
                }
                fftInPlace(setup, &sr, &si, log2n: log2m, inverse: true)
                for t in 1..<n {   // h(t) * conj(h(t-1))
                    accRe[t] += sr[t] * sr[t - 1] + si[t] * si[t - 1]
                    accIm[t] += si[t] * sr[t - 1] - sr[t] * si[t - 1]
                }
            }
            var residual = [Double](repeating: 0, count: n)
            for t in 1..<n { residual[t] = residual[t - 1] + atan2(accIm[t], accRe[t]) }
            removeLinearTrend(&residual)
            for t in 0..<n { phi[t] += residual[t] }
            for j in g.indices {
                for t in 0..<n {
                    let c = cos(residual[t]), s = sin(residual[t])
                    let r = g[j].re[t], i = g[j].im[t]
                    g[j].re[t] = r * c + i * s
                    g[j].im[t] = i * c - r * s
                }
            }
            width = max(16, Int(Double(width) * 0.6))
            lastResidualRMS = rms(residual)
            if lastResidualRMS < 0.005 { break }
        }
        return phi
    }
}
