import Accelerate
import CoreGraphics
import Foundation

/// Builds range-Doppler maps: Doppler PGA, then an FFT or matrix pencil (super-resolution) map.
/// Runs on its own queue, so it has its own FFT setup.
enum RangeDopplerBuilder {
    /// Doppler rows per FFT cell when the pencil runs in Doppler (the pseudospectrum is drawn finer).
    static let dopplerUpsample = 4
    private static let maxLog2 = 8
    private static let setup = vDSP_create_fftsetupD(vDSP_Length(maxLog2), FFTRadix(kFFTRadix2))!

    static func compute(_ inp: RangeDopplerInput) -> RangeDopplerSnapshot? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let p = inp.params, m = inp.m, nr = inp.nr, n = inp.n
        guard inp.log2m <= maxLog2, nr > 0 else { return nil }
        var bre = inp.bre, bim = inp.bim
        var fre = inp.fre, fim = inp.fim

        // Doppler PGA: estimated on the range profiles, applied to the fast-time samples as well
        var slowPhase: [Double]?
        if p.rdDopplerPGA {
            let first = min(nr, max(1, Int(ceil(p.pgaMinRange / inp.metersPerBin))))
            let phi = RadarProcessor.slowTimePGA(setup: setup, re: &bre, im: &bim, m: m, log2m: inp.log2m,
                                                 bins: first..<nr, iterations: max(1, p.pgaIterations))
            slowPhase = phi
            if !fre.isEmpty {
                for j in 0..<m {
                    let c = cos(phi[j]), s = -sin(phi[j])
                    for t in 0..<n {
                        let i = j * n + t, a = fre[i], b = fim[i]
                        fre[i] = a * c - b * s; fim[i] = a * s + b * c
                    }
                }
            }
        }

        var wp = p
        wp.window = p.rdWindow
        let wd = makeWindow(wp, n: m)
        let gd = 1 / wd.reduce(0, +)          // a steady tone keeps its range-profile level
        let floorDB = Float(p.dbTop - p.rdDbRange - 10)   // cells below this aren't worth a pencil

        // Row r of an m-row map holds slow-time frequency q = r - m/2. The phase 4*pi*R/lambda falls
        // as a target approaches, so negative q (top rows) is approaching.
        func fftMap() -> [Float] {
            var db = [Float](repeating: -400, count: m * nr)
            var re = [Double](repeating: 0, count: m), im = re
            for kb in 0..<nr {
                for j in 0..<m {
                    re[j] = bre[kb * m + j] * wd[j] * gd
                    im[j] = bim[kb * m + j] * wd[j] * gd
                }
                fftInPlace(setup, &re, &im, log2n: inp.log2m)
                for r in 0..<m {
                    let q = (r - m / 2 + m) % m
                    db[r * nr + kb] = Float(10 * log10(re[q] * re[q] + im[q] * im[q] + 1e-20))
                }
            }
            return db
        }

        /// Matrix pencil along slow time for every range bin: pseudospectrum on `u` rows per Doppler cell.
        func dopplerPencil(u: Int) -> [Float] {
            let rows = m * u
            var db = [Float](repeating: -400, count: rows * nr)
            let mp = MatrixPencil(n: m, pencil: m / 3)
            let energy = (0..<nr).map { kb in (0..<m).reduce(0.0) { $0 + bre[kb * m + $1] * bre[kb * m + $1] + bim[kb * m + $1] * bim[kb * m + $1] } / Double(m) }
            let omegas = (0..<rows).map { 2 * Double.pi * Double($0 - rows / 2) / Double(rows) }
            let eps = 2 * Double.pi / Double(rows) * max(0.1, p.pencilPeakWidth), eps2 = eps * eps
            for kb in 0..<nr where Float(10 * log10(energy[kb] + 1e-20)) > floorDB {
                let re = Array(bre[(kb * m)..<(kb * m + m)]), im = Array(bim[(kb * m)..<(kb * m + m)])
                guard let r = mp.analyze(re: re, im: im, maxOrder: max(1, p.pencilMaxTargets), thresholdDB: p.pencilThresholdDB,
                                         rule: p.pencilOrderRule, pairs: false, esterThreshold: p.esterThreshold,
                                         forwardBackward: p.pencilForwardBackward), r.order > 0 else { continue }
                let top = r.power.prefix(r.order).max() ?? 0
                let s2 = MatrixPencil.sigmaMin2(schur: r.schur, order: r.order, omegas: omegas)
                for row in 0..<rows { db[row * nr + kb] = Float(10 * log10(top * eps2 / (s2[row] + eps2) + 1e-20)) }
            }
            return db
        }

        /// Matrix pencil along fast time for every Doppler FFT cell: range pseudospectrum on the FFT range grid.
        func rangePencil() -> [Float] {
            var db = [Float](repeating: -400, count: m * nr)
            guard fre.count == m * n else { return db }
            // Doppler-filter every fast-time sample: y[q][t]
            var yre = [Double](repeating: 0, count: m * n), yim = yre
            var re = [Double](repeating: 0, count: m), im = re
            for t in 0..<n {
                for j in 0..<m { re[j] = fre[j * n + t] * wd[j] * gd; im[j] = fim[j * n + t] * wd[j] * gd }
                fftInPlace(setup, &re, &im, log2n: inp.log2m)
                for q in 0..<m { yre[q * n + t] = re[q]; yim[q * n + t] = im[q] }
            }
            let mp = MatrixPencil(n: n, pencil: n / 3)
            // a real IF has both +range and -range components, so allow twice the order
            let cap = max(1, p.pencilMaxTargets) * (inp.analytic ? 1 : 2)
            let scale = inp.analytic ? 1.0 : 4.0     // a real sine of amplitude A: component A/2
            let omegas = (0..<nr).map { 2 * Double.pi * Double($0) / Double(inp.nfft) }
            let eps = 2 * Double.pi / Double(inp.nfft) * max(0.1, p.pencilPeakWidth), eps2 = eps * eps
            for row in 0..<m {
                let q = (row - m / 2 + m) % m
                let re = Array(yre[(q * n)..<(q * n + n)]), im = Array(yim[(q * n)..<(q * n + n)])
                let e = zip(re, im).reduce(0.0) { $0 + $1.0 * $1.0 + $1.1 * $1.1 } / Double(n) * scale
                guard Float(10 * log10(e + 1e-20)) > floorDB,
                      let r = mp.analyze(re: re, im: im, maxOrder: cap, thresholdDB: p.pencilThresholdDB,
                                         rule: p.pencilOrderRule, pairs: false, esterThreshold: p.esterThreshold,
                                         forwardBackward: p.pencilForwardBackward), r.order > 0 else { continue }
                let top = (0..<r.order).filter { r.poles[$0].arg > 0 }.map { r.power[$0] }.max().map { $0 * scale } ?? 0
                guard top > 0 else { continue }
                let s2 = MatrixPencil.sigmaMin2(schur: r.schur, order: r.order, omegas: omegas)
                for kb in 0..<nr { db[row * nr + kb] = Float(10 * log10(top * eps2 / (s2[kb] + eps2) + 1e-20)) }
            }
            return db
        }

        var db: [Float]
        var u = 1
        switch p.rdSuperRes {
        case .off:
            db = fftMap()
        case .doppler:
            u = dopplerUpsample
            db = dopplerPencil(u: u)
        case .range:
            db = rangePencil()
        case .both:
            // A cell is bright only where both agree: Doppler sharpness from the slow-time pencil,
            // range sharpness from the fast-time pencil.
            u = dopplerUpsample
            db = dopplerPencil(u: u)
            let rg = rangePencil()
            for row in 0..<(m * u) {
                let coarse = min(m - 1, max(0, Int((Double(row - m * u / 2) / Double(u)).rounded()) + m / 2))
                for kb in 0..<nr { db[row * nr + kb] = min(db[row * nr + kb], rg[coarse * nr + kb]) }
            }
        }
        let rows = m * u

        let pri = 2 * p.tpMs / 1000
        let dv = wavelength(p) / 2 / (Double(m) * pri) / Double(u)    // m/s per image row
        // strongest cell away from zero Doppler and the feed-through at the first bins
        var peak: (range: Double, velocity: Double, db: Double)?
        let firstBin = max(1, Int(ceil(0.5 / inp.metersPerBin)))
        var best: Float = -400
        for r in 0..<rows where abs(r - rows / 2) > u {
            for kb in firstBin..<max(firstBin, nr) where db[r * nr + kb] > best {
                best = db[r * nr + kb]
                peak = (Double(kb) * inp.metersPerBin, Double(rows / 2 - r) * dv, Double(best))
            }
        }
        // colour with the jet map, like the waterfall
        let lo = Float(p.dbTop - p.rdDbRange), cs = Float(255 / max(1, p.rdDbRange))
        var rgba = [UInt8](repeating: 255, count: rows * nr * 4)
        for i in 0..<(rows * nr) {
            let c = Int(max(0, min(255, ((db[i] - lo) * cs).rounded()))) * 4
            rgba[i * 4] = RTIBuffer.jet[c]; rgba[i * 4 + 1] = RTIBuffer.jet[c + 1]; rgba[i * 4 + 2] = RTIBuffer.jet[c + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let img = CGImage(width: nr, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: nr * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        var snap = RangeDopplerSnapshot(image: img, pulses: m, velocityStep: dv, topVelocity: Double(rows / 2) * dv,
                                        peak: peak, slowPhase: slowPhase?.map { Float($0) })
        snap.rows = rows
        snap.ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        snap.db = db
        return snap
    }
}
