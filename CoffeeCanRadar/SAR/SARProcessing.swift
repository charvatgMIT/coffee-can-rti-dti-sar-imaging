import Accelerate
import AVFoundation
import Foundation

let feetPerMeter = 1 / 0.3048

enum PulseAlignment: String, Codable, CaseIterable, Identifiable {
    case interpolated = "Sub-sample edge (RTI interpolation)"
    case mit = "Integer sample (MIT script)"
    var id: String { rawValue }
}

enum SARSuperRes: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case range = "Matrix pencil in range"
    case crossrange = "Matrix pencil in crossrange"
    case both = "Matrix pencil in range and crossrange"
    var id: String { rawValue }
    var inRange: Bool { self == .range || self == .both }
    var inCrossrange: Bool { self == .crossrange || self == .both }
}

enum SVAMode: String, Codable, CaseIterable, Identifiable {
    case joint = "Joint I/Q"
    case separate = "I and Q separately (Stankwitz)"
    case dual = "Dual apodization (rect/Hann minimum)"
    var id: String { rawValue }
}

enum SARAlgorithm: String, Codable, CaseIterable, Identifiable {
    case backprojection = "Backprojection (AFRL bpBasic.m)"
    case rma = "Range migration (MIT SBAND_RMA_IFP.m)"
    var id: String { rawValue }
}

/// Settings for the MIT Coffee Can Radar SAR experiment (Experiment 3). Defaults follow
/// SBAND_RMA_opendata.m and SBAND_RMA_IFP.m.
struct SARParams: Codable, Equatable {
    var invert = true              // trig = -Y(:,1), s = -Y(:,2)
    var syncOnRight = false        // sync on the left channel, IF on the right
    var tpMs: Double = 20          // up-chirp time Tp
    var trpSeconds: Double = 0.25  // minimum range-profile (position) duration Trp
    var fStartMHz: Double = 2260
    var fStopMHz: Double = 2590
    var syncThreshold: Double = 0.08
    var alignment: PulseAlignment = .interpolated
    var interpolation = 16         // edge upsampling factor (>= 10), as in the RTI app
    var holdoff = 11               // samples that must be below the threshold before a rising edge
    var chirpsPerPosition = 20     // up-chirps averaged at EVERY position (0 = MIT: all in the first Trp)
    var spacingInches: Double = 2  // antenna spacing along the rail
    var fullFOV = false            // 1-inch spacing: no grating lobes, image out to +/-90 degrees
    var subtractMean = true        // remove the mean over the aperture (as in the script)
    var mitMean = false            // use MIT's running mean exactly (it only removes ~63% of the mean)
    var rsFeet: Double = 0         // scene-centre range Rs for the matched filter (0 in the script)
    var zpad = 2048                // cross-range zero-padded length
    var kStart: Double = 73        // Stolt output Ky grid (rad/m)
    var kStop: Double = 108.5
    var nKy = 1024
    var hannAfterStolt = false     // the script computes this window but leaves it commented out
    var crossRangeFt: Double = 200 // image shown: crossrange -x ... +x
    var downStartFt: Double = 1    // downrange shown
    var downStopFt: Double = 350
    var rangeScaling = true        // multiply by range^(3/2), as in the script
    var blankGratingLobes = true   // blank angles where the aperture's grating lobes (aliases) can land
    var scaleBySlantRange = true   // use the true range from the aperture centre, not downrange (MIT's script)
    var dbRange: Double = 40       // colour scale below the image maximum
    var algorithm: SARAlgorithm = .backprojection
    var bpNfft = 8192              // backprojection: zero-padded range-profile FFT size (data.Nfft)
    var bpPixelFt: Double = 0.25   // backprojection: image pixel spacing
    var bpR0Ft: Double = 0         // backprojection: reference range R0 (0 = middle of the downrange shown)
    var bpHann = true              // backprojection: Hann window over frequency first (as the RMA script does)
    var sva = false                // spatially variant apodization on the complex image (replaces the Hann windows)
    var svaMode: SVAMode = .joint
    var svaHannCap = true          // never let an SVA pixel exceed the (gain-matched) Hann image
    var superRes: SARSuperRes = .off
    var bweFactor = 3              // range: bandwidth extrapolated to this many times the measured band
    var pencilRule: PencilOrderRule = .gap   // gap: about 3x faster than ESTER per fit (matters per pixel)
    var pencilMaxTargets = 8       // model order cap per fit
    var pencilFB = true            // forward-backward averaging in the pencil
    var esterThreshold: Double = 0.3
    var crossPeakWidth: Double = 0.1    // crossrange: kept width around the pixel, in FFT resolution cells
    var rangePGA = true            // phase gradient autofocus in range (fast time: one phase per frequency sample)
    var crossPGA = true            // autofocus in crossrange (one phase per aperture position)
    var pgaIterations = 8

    var deltaX: Double { spacingInches / 12 / feetPerMeter }   // m
}

/// One position per row: the averaged up-chirp after the Hilbert transform (N/2 complex samples).
struct ParsedSAR {
    var fs: Double
    var n: Int                    // samples per up-chirp, N = Tp*FS
    var positions: Int
    var pulsesPerPosition: [Int]
    var re: [Double]              // [position][sample], positions x n/2, before mean subtraction
    var im: [Double]
    var seconds: Double           // recording length
    var jitterIntegerUs: Double?  // sync period jitter (std. dev.) from integer-sample edges
    var jitterInterpUs: Double?   // ... and from the interpolated edges (sub-sample alignment only)
    var prepared = false          // mean already subtracted and autofocus applied (see autofocus())
    var rangePhase: [Double]?     // range PGA estimate (rad) per frequency sample, when applied
    var crossPhase: [Double]?     // crossrange autofocus estimate (rad) per aperture position, when applied
    var requestedChirps = 0       // up-chirps per position asked for (0 = MIT: all in the first Trp)
    var availableChirpsMin: Int?  // fewest complete up-chirps found at any position
    var cols: Int { n / 2 }
}

struct SARImage {
    var db: [Float]               // [row][col], row 0 = nearest downrange
    var rows: Int, cols: Int
    var crossRange: (Double, Double)   // ft
    var downRange: (Double, Double)    // ft
    var maxDB: Double
    var pencilNote: String?       // super-resolution summary for the status line
}

struct DBImage {
    var db: [Float]               // [row][col], row 0 at the top
    var rows: Int, cols: Int
    var maxDB: Double
}

struct SARResult {
    var parsed: ParsedSAR
    var image: SARImage
    var rangeProfiles: DBImage    // positions (rows) x range (cols)
    var rangeProfileMaxFt: Double
    var kSpace: DBImage?          // Kx (rows) x Ky (cols) after Stolt interpolation (range migration only)
    var algorithm: SARAlgorithm
    var parseSeconds: Double
    var imageSeconds: Double
}

enum SARError: LocalizedError {
    case read(String), noPositions
    var errorDescription: String? {
        switch self {
        case .read(let s): return "Couldn't read the recording: \(s)"
        case .noPositions: return "No aperture positions found. Check the sync channel, Trp and the invert setting."
        }
    }
}

// MARK: - WAV

struct StereoRecording {
    var left: [Float], right: [Float], fs: Double
}

func readStereoWAV(_ url: URL) throws -> StereoRecording {
    let file: AVAudioFile
    do { file = try AVAudioFile(forReading: url) } catch { throw SARError.read(error.localizedDescription) }
    let fmt = file.processingFormat
    guard fmt.channelCount >= 2 else { throw SARError.read("it has \(fmt.channelCount) channel; sync and IF need 2.") }
    let frames = AVAudioFrameCount(file.length)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { throw SARError.read("out of memory") }
    do { try file.read(into: buf) } catch { throw SARError.read(error.localizedDescription) }
    let n = Int(buf.frameLength)
    guard let ch = buf.floatChannelData else { throw SARError.read("unsupported sample format") }
    // AVAudioFile scales 16-bit samples by 1/32768, the same as MATLAB's wavread
    return StereoRecording(left: Array(UnsafeBufferPointer(start: ch[0], count: n)),
                           right: Array(UnsafeBufferPointer(start: ch[1], count: n)), fs: fmt.sampleRate)
}

// MARK: - FFT helpers

/// Direct DFT for any length (the up-chirp is N = 882 samples at 44.1 kHz, not a power of two).
/// forward: X(k) = sum x(n) e^{-j2pi kn/N}; inverse: x(n) = (1/N) sum X(k) e^{+j2pi kn/N} (MATLAB's ifft).
func dft(_ re: [Double], _ im: [Double], inverse: Bool) -> ([Double], [Double]) {
    let n = re.count
    let c = (0..<n).map { cos(2 * Double.pi * Double($0) / Double(n)) }
    let s = (0..<n).map { (inverse ? 1.0 : -1.0) * sin(2 * Double.pi * Double($0) / Double(n)) }
    var or = [Double](repeating: 0, count: n), oi = or
    for k in 0..<n {
        var ar = 0.0, ai = 0.0, idx = 0
        for t in 0..<n {
            ar += re[t] * c[idx] - im[t] * s[idx]
            ai += re[t] * s[idx] + im[t] * c[idx]
            idx += k; if idx >= n { idx -= n }
        }
        or[k] = inverse ? ar / Double(n) : ar
        oi[k] = inverse ? ai / Double(n) : ai
    }
    return (or, oi)
}

final class FFT {
    let log2n: Int
    let setup: FFTSetupD
    init(log2n: Int) {
        self.log2n = log2n
        setup = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetupD(setup) }

    /// In place, length 2^log2n; inverse is scaled by 1/n like MATLAB's ifft.
    func run(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
            }
        }
        if inverse {
            var sc = 1 / Double(1 << log2n)
            vDSP_vsmulD(re, 1, &sc, &re, 1, vDSP_Length(re.count))
            vDSP_vsmulD(im, 1, &sc, &im, 1, vDSP_Length(im.count))
        }
    }
}

/// MATLAB linspace.
func linspace(_ a: Double, _ b: Double, _ n: Int) -> [Double] {
    n == 1 ? [b] : (0..<n).map { a + (b - a) * Double($0) / Double(n - 1) }
}

private func log2Ceil(_ n: Int) -> Int { Int(ceil(log2(Double(max(2, n))))) }

// MARK: - Trigger interpolation (from Coffee Can Radar RTI, RadarProcessor.swift)

/// Half-width (taps per side) of the windowed-sinc interpolator.

/// sinc(u) tapered by a Blackman window spanning +/- kernelHalf samples.
/// Band-limited value of x at fractional index t (needs kernelHalf samples on each side).
@inline(__always) func interpolate(_ x: [Float], at t: Double) -> Double {
    let n0 = Int(floor(t))
    let f = t - Double(n0)
    if f == 0 { return Double(x[n0]) }
    var s = 0.0
    for m in (-kernelHalf + 1)...kernelHalf { s += Double(x[n0 + m]) * sincKernel(f - Double(m)) }
    return s
}

/// Rising edges of the sync in one position, as the RTI app finds them: the sync goes above the
/// threshold after at least `holdoff` samples below it. The edge is upsampled `u` times with the
/// windowed-sinc interpolator between the last sample below and the first above, then refined
/// linearly between the two upsampled points that straddle the threshold.
/// Returns (integer index, interpolated time) for each edge with room for 2N samples after it.
func interpolatedEdges(_ rt: [Float], threshold th: Double, holdoff: Int, upsample u: Int, last: Int) -> [(i: Int, t: Double)] {
    var edges: [(Int, Double)] = []
    var below = 0
    let start = kernelHalf + 2
    guard last > start else { return [] }
    for i in start..<last {
        if Double(rt[i]) > th {
            if below >= holdoff {
                var pt = Double(i - 1), pv = Double(rt[i - 1]), tEdge = Double(i)
                for j in 1...u {
                    let t = Double(i - 1) + Double(j) / Double(u)
                    let v = j == u ? Double(rt[i]) : interpolate(rt, at: t)
                    if v > th { tEdge = pt + (th - pv) / (v - pv) / Double(u); break }
                    pt = t; pv = v
                }
                edges.append((i, tEdge))
            }
            below = 0
        } else {
            below += 1
        }
    }
    return edges
}

/// IF samples x(t0 ... t0+N-1), resampled with the windowed sinc when t0 is fractional.
func alignedPulse(_ x: [Float], at t0: Double, count n: Int) -> [Double] {
    let n0 = Int(floor(t0)), f = t0 - Double(n0)
    if f == 0 { return (0..<n).map { Double(x[n0 + $0]) } }
    let taps = (0..<(2 * kernelHalf)).map { sincKernel(f - Double($0 - kernelHalf + 1)) }
    return (0..<n).map { k in
        var s = 0.0
        let base = n0 + k - kernelHalf + 1
        for m in 0..<(2 * kernelHalf) { s += Double(x[base + m]) * taps[m] }
        return s
    }
}


// MARK: - SBAND_RMA_opendata.m: parse positions and pulses

func parseSAR(_ rec: StereoRecording, _ p: SARParams) throws -> ParsedSAR {
    let fs = rec.fs
    let sg: Float = p.invert ? -1 : 1
    let trig = (p.syncOnRight ? rec.right : rec.left).map { sg * $0 }
    let s = (p.syncOnRight ? rec.left : rec.right).map { sg * $0 }
    let total = trig.count
    let n = Int((p.tpMs * 1e-3 * fs).rounded())          // N = Tp*FS
    let nrp = Int((p.trpSeconds * fs).rounded())           // Nrp = Trp*FS

    // rpstart = abs(trig) > mean(abs(trig)); a position starts where rpstart is 1 after Nrp zeros
    var meanAbs: Float = 0
    vDSP_meamgv(trig, 1, &meanAbs, vDSP_Length(total))
    let rpstart = trig.map { abs($0) > meanAbs }
    var starts: [Int] = []
    var ones = 0                                            // rpstart count in [ii-Nrp, ii-1]
    if total > 2 * nrp {
        for i in 0..<nrp where rpstart[i] { ones += 1 }
        for ii in nrp..<(total - nrp) {                     // MATLAB ii = Nrp+1 : end-Nrp (1-based)
            if rpstart[ii] && ones == 0 { starts.append(ii) }
            if rpstart[ii] { ones += 1 }
            if rpstart[ii - nrp] { ones -= 1 }
        }
    }
    guard !starts.isEmpty else { throw SARError.noPositions }

    // Edges per position. With chirpsPerPosition = 0 this is MIT's script: only the first Trp of each
    // position is used and every chirp in it is averaged (the count varies by position). Otherwise the
    // whole position (up to the next one) is searched and exactly the first K chirps are averaged at
    // every position, so all positions have the same integration.
    let th = Float(p.syncThreshold)
    let half = n / 2
    let fixed = p.chirpsPerPosition > 0
    var edgesPerPosition: [[(i: Int, t: Double)]] = []
    var segments: [Range<Int>] = []
    for (row, st) in starts.enumerated() {
        let end = fixed ? min(row + 1 < starts.count ? starts[row + 1] : total, st + Int(30 * fs)) : st + nrp
        let seg = st..<end
        segments.append(seg)
        let rt = Array(trig[seg])
        let last = rt.count - 2 * n                         // a whole sweep (2N) must follow the edge
        var edges: [(i: Int, t: Double)] = []
        if p.alignment == .interpolated {
            edges = interpolatedEdges(rt, threshold: p.syncThreshold, holdoff: p.holdoff,
                                      upsample: max(10, p.interpolation), last: last)
        } else if last > 11 {
            // MIT: start(ii-10:ii-2) all low and RPtrig(ii) the (first) maximum of RPtrig(ii:ii+2N)
            let high = rt.map { $0 > th }
            for i in 11..<last {                            // MATLAB ii = 12 : size-2N (1-based)
                var quiet = true
                for k in (i - 10)...(i - 2) where high[k] { quiet = false; break }
                guard quiet else { continue }
                let v = rt[i]
                var first = true
                for k in (i + 1)...(i + 2 * n) where rt[k] > v { first = false; break }
                if first { edges.append((i, Double(i))) }
            }
        }
        edgesPerPosition.append(edges)
    }
    // The same K at every position: a chirp is used only if another edge follows it (so it is complete);
    // if any position has fewer, K is lowered to what every position has.
    var k = p.chirpsPerPosition
    if fixed {
        let available = edgesPerPosition.map { max(0, $0.count - 1) }.min() ?? 0
        k = min(k, available)
        guard k > 0 else { throw SARError.noPositions }
    }

    var outRe = [Double](repeating: 0, count: starts.count * half), outIm = outRe
    var pulses: [Int] = []
    var periodsInt: [Double] = [], periodsInterp: [Double] = []   // sync periods (samples), within positions
    for (row, seg) in segments.enumerated() {
        let rp = Array(s[seg])
        let edges = fixed ? Array(edgesPerPosition[row].prefix(k)) : edgesPerPosition[row]
        var sif = [Double](repeating: 0, count: n)
        for e in edges {
            if p.alignment == .interpolated {
                let x = alignedPulse(rp, at: e.t, count: n)
                for j in 0..<n { sif[j] += x[j] }
            } else {
                for j in 0..<n { sif[j] += Double(rp[e.i + j]) }
            }
        }
        for j in 1..<max(1, edges.count) {
            periodsInt.append(Double(edges[j].i - edges[j - 1].i))
            if p.alignment == .interpolated { periodsInterp.append(edges[j].t - edges[j - 1].t) }
        }
        let count = edges.count
        pulses.append(count)
        // hilbert transform: q = ifft(SIF/count); sif = fft(q(N/2+1:N))
        let scaled = sif.map { $0 / Double(count) }          // NaN when count = 0, as in MATLAB
        let q = dft(scaled, [Double](repeating: 0, count: n), inverse: true)
        let y = dft(Array(q.0[half..<n]), Array(q.1[half..<n]), inverse: false)
        for j in 0..<half {
            outRe[row * half + j] = y.0[j].isNaN ? 1e-30 : y.0[j]
            outIm[row * half + j] = y.1[j].isNaN ? 0 : y.1[j]
        }
    }
    // Jitter about the median period: the MIT detector can skip a pulse, giving one double period.
    func jitter(_ a: [Double]) -> Double? {
        guard a.count > 2 else { return nil }
        let med = a.sorted()[a.count / 2]
        let near = a.filter { abs($0 - med) < 0.25 * med }
        return near.count > 2 ? stdDev(near) / fs * 1e6 : nil
    }
    let availableMin = fixed ? (edgesPerPosition.map { max(0, $0.count - 1) }.min() ?? 0) : nil
    return ParsedSAR(fs: fs, n: n, positions: starts.count, pulsesPerPosition: pulses,
                     re: outRe, im: outIm, seconds: Double(total) / fs,
                     jitterIntegerUs: jitter(periodsInt), jitterInterpUs: jitter(periodsInterp),
                     requestedChirps: p.chirpsPerPosition, availableChirpsMin: availableMin)
}

// MARK: - SBAND_RMA_IFP.m: range migration algorithm

/// Signs of the RMA demodulation terms (2*k_c*R, pi/dx*x, kStart*y) for SVA, from MIT's ifft2 / rot90 /
/// fliplr conventions; found by imaging synthetic point targets (all other combinations leave a carrier).
var rmaSigns: (Double, Double, Double) = (1, 1, -1)

/// Removes the mean over the aperture: exactly, or as MIT's script does (see subtractMeanLikeMATLAB).
func subtractApertureMean(_ re: inout [Double], _ im: inout [Double], rows M: Int, cols nt: Int, mit: Bool) {
    if mit { subtractMeanLikeMATLAB(&re, &im, rows: M, cols: nt); return }
    for k in 0..<nt {
        var mr = 0.0, mi = 0.0
        for r in 0..<M { mr += re[r * nt + k]; mi += im[r * nt + k] }
        mr /= Double(M); mi /= Double(M)
        for r in 0..<M { re[r * nt + k] -= mr; im[r * nt + k] -= mi }
    }
}

/// for ii = 1:size(s,1), s(ii,:) = s(ii,:) - mean(s,1); end  -- the mean is recomputed after each row changes,
/// so each row only removes 1/M of what is left: (1 - 1/M)^M, about 37%, of the common component remains
/// (mostly the direct antenna leakage, which then shows as a stripe at zero crossrange without a window).
func subtractMeanLikeMATLAB(_ re: inout [Double], _ im: inout [Double], rows M: Int, cols nt: Int) {
    var sumR = [Double](repeating: 0, count: nt), sumI = sumR
    for r in 0..<M { for k in 0..<nt { sumR[k] += re[r * nt + k]; sumI[k] += im[r * nt + k] } }
    for r in 0..<M {
        for k in 0..<nt {
            let mr = sumR[k] / Double(M), mi = sumI[k] / Double(M)
            re[r * nt + k] -= mr; im[r * nt + k] -= mi
            sumR[k] -= mr; sumI[k] -= mi
        }
    }
}

func formImage(_ data: ParsedSAR, _ p: SARParams) -> (image: SARImage, kSpace: DBImage) {
    let M = data.positions, nt = data.cols
    var re = data.re, im = data.im

    // s(ii,:) = s(ii,:) - mean(s,1), row by row as the script does (the mean is recomputed after
    // each row has been changed)
    if p.subtractMean && !data.prepared { subtractApertureMean(&re, &im, rows: M, cols: nt, mit: p.mitMean) }
    // Hann window over fast time: H(ii) = 0.5 + 0.5*cos(2*pi*(ii-N/2)/N), ii = 1..N
    let h = (1...nt).map { 0.5 + 0.5 * cos(2 * Double.pi * (Double($0) - Double(nt) / 2) / Double(nt)) }
    if !p.sva && p.bpHann { for r in 0..<M { for k in 0..<nt { re[r * nt + k] *= h[k]; im[r * nt + k] *= h[k] } } }

    // symmetric cross-range zero pad, along-track FFT, fftshift
    let zpad = max(p.zpad, 1 << log2Ceil(M))
    let zfft = FFT(log2n: log2Ceil(zpad))
    let index = Int((Double(zpad - M) / 2).rounded())
    var S_re = [Double](repeating: 0, count: zpad * nt), S_im = S_re   // [kx][kr]
    var colR = [Double](repeating: 0, count: zpad), colI = colR
    for k in 0..<nt {
        for i in 0..<zpad { colR[i] = 0; colI[i] = 0 }
        for r in 0..<M { colR[index + r] = re[r * nt + k]; colI[index + r] = im[r * nt + k] }
        zfft.run(&colR, &colI, inverse: false)
        for i in 0..<zpad {
            let sh = (i + zpad / 2) % zpad
            S_re[sh * nt + k] = colR[i]; S_im[sh * nt + k] = colI[i]
        }
    }
    let dx = p.deltaX
    let kx = linspace(-Double.pi / dx, Double.pi / dx, zpad)
    let kr = linspace(4 * Double.pi / speedOfLight * p.fStartMHz * 1e6, 4 * Double.pi / speedOfLight * p.fStopMHz * 1e6, nt)

    // matched filter: exp(j * Rs * sqrt(Kr^2 - Kx^2))
    let rs = p.rsFeet / feetPerMeter
    if rs != 0 {
        for i in 0..<zpad {
            for k in 0..<nt {
                let d = kr[k] * kr[k] - kx[i] * kx[i]
                let (cr, ci) = d >= 0 ? (cos(rs * d.squareRoot()), sin(rs * d.squareRoot())) : (exp(-rs * (-d).squareRoot()), 0)
                let a = S_re[i * nt + k], b = S_im[i * nt + k]
                S_re[i * nt + k] = a * cr - b * ci; S_im[i * nt + k] = a * ci + b * cr
            }
        }
    }

    // Stolt interpolation onto an even Ky grid (linear, NaN outside -> 1e-30)
    let nky = p.nKy
    let kyEven = linspace(p.kStart, p.kStop, nky)
    var St_re = [Double](repeating: 1e-30, count: zpad * nky), St_im = [Double](repeating: 0, count: zpad * nky)
    let hk = (1...nky).map { 0.5 + 0.5 * cos(2 * Double.pi * (Double($0) - Double(nky) / 2) / Double(nky)) }
    for i in 0..<zpad {
        let ky = kr.map { ($0 * $0 - kx[i] * kx[i]).squareRoot() }
        var j = 0
        for (o, y) in kyEven.enumerated() {
            guard y >= ky[0], y <= ky[nt - 1] else { continue }
            while j < nt - 2 && ky[j + 1] < y { j += 1 }
            let f = (y - ky[j]) / (ky[j + 1] - ky[j])
            let w = p.hannAfterStolt && !p.sva ? hk[o] : 1
            St_re[i * nky + o] = (S_re[i * nt + j] * (1 - f) + S_re[i * nt + j + 1] * f) * w
            St_im[i * nky + o] = (S_im[i * nt + j] * (1 - f) + S_im[i * nt + j + 1] * f) * w
        }
    }
    var kdb = [Float](repeating: 0, count: zpad * nky)
    for i in 0..<(zpad * nky) { kdb[i] = Float(10 * log10(St_re[i] * St_re[i] + St_im[i] * St_im[i] + 1e-30)) }
    let kSpace = DBImage(db: kdb, rows: zpad, cols: nky, maxDB: Double(kdb.max() ?? 0))

    // v = ifft2(S_st, 4*zpad, 4*nKy), then S_image = fliplr(rot90(v)) and the crop, computed only
    // where needed: S_image(i,j) = v(m-j+1, n-i+1) (1-based)
    let m = 4 * zpad, n = 4 * nky
    let bw = speedOfLight * (p.kStop - p.kStart) / (4 * Double.pi)
    let maxRange = speedOfLight * Double(nky) / (2 * bw) * feetPerMeter        // ft, as the script
    let rsFt = p.rsFeet
    let dr1 = p.downStartFt + rsFt, dr2 = p.downStopFt + rsFt
    let apertureFt = Double(zpad) * dx * feetPerMeter
    let dr1i = max(1, Int((dr1 / maxRange * Double(n)).rounded()))
    let dr2i = min(n, max(dr1i, Int((dr2 / maxRange * Double(n)).rounded())))
    let cr1i = max(1, Int(((-p.crossRangeFt + apertureFt / 2) / apertureFt * Double(m)).rounded()))
    let cr2i = min(m, max(cr1i, Int(((p.crossRangeFt + apertureFt / 2) / apertureFt * Double(m)).rounded())))
    let rows = dr2i - dr1i + 1, cols = cr2i - cr1i + 1
    // range IFFT of every Kx row, keeping v's columns n-dr2i ... n-dr1i (0-based)
    let k0 = n - dr2i
    let rfft = FFT(log2n: log2Ceil(n))
    var A_re = [Double](repeating: 0, count: rows * zpad), A_im = A_re     // [kept column][kx]
    var rr = [Double](repeating: 0, count: n), ri = rr
    for i in 0..<zpad {
        for k in 0..<n { rr[k] = k < nky ? St_re[i * nky + k] : 0; ri[k] = k < nky ? St_im[i * nky + k] : 0 }
        rfft.run(&rr, &ri, inverse: true)
        for c in 0..<rows { A_re[c * zpad + i] = rr[k0 + c]; A_im[c * zpad + i] = ri[k0 + c] }
    }
    // cross-range IFFT of every kept column, keeping v's rows m-cr2i ... m-cr1i (0-based)
    let xfft = FFT(log2n: log2Ceil(m))
    var cre = [Float](repeating: 0, count: rows * cols), cim = cre
    var xr = [Double](repeating: 0, count: m), xi = xr
    for c in 0..<rows {
        for i in 0..<m { xr[i] = i < zpad ? A_re[c * zpad + i] : 0; xi[i] = i < zpad ? A_im[c * zpad + i] : 0 }
        xfft.run(&xr, &xi, inverse: true)
        // kept column k0 + c of v is S_image row i = n - (k0 + c) (1-based) = dr2i - c
        let row = dr2i - c - dr1i                       // 0 = nearest
        for col in 0..<cols {
            let x = m - (cr1i + col)                    // 0-based row of v for S_image column cr1i + col
            cre[row * cols + col] = Float(xr[x]); cim[row * cols + col] = Float(xi[x])
        }
    }
    // the zero-padded aperture spans +/- apertureFt/2; a wider request is clamped there
    let crShown = (Double(cr1i) / Double(m) * apertureFt - apertureFt / 2, Double(cr2i) / Double(m) * apertureFt - apertureFt / 2)
    if p.sva {
        // SVA needs the image at baseband. Near a scatterer the RMA image's local wavenumber is 2*k_c along the
        // line of sight, measured from the grid's reference (Kx = -pi/dx, Ky = kStart), with MIT's flips.
        let kc = 4 * Double.pi * (p.fStartMHz + p.fStopMHz) / 2 * 1e6 / speedOfLight
        let ys = linspace(p.downStartFt, p.downStopFt, rows), xs = linspace(crShown.0, crShown.1, cols)
        for r in 0..<rows {
            let y = ys[r] / feetPerMeter
            for col in 0..<cols {
                let x = xs[col] / feetPerMeter
                let R = (x * x + y * y).squareRoot()
                let ph = rmaSigns.0 * kc * R + rmaSigns.1 * Double.pi / dx * x + rmaSigns.2 * p.kStart * y
                let cs = Float(cos(ph)), sn = Float(sin(ph))
                let i = r * cols + col, a = cre[i], b = cim[i]
                cre[i] = a * cs - b * sn; cim[i] = a * sn + b * cs
            }
        }
    }
    let image = finishImage(re: &cre, im: &cim, rows: rows, cols: cols, crossRange: crShown,
                            downRange: (p.downStartFt, p.downStopFt), rangeOffsetFt: 0, positions: M, p)
    return (image, kSpace)
}

// MARK: - bpBasic.m: backprojection (LeRoy Gorham, AFRL, 2010)

/// Backprojection after Gorham & Moore, "SAR image formation toolbox for MATLAB" (SPIE 2010), bpBasic.m.
/// Each aperture position is one pulse. Its N/2 complex samples are the phase history: sample k is the
/// return at transmit frequency f_k = fstart + k*deltaF. MIT's Hilbert step gives e^{+j4*pi*f*R/c}, AFRL's
/// convention is e^{-j4*pi*f*(R-R0)/c}, so the data are conjugated and referenced to R0. The antenna moves
/// along x (spacing deltaX, centred on 0), the image is on the ground plane z = 0, y = downrange.
func backproject(_ data: ParsedSAR, _ p: SARParams) -> SARImage {
    let c = 299792458.0                                    // bpBasic's speed of light
    let M = data.positions, K = data.cols
    var re = data.re, im = data.im
    if p.subtractMean && !data.prepared { subtractApertureMean(&re, &im, rows: M, cols: K, mit: p.mitMean) }
    let bp = BPProfiles(re: re, im: im, positions: M, cols: K, p, hann: p.bpHann && !p.sva)
    let f = bp.f, antX = bp.antX, r0 = bp.r0, nfft = bp.nfft, binM = bp.binM, rMin = bp.rMin, rMax = bp.rMax
    let rcRe = bp.rcRe, rcIm = bp.rcIm, minF = f[0]

    // pixel grid: crossrange x, downrange y (row 0 = nearest), z = 0
    let px = max(0.01, p.bpPixelFt)
    let cols = max(2, Int(((2 * p.crossRangeFt) / px).rounded()) + 1)
    let rows = max(2, Int(((p.downStopFt - p.downStartFt) / px).rounded()) + 1)
    let xs = linspace(-p.crossRangeFt, p.crossRangeFt, cols).map { $0 / feetPerMeter }
    let ys = linspace(p.downStartFt, p.downStopFt, rows).map { $0 / feetPerMeter }
    var cre = [Float](repeating: 0, count: rows * cols), cim = cre
    let k4 = 4 * Double.pi * minF / c
    cre.withUnsafeMutableBufferPointer { outRe in cim.withUnsafeMutableBufferPointer { outIm in
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let y = ys[r]
            var accRe = [Double](repeating: 0, count: cols), accIm = accRe
            for ii in 0..<M {
                let ax = antX[ii], base = ii * nfft
                for col in 0..<cols {
                    let ddx = ax - xs[col]
                    let dR = (ddx * ddx + y * y).squareRoot() - r0
                    guard dR > rMin, dR < rMax else { continue }
                    // interp1(r_vec, rc, dR, 'linear')
                    let u = dR / binM + Double(nfft / 2)
                    let i0 = Int(u), fr = u - Double(i0)
                    guard i0 + 1 < nfft else { continue }
                    let vr = rcRe[base + i0] * (1 - fr) + rcRe[base + i0 + 1] * fr
                    let vi = rcIm[base + i0] * (1 - fr) + rcIm[base + i0 + 1] * fr
                    // * exp(1i*4*pi*minF/c*dR)
                    let ph = k4 * dR
                    let cs = cos(ph), sn = sin(ph)
                    accRe[col] += vr * cs - vi * sn
                    accIm[col] += vr * sn + vi * cs
                }
            }
            for col in 0..<cols {
                var a = accRe[col], b = accIm[col]
                if p.sva {
                    // near a scatterer the image carries e^{j*4*pi*fc*(R-R0)/c} along the line of sight from
                    // the aperture; SVA needs it at baseband
                    let R = (xs[col] * xs[col] + y * y).squareRoot()
                    let ph = -4 * Double.pi * (f[0] + f[K - 1]) / 2 * (R - r0) / c
                    let cs = cos(ph), sn = sin(ph)
                    (a, b) = (a * cs - b * sn, a * sn + b * cs)
                }
                outRe[r * cols + col] = Float(a); outIm[r * cols + col] = Float(b)
            }
        }
    } }
    var note: String?
    if p.superRes.inCrossrange {
        note = crossrangePencil(bp: bp, xs: xs, ys: ys, re: &cre, im: &cim, rows: rows, cols: cols, positions: M, p)
    }
    var img = finishImage(re: &cre, im: &cim, rows: rows, cols: cols, crossRange: (-p.crossRangeFt, p.crossRangeFt),
                          downRange: (p.downStartFt, p.downStopFt), rangeOffsetFt: 0, positions: M, p)
    img.pencilNote = note
    return img
}

/// bpBasic's range profiles for every aperture position, and the geometry, shared by the image and the autofocus.
struct BPProfiles {
    let c = 299792458.0
    var f: [Double], antX: [Double], r0: Double, nfft: Int, binM: Double, rMin: Double, rMax: Double
    var rcRe: [Double], rcIm: [Double]

    init(re: [Double], im: [Double], positions M: Int, cols K: Int, _ p: SARParams, hann: Bool) {
        f = linspace(p.fStartMHz * 1e6, p.fStopMHz * 1e6, K)  // MIT: f = linspace(fstart, fstop, N/2)
        let deltaF = f[1] - f[0]
        let L = p.deltaX * Double(M)
        // MIT's image (fliplr(rot90(...)) in SBAND_RMA_IFP.m) shows the first recorded position at +x;
        // use the same orientation so the two algorithms' images line up
        antX = linspace(L / 2, -L / 2, M)
        r0 = (p.bpR0Ft > 0 ? p.bpR0Ft : (p.downStartFt + p.downStopFt) / 2) / feetPerMeter
        nfft = 1 << log2Ceil(max(p.bpNfft, 2 * K))
        let maxWr = c / (2 * deltaF)                       // unambiguous range swath (m)
        binM = maxWr / Double(nfft)                        // r_vec = (-Nfft/2 ... Nfft/2-1) * maxWr/Nfft
        rMin = -Double(nfft / 2) * binM; rMax = Double(nfft / 2 - 1) * binM
        let h = (1...K).map { hann ? 0.5 + 0.5 * cos(2 * Double.pi * (Double($0) - Double(K) / 2) / Double(K)) : 1 }
        // range profiles: rc = fftshift(ifft(phdata(:,ii), Nfft)), stored per pulse
        let fft = FFT(log2n: log2Ceil(nfft))
        rcRe = [Double](repeating: 0, count: M * nfft); rcIm = rcRe
        var xr = [Double](repeating: 0, count: nfft), xi = xr
        for ii in 0..<M {
            for k in 0..<nfft { xr[k] = 0; xi[k] = 0 }
            for k in 0..<K {
                // conj(s) * e^{+j4*pi*f*R0/c}
                let a = re[ii * K + k] * h[k], b = -im[ii * K + k] * h[k]
                let ph = 4 * Double.pi * f[k] * r0 / c
                let cs = cos(ph), sn = sin(ph)
                xr[k] = a * cs - b * sn; xi[k] = a * sn + b * cs
            }
            fft.run(&xr, &xi, inverse: true)
            for k in 0..<nfft {
                let sh = (k + nfft / 2) % nfft             // fftshift
                rcRe[ii * nfft + sh] = xr[k]; rcIm[ii * nfft + sh] = xi[k]
            }
        }
    }

    /// Contribution of position ii to the pixel at (x, y) metres (bpBasic's interp1 * phCorr).
    @inline(__always) func contribution(_ ii: Int, x: Double, y: Double) -> (Double, Double) {
        let ddx = antX[ii] - x
        let dR = (ddx * ddx + y * y).squareRoot() - r0
        guard dR > rMin, dR < rMax else { return (0, 0) }
        let u = dR / binM + Double(nfft / 2)
        let i0 = Int(u), fr = u - Double(i0)
        guard i0 + 1 < nfft else { return (0, 0) }
        let base = ii * nfft
        let vr = rcRe[base + i0] * (1 - fr) + rcRe[base + i0 + 1] * fr
        let vi = rcIm[base + i0] * (1 - fr) + rcIm[base + i0 + 1] * fr
        let ph = 4 * Double.pi * f[0] / c * dR
        let cs = cos(ph), sn = sin(ph)
        return (vr * cs - vi * sn, vr * sn + vi * cs)
    }
}

// MARK: - Autofocus

/// Mean subtraction, then range PGA and crossrange autofocus, applied to the data so both image
/// formation algorithms use them.
func autofocus(_ data: ParsedSAR, _ p: SARParams) -> ParsedSAR {
    var d = data
    let M = d.positions, K = d.cols
    if p.subtractMean { subtractApertureMean(&d.re, &d.im, rows: M, cols: K, mit: p.mitMean) }
    if p.rangePGA {
        let phi = rangePGA(re: &d.re, im: &d.im, rows: M, cols: K, iterations: max(1, p.pgaIterations))
        d.rangePhase = phi
    }
    if p.crossPGA {
        let psi = crossAutofocus(re: d.re, im: d.im, positions: M, cols: K, p)
        for ii in 0..<M {
            // pulse ii's backprojected contribution is multiplied by e^{+j psi}: s -> s e^{-j psi}
            let cs = cos(psi[ii]), sn = -sin(psi[ii])
            for k in 0..<K {
                let i = ii * K + k, a = d.re[i], b = d.im[i]
                d.re[i] = a * cs - b * sn; d.im[i] = a * sn + b * cs
            }
        }
        d.crossPhase = psi.map { -$0 }          // the estimated error (the correction is its negative)
    }
    d.prepared = true
    return d
}

/// Removes the least-squares line a + b*t (a constant phase or a shift is not an error).


/// Phase gradient autofocus along fast time (Jakowatz & Eichel), as in the RTI app: the phase error every
/// sweep shares (mostly VCO nonlinearity), one value per frequency sample. Each position's range profile
/// is a "range line": its strongest return is circularly shifted to zero range, windowed (the window
/// shrinks as the estimate converges), and transformed back; the sample-to-sample phase differences are
/// summed over positions and integrated. Linear trend removed. Corrects re/im in place.
func rangePGA(re: inout [Double], im: inout [Double], rows M: Int, cols K: Int, iterations: Int) -> [Double] {
    let P = 1 << log2Ceil(2 * K)
    let fft = FFT(log2n: log2Ceil(P))
    var total = [Double](repeating: 0, count: K)
    var gr = [Double](repeating: 0, count: P), gi = gr
    var cr = [[Double]](repeating: [Double](repeating: 0, count: P), count: M), ci = cr
    for _ in 0..<iterations {
        var avg = [Double](repeating: 0, count: P)
        for r in 0..<M {
            for t in 0..<P { gr[t] = t < K ? re[r * K + t] : 0; gi[t] = t < K ? im[r * K + t] : 0 }
            fft.run(&gr, &gi, inverse: false)
            var q0 = 0, best = -1.0
            for q in 0..<P { let pw = gr[q] * gr[q] + gi[q] * gi[q]; if pw > best { best = pw; q0 = q } }
            for q in 0..<P {
                let s = (q + q0) % P
                cr[r][q] = gr[s]; ci[r][q] = gi[s]
                avg[q] += gr[s] * gr[s] + gi[s] * gi[s]
            }
        }
        var ext = 0
        while ext < P / 2 - 1 && (avg[(ext + 1) % P] > 0.1 * avg[0] || avg[(P - ext - 1) % P] > 0.1 * avg[0]) { ext += 1 }
        let half = min(P / 2, max(3, Int((1.5 * Double(ext + 1)).rounded(.up))))
        var sr = [Double](repeating: 0, count: K), si = sr
        for r in 0..<M {
            for q in 0..<P {
                let signed = q <= P / 2 ? q : q - P
                let keep = abs(signed) <= half
                gr[q] = keep ? cr[r][q] : 0; gi[q] = keep ? ci[r][q] : 0
            }
            fft.run(&gr, &gi, inverse: true)
            for t in 1..<K {
                sr[t] += gr[t - 1] * gr[t] + gi[t - 1] * gi[t]
                si[t] += gr[t - 1] * gi[t] - gi[t - 1] * gr[t]
            }
        }
        var phi = [Double](repeating: 0, count: K)
        for t in 1..<K { phi[t] = phi[t - 1] + atan2(si[t], sr[t]) }
        removeLinearTrend(&phi)
        for t in 0..<K {
            total[t] += phi[t]
            let cs = cos(phi[t]), sn = -sin(phi[t])
            for r in 0..<M {
                let i = r * K + t, a = re[i], b = im[i]
                re[i] = a * cs - b * sn; im[i] = a * sn + b * cs
            }
        }
        if rms(phi) < 0.01 { break }
    }
    removeLinearTrend(&total)
    return total
}

/// Crossrange autofocus: one phase per aperture position (rail position errors, drift between positions).
/// A quick backprojected image (Hann-weighted, 1 ft pixels) gives the strongest isolated scatterers; each
/// position's contribution to those pixels is its backprojected phase history. PGA's estimator then aligns
/// every position with the sum of the others: psi_ii = arg sum_p I_others(p) conj(c_ii(p)), repeated over
/// all positions until it settles. Mean and linear trend removed (they only shift the image).
func crossAutofocus(re: [Double], im: [Double], positions M: Int, cols K: Int, _ p: SARParams) -> [Double] {
    let bp = BPProfiles(re: re, im: im, positions: M, cols: K, p, hann: true)
    let span = min(p.crossRangeFt, 150.0), y0 = max(30.0, p.downStartFt), y1 = p.downStopFt
    let step = 1.0
    let nx = Int(2 * span / step) + 1, ny = Int((y1 - y0) / step) + 1
    var mag = [Double](repeating: 0, count: nx * ny)
    mag.withUnsafeMutableBufferPointer { out in
        DispatchQueue.concurrentPerform(iterations: ny) { r in
            let y = (y0 + Double(r) * step) / feetPerMeter
            for c in 0..<nx {
                let x = (-span + Double(c) * step) / feetPerMeter
                var a = 0.0, b = 0.0
                for ii in 0..<M { let v = bp.contribution(ii, x: x, y: y); a += v.0; b += v.1 }
                out[r * nx + c] = a * a + b * b
            }
        }
    }
    // strongest local peaks, at least 3 ft apart, scaled for the R^-3 power fall-off so far scatterers count too
    var cand: [(x: Double, y: Double, w: Double)] = []
    for r in 1..<max(1, ny - 1) {
        let y = y0 + Double(r) * step
        for c in 1..<max(1, nx - 1) {
            let i = r * nx + c, v = mag[i]
            if v > mag[i - 1] && v >= mag[i + 1] && v > mag[i - nx] && v >= mag[i + nx] {
                cand.append((-span + Double(c) * step, y, v * pow(y, 3)))
            }
        }
    }
    var picks: [(x: Double, y: Double)] = []
    for c in cand.sorted(by: { $0.w > $1.w }) where picks.count < 200 {
        if !picks.contains(where: { abs($0.x - c.x) < 3 && abs($0.y - c.y) < 3 }) { picks.append((c.x, c.y)) }
    }
    guard picks.count >= 3 else { return [Double](repeating: 0, count: M) }
    // contributions c[ii][j], each scatterer normalised to unit total energy so a few huge ones don't dominate
    let J = picks.count
    var cr = [Double](repeating: 0, count: M * J), ci = cr
    for (j, pk) in picks.enumerated() {
        var e = 0.0
        for ii in 0..<M {
            let v = bp.contribution(ii, x: pk.x / feetPerMeter, y: pk.y / feetPerMeter)
            cr[ii * J + j] = v.0; ci[ii * J + j] = v.1; e += v.0 * v.0 + v.1 * v.1
        }
        let g = e > 0 ? 1 / e.squareRoot() : 0
        for ii in 0..<M { cr[ii * J + j] *= g; ci[ii * J + j] *= g }
    }
    var psi = [Double](repeating: 0, count: M)
    var Ir = [Double](repeating: 0, count: J), Ii = Ir
    for ii in 0..<M { for j in 0..<J { Ir[j] += cr[ii * J + j]; Ii[j] += ci[ii * J + j] } }
    for _ in 0..<max(1, p.pgaIterations) {
        var change = 0.0
        for ii in 0..<M {
            let cs = cos(psi[ii]), sn = sin(psi[ii])
            var ar = 0.0, ai = 0.0
            for j in 0..<J {
                let vr = cr[ii * J + j] * cs - ci[ii * J + j] * sn, vi = cr[ii * J + j] * sn + ci[ii * J + j] * cs
                let orr = Ir[j] - vr, oi = Ii[j] - vi                 // the image without this position
                // sum_p I_others * conj(c)
                ar += orr * cr[ii * J + j] + oi * ci[ii * J + j]
                ai += oi * cr[ii * J + j] - orr * ci[ii * J + j]
            }
            let new = atan2(ai, ar)
            change = max(change, abs(remainder(new - psi[ii], 2 * Double.pi)))
            let ncs = cos(new), nsn = sin(new)
            for j in 0..<J {
                let vr = cr[ii * J + j] * cs - ci[ii * J + j] * sn, vi = cr[ii * J + j] * sn + ci[ii * J + j] * cs
                let wr = cr[ii * J + j] * ncs - ci[ii * J + j] * nsn, wi = cr[ii * J + j] * nsn + ci[ii * J + j] * ncs
                Ir[j] += wr - vr; Ii[j] += wi - vi
            }
            psi[ii] = new
        }
        if change < 0.01 { break }
    }
    // unwrap, then drop the mean and linear trend
    for ii in 1..<M { psi[ii] = psi[ii - 1] + remainder(psi[ii] - psi[ii - 1], 2 * Double.pi) }
    removeLinearTrend(&psi)
    return psi
}

// MARK: - Image formation entry point

/// Forms the image with the chosen algorithm. Dual apodization forms it unweighted and with the Hann window
/// and keeps the smaller (gain-matched) value at every pixel; "limit by Hann" does the same with the SVA image.
func formSARImage(_ data: ParsedSAR, _ p: SARParams) -> (SARImage, DBImage?) {
    var d = data, q = p
    var note: [String] = []
    if p.superRes.inCrossrange { q.sva = false }        // the crossrange pencil replaces the pixel magnitudes
    if p.superRes.inCrossrange && p.algorithm == .rma { note.append("crossrange pencil needs backprojection") }
    if p.superRes.inRange {
        let t0 = Date()
        let r = bandwidthExtrapolate(data, p)
        d = r.data; q = r.params
        note.append(String(format: "range pencil: median order %d, band %.0f–%.0f MHz (%.2f s)", r.medianOrder, q.fStartMHz, q.fStopMHz, Date().timeIntervalSince(t0)))
    }
    var (img, k) = formSARImageUnmasked(d, q)
    if let n = img.pencilNote { note.append(n) }
    img.pencilNote = note.isEmpty ? nil : note.joined(separator: "; ")
    if p.blankGratingLobes { blankGratingLobes(&img, q) }   // q: an extrapolated band reaches higher frequencies
    return (img, k)
}

/// Widest angle off broadside (from the aperture centre) free of grating lobes. Positions dx apart alias a
/// scatterer at theta_s to sin(theta) = sin(theta_s) +/- lambda/(2 dx); a region |theta| <= theta_max contains
/// no aliases of scatterers inside it when sin(theta_max) <= lambda/(4 dx). The shortest wavelength (f stop)
/// is the worst case. 2-inch spacing at 2590 MHz: 34.8 deg.
func gratingLobeFreeAngle(_ p: SARParams) -> Double {
    let lambdaMin = speedOfLight / (p.fStopMHz * 1e6)
    return asin(min(1, lambdaMin / (4 * p.deltaX)))
}

/// Sets pixels beyond the grating-lobe-free angle to -infinity (drawn in the bottom colour, dark blue).
func blankGratingLobes(_ img: inout SARImage, _ p: SARParams) {
    let sinMax = sin(gratingLobeFreeAngle(p))
    guard sinMax < 1 else { return }
    let ys = linspace(img.downRange.0, img.downRange.1, img.rows), xs = linspace(img.crossRange.0, img.crossRange.1, img.cols)
    for r in 0..<img.rows {
        for c in 0..<img.cols {
            let x = xs[c], y = ys[r]
            let R = (x * x + y * y).squareRoot()
            if R > 0 && abs(x) / R > sinMax { img.db[r * img.cols + c] = -.infinity }
        }
    }
    img.maxDB = Double(img.db.max() ?? 0)
}

// MARK: - Matrix pencil super-resolution

/// Range super-resolution by bandwidth extrapolation. At every aperture position the frequency samples are a
/// sum of complex exponentials (one per scatterer, frequency = its range), as in the RTI app. A matrix pencil
/// (TLS, Hua & Sarkar; model order by ESTER or the gap rule) gives the poles; they are put on the unit circle,
/// the amplitudes are refitted by least squares, and the model extends the band on both sides to `bweFactor`
/// times its width, keeping the measured samples in the middle. Image formation then sees a wider band (finer
/// range) with the phases intact, so backprojection still adds positions coherently.
func bandwidthExtrapolate(_ d: ParsedSAR, _ p: SARParams) -> (data: ParsedSAR, params: SARParams, medianOrder: Int) {
    let M = d.positions, K = d.cols
    let E = K * max(0, p.bweFactor - 1) / 2
    let K2 = K + 2 * E
    let df = (p.fStopMHz - p.fStartMHz) / Double(K - 1)
    var out = d
    out.n = 2 * K2
    let outRe = UnsafeMutableBufferPointer<Double>.allocate(capacity: M * K2), outIm = UnsafeMutableBufferPointer<Double>.allocate(capacity: M * K2)
    let ordersBuf = UnsafeMutableBufferPointer<Int>.allocate(capacity: M)
    defer { outRe.deallocate(); outIm.deallocate(); ordersBuf.deallocate() }
    ordersBuf.initialize(repeating: 0)
    DispatchQueue.concurrentPerform(iterations: M) { ii in
        let re = Array(d.re[(ii * K)..<(ii * K + K)]), im = Array(d.im[(ii * K)..<(ii * K + K)])
        let mp = MatrixPencil(n: K, pencil: K / 3)
        var row = [Cx](repeating: .zero, count: K2)
        for k in 0..<K { row[E + k] = Cx(re[k], im[k]) }
        if let r = mp.analyze(re: re, im: im, maxOrder: max(1, p.pencilMaxTargets), thresholdDB: 40, rule: p.pencilRule,
                              pairs: false, esterThreshold: p.esterThreshold, forwardBackward: p.pencilFB), r.order > 0 {
            let poles = (0..<r.order).map { m -> Cx in let z = r.poles[m]; let a = max(1e-12, z.mag); return Cx(z.re / a, z.im / a) }
            // least-squares amplitudes on the measured samples: (V^H V) a = V^H z
            let J = poles.count
            var vhv = [Cx](repeating: .zero, count: J * J), vhz = [Cx](repeating: .zero, count: J)
            var pw = [Cx](repeating: Cx(1), count: J)
            for k in 0..<K {
                let z = Cx(re[k], im[k])
                for a in 0..<J {
                    vhz[a] = vhz[a] + pw[a].conj * z
                    for b in 0..<J { vhv[a * J + b] = vhv[a * J + b] + pw[a].conj * pw[b] }
                }
                for a in 0..<J { pw[a] = pw[a] * poles[a] }
            }
            let tr = (0..<J).reduce(0.0) { $0 + vhv[$1 * J + $1].re }
            for a in 0..<J { vhv[a * J + a] = vhv[a * J + a] + Cx(1e-10 * tr) }
            if let amp = solveComplex(vhv, vhz, n: J) {
                // extrapolate: below the band (k = -1, -2, ...) and above it (k = K, K+1, ...)
                for a in 0..<J {
                    let inv = poles[a].conj                       // 1/z on the unit circle
                    var lo = amp[a], hi = amp[a]
                    for _ in 0..<K { hi = hi * poles[a] }         // a z^K
                    for e in 0..<E {
                        lo = lo * inv                              // a z^-(e+1)
                        row[E - 1 - e] = row[E - 1 - e] + lo
                        row[E + K + e] = row[E + K + e] + hi
                        hi = hi * poles[a]
                    }
                }
            }
            ordersBuf[ii] = r.order
        }
        for k in 0..<K2 { outRe[ii * K2 + k] = row[k].re; outIm[ii * K2 + k] = row[k].im }
    }
    out.re = Array(outRe); out.im = Array(outIm)
    let orders = Array(ordersBuf)
    var q = p
    q.bpHann = false            // a window over the extended band would taper away the extrapolated samples
    q.fStartMHz = p.fStartMHz - Double(E) * df
    q.fStopMHz = p.fStopMHz + Double(E) * df
    // range migration: widen the Ky grid to the new band, keeping its spacing
    let kAdd = 4 * Double.pi * Double(E) * df * 1e6 / speedOfLight
    q.kStop = p.kStop + kAdd
    q.kStart = max(1, p.kStart - kAdd)
    q.nKy = 1 << log2Ceil(Int(Double(p.nKy) * (q.kStop - q.kStart) / (p.kStop - p.kStart)))
    return (out, q, orders.sorted()[M / 2])
}

/// Crossrange super-resolution, per pixel. Once backprojection has focused on a pixel, the positions'
/// contributions c_ii(p) are, for scatterers near p across the line of sight, close to a sum of complex
/// exponentials over the aperture: the scatterer at p itself at zero frequency, a neighbour at a frequency
/// proportional to its offset. A matrix pencil on the M contributions finds them, and the pixel keeps only
/// the power near zero frequency (amplitude-weighted lines, as in the RTI app): sum_m P_m eps^2/(w_m^2 + eps^2),
/// P_m being the component's power if it summed coherently. Pixels below the colour scale (and blanked angles)
/// are left as they are.
func crossrangePencil(bp: BPProfiles, xs: [Double], ys: [Double], re: inout [Float], im: inout [Float],
                      rows: Int, cols: Int, positions M: Int, _ p: SARParams) -> String {
    let t0 = Date()
    // threshold on the displayed (range-scaled) level
    func scale(_ x: Double, _ y: Double) -> Double {
        p.rangeScaling ? pow(p.scaleBySlantRange ? x * x + y * y : y * y, 1.5) : 1
    }
    var top = 0.0
    for r in 0..<rows { for c in 0..<cols {
        let i = r * cols + c
        top = max(top, Double(re[i] * re[i] + im[i] * im[i]) * scale(xs[c], ys[r]))
    } }
    let floorPow = top * pow(10, -p.dbRange / 10)          // below the colour scale nothing would show
    let sinMax = p.blankGratingLobes ? sin(gratingLobeFreeAngle(p)) : 2
    let eps = 2 * Double.pi / Double(M) * max(0.02, p.crossPeakWidth), eps2 = eps * eps
    var fitted = 0, orderSum = 0
    let lock = NSLock()
    re.withUnsafeMutableBufferPointer { orp in im.withUnsafeMutableBufferPointer { oip in
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let mp = MatrixPencil(n: M, pencil: max(2, M / 3))
            var cr = [Double](repeating: 0, count: M), ci = cr
            var nFit = 0, nOrd = 0
            let y = ys[r]
            for c in 0..<cols {
                let i = r * cols + c, x = xs[c]
                let a = Double(orp[i]), b = Double(oip[i])
                let pw = a * a + b * b
                guard pw * scale(x, y) >= floorPow else { continue }
                let R = (x * x + y * y).squareRoot()
                guard R > 0, abs(x) / R <= sinMax else { continue }
                for ii in 0..<M { let v = bp.contribution(ii, x: x, y: y); cr[ii] = v.0; ci[ii] = v.1 }
                guard let fit = mp.analyze(re: cr, im: ci, maxOrder: max(1, p.pencilMaxTargets), thresholdDB: 40, rule: p.pencilRule,
                                           pairs: false, esterThreshold: p.esterThreshold, forwardBackward: p.pencilFB), fit.order > 0 else { continue }
                var power = 0.0
                for m in 0..<fit.order {
                    let w = fit.poles[m].arg
                    power += fit.power[m] * Double(M * M) * eps2 / (w * w + eps2)
                }
                // keep the backprojected phase, set the super-resolved magnitude
                let mag = power.squareRoot(), old = pw.squareRoot()
                orp[i] = old > 0 ? Float(a / old * mag) : Float(mag)
                oip[i] = old > 0 ? Float(b / old * mag) : 0
                nFit += 1; nOrd += fit.order
            }
            lock.lock(); fitted += nFit; orderSum += nOrd; lock.unlock()
        }
    } }
    return String(format: "crossrange pencil: %d pixels, mean order %.1f (%.1f s)", fitted,
                  fitted > 0 ? Double(orderSum) / Double(fitted) : 0, Date().timeIntervalSince(t0))
}

private func formSARImageUnmasked(_ data: ParsedSAR, _ p: SARParams) -> (SARImage, DBImage?) {
    func form(_ q: SARParams) -> (SARImage, DBImage?) { q.algorithm == .rma ? formImage(data, q) : (backproject(data, q), nil) }
    guard p.sva && (p.svaMode == .dual || p.svaHannCap) else { return form(p) }
    // Unweighted range sidelobes fall off slowly (-6 dB/octave), so strong close-in returns leave radial
    // tails out to far range, where the range^(3/2) display scaling brightens them; SVA can't recognise them
    // there because the local clutter sets the local carrier. Hann's sidelobes fall off at -18 dB/octave.
    var hann = p; hann.sva = false; hann.bpHann = true
    let (rect, k) = form(p)                               // dual: unweighted; otherwise SVA
    let (h, _) = form(hann)
    var out = rect
    let gain = Float(20 * log10(2.0))                     // Hann's coherent gain is 1/2 (one dimension)
    for i in out.db.indices { out.db[i] = min(rect.db[i], h.db[i] + gain) }
    out.maxDB = Double(out.db.max() ?? 0)
    return (out, k)
}

// MARK: - Image finishing: SVA, range scaling, dB

/// For diagnostics: keep the complex image (after demodulation, before SVA) instead of applying SVA.
var svaDebugCapture = false
var debugComplex: (re: [Float], im: [Float], rows: Int, cols: Int, cr: (Double, Double), dr: (Double, Double))?

/// Optional SVA, then downrange^(3/2) scaling and dB. re/im: complex image [row][col], row 0 = nearest.
func finishImage(re: inout [Float], im: inout [Float], rows: Int, cols: Int, crossRange: (Double, Double),
                 downRange: (Double, Double), rangeOffsetFt: Double, positions M: Int, _ p: SARParams) -> SARImage {
    if svaDebugCapture { debugComplex = (re, im, rows, cols, crossRange, downRange) }
    if p.sva && p.svaMode != .dual && !svaDebugCapture { svaImage(re: &re, im: &im, rows: rows, cols: cols, crossRange: crossRange, downRange: downRange, positions: M, p) }
    var db = [Float](repeating: -400, count: rows * cols)
    let ys = linspace(downRange.0, downRange.1, rows), xs = linspace(crossRange.0, crossRange.1, cols)
    db.withUnsafeMutableBufferPointer { out in
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let y = (ys[r] - rangeOffsetFt) / feetPerMeter
            for c in 0..<cols {
                // range^(3/2): MIT scales by downrange y; the true range from the aperture centre is sqrt(x^2 + y^2),
                // which matters at wide crossrange (e.g. 224 ft, not 100 ft, at (200, 100) ft: 5 dB)
                var scale: Float = 1
                if p.rangeScaling {
                    let x = xs[c] / feetPerMeter
                    scale = Float(pow(p.scaleBySlantRange ? (x * x + y * y).squareRoot() : abs(y), 1.5))
                }
                let a = re[r * cols + c] * scale, b = im[r * cols + c] * scale
                out[r * cols + c] = 10 * log10(a * a + b * b + 1e-38)
            }
        }
    }
    return SARImage(db: db, rows: rows, cols: cols, crossRange: crossRange, downRange: downRange, maxDB: Double(db.max() ?? 0))
}

/// Spatially variant apodization (Stankwitz, Dallaire & Fienup 1995) on the complex SAR image.
/// For unweighted data the point response is a sinc whose first nulls are one Nyquist spacing away:
/// c/(2B) along the line of sight from the aperture centre, and lambda*R/(2*L*cos(theta)) across it
/// (L = aperture length, theta = squint off broadside). Both vary over the image, so for every pixel
/// the two neighbours one null away are interpolated (bilinear) along each direction in turn, and the
/// raised-cosine weight a in [0, 1/2] that minimises the output is chosen separately for I and Q:
/// y = x + a*(x(-d) + x(+d)).
func svaImage(re: inout [Float], im: inout [Float], rows: Int, cols: Int, crossRange: (Double, Double),
              downRange: (Double, Double), positions M: Int, _ p: SARParams) {
    guard rows > 2, cols > 2 else { return }
    let x0 = crossRange.0, y0 = downRange.0
    let sx = (crossRange.1 - crossRange.0) / Double(cols - 1), sy = (downRange.1 - downRange.0) / Double(rows - 1)
    let rhoR = speedOfLight / (2 * (p.fStopMHz - p.fStartMHz) * 1e6) * feetPerMeter            // ft
    let lambda = speedOfLight / ((p.fStartMHz + p.fStopMHz) / 2 * 1e6)                          // m
    let aperture = Double(M) * p.deltaX                                                          // m
    let step = max(sx, sy)
    let joint = p.svaMode == .joint
    func pass(_ src: (re: [Float], im: [Float]), along: @escaping (Double, Double) -> (Double, Double)) -> ([Float], [Float]) {
        @inline(__always) func sample(_ x: Double, _ y: Double) -> (Float, Float) {
            let fc = (x - x0) / sx, fr = (y - y0) / sy
            guard fc >= 0, fr >= 0, fc <= Double(cols - 1), fr <= Double(rows - 1) else { return (0, 0) }
            let c0 = min(cols - 2, Int(fc)), r0 = min(rows - 2, Int(fr))
            let tc = Float(fc - Double(c0)), tr = Float(fr - Double(r0))
            let i00 = r0 * cols + c0, i01 = i00 + 1, i10 = i00 + cols, i11 = i10 + 1
            let w00 = (1 - tr) * (1 - tc), w01 = (1 - tr) * tc, w10 = tr * (1 - tc), w11 = tr * tc
            return (src.re[i00] * w00 + src.re[i01] * w01 + src.re[i10] * w10 + src.re[i11] * w11,
                    src.im[i00] * w00 + src.im[i01] * w01 + src.im[i10] * w10 + src.im[i11] * w11)
        }
        // Local carrier: the phase of x(p + step*u) conj(x(p)) over one pixel step (adjacent pixels sit in the same
        // lobe, so there is no sign ambiguity; one null away a sidelobe has flipped sign), summed over a window of
        // about +/- 1.5 resolution cells (power-weighted), then scaled to the neighbour distance. Real radar data
        // keep a residual carrier (the actual sweep differs from the nominal one); SVA's rule needs baseband.
        let n = rows * cols
        let F = UnsafeMutableBufferPointer<Float>.allocate(capacity: 5 * n)       // aRe aIm bRe bIm |d|
        let D = UnsafeMutableBufferPointer<Double>.allocate(capacity: 2 * n)      // x(p+step u) x(p)*
        defer { F.deallocate(); D.deallocate() }
        DispatchQueue.concurrentPerform(iterations: rows) { r in
            let y = y0 + Double(r) * sy
            for c in 0..<cols {
                let x = x0 + Double(c) * sx
                let (dx, dy) = along(x, y)
                let a = sample(x - dx, y - dy), b = sample(x + dx, y + dy)
                let i = r * cols + c, xr = Double(src.re[i]), xi = Double(src.im[i])
                F[i] = a.0; F[n + i] = a.1; F[2 * n + i] = b.0; F[3 * n + i] = b.1
                let len = max(1e-9, (dx * dx + dy * dy).squareRoot())
                F[4 * n + i] = Float(len)
                let e = sample(x + step * dx / len, y + step * dy / len)
                D[i] = Double(e.0) * xr + Double(e.1) * xi
                D[n + i] = Double(e.1) * xr - Double(e.0) * xi
            }
        }
        let sat = SummedArea(Array(D[0..<n]), Array(D[n..<(2 * n)]), rows: rows, cols: cols)
        var oRe = src.re, oIm = src.im
        oRe.withUnsafeMutableBufferPointer { orp in oIm.withUnsafeMutableBufferPointer { oip in
            DispatchQueue.concurrentPerform(iterations: rows) { r in
                for c in 0..<cols {
                    let i = r * cols + c
                    // window about +/- 1.5 resolution cells (at least 3 ft), in pixels
                    let half = min(80, max(Int((3.0 / step).rounded()), Int((1.5 * Double(F[4 * n + i]) / step).rounded())))
                    let g = sat.sum(r, c, half)
                    let kd = atan2(g.1, g.0) / step * Double(F[4 * n + i])     // carrier phase over the distance d
                    let php = kd, phm = -kd
                    // bring both neighbours to this pixel's phase: x(+d) e^{-j php} + x(-d) e^{-j phm}
                    let cp = Float(cos(php)), sp = Float(sin(php)), cm = Float(cos(phm)), sm = Float(sin(phm))
                    let aR = F[i], aI = F[n + i], bR = F[2 * n + i], bI = F[3 * n + i]
                    let sRe = (bR * cp + bI * sp) + (aR * cm + aI * sm)
                    let sIm = (bI * cp - bR * sp) + (aI * cm - aR * sm)
                    let xr = src.re[i], xi = src.im[i]
                    if joint {
                        // one weight for the complex value: minimise |x + a s| over 0 <= a <= 1/2
                        let s2 = sRe * sRe + sIm * sIm
                        let a = s2 > 0 ? min(0.5, max(0, -(xr * sRe + xi * sIm) / s2)) : 0
                        orp[i] = xr + a * sRe; oip[i] = xi + a * sIm
                    } else {
                        orp[i] = svaPick(xr, sRe); oip[i] = svaPick(xi, sIm)
                    }
                }
            }
        } }
        return (oRe, oIm)
    }
    // along the line of sight (range), then across it (crossrange)
    let r1 = pass((re, im)) { x, y in
        let R = max(1e-6, (x * x + y * y).squareRoot())
        return (rhoR * x / R, rhoR * y / R)
    }
    let r2 = pass(r1) { x, y in
        let R = max(1e-6, (x * x + y * y).squareRoot())
        let cosT = max(0.2, y / R)
        let rho = lambda * (R / feetPerMeter) / (2 * aperture * cosT) * feetPerMeter          // ft
        return (rho * y / R, -rho * x / R)
    }
    re = r2.0; im = r2.1
}

/// Summed-area table of a complex field, for box sums of any size.
struct SummedArea {
    let rows: Int, cols: Int
    var sr: [Double], si: [Double]
    init(_ re: [Double], _ im: [Double], rows: Int, cols: Int) {
        self.rows = rows; self.cols = cols
        let w = cols + 1
        sr = [Double](repeating: 0, count: (rows + 1) * w); si = sr
        for r in 0..<rows {
            var rr = 0.0, ri = 0.0
            for c in 0..<cols {
                rr += re[r * cols + c]; ri += im[r * cols + c]
                sr[(r + 1) * w + c + 1] = sr[r * w + c + 1] + rr
                si[(r + 1) * w + c + 1] = si[r * w + c + 1] + ri
            }
        }
    }
    @inline(__always) func sum(_ r: Int, _ c: Int, _ half: Int) -> (Double, Double) {
        let w = cols + 1
        let r0 = max(0, r - half), r1 = min(rows, r + half + 1), c0 = max(0, c - half), c1 = min(cols, c + half + 1)
        return (sr[r1 * w + c1] - sr[r0 * w + c1] - sr[r1 * w + c0] + sr[r0 * w + c0],
                si[r1 * w + c1] - si[r0 * w + c1] - si[r1 * w + c0] + si[r0 * w + c0])
    }
}

/// Phase of a complex field box-summed over (2*half+1)^2 pixels (summed-area tables).
func boxPhase(_ re: [Double], _ im: [Double], rows: Int, cols: Int, half: Int) -> [Double] {
    let w = cols + 1
    var sr = [Double](repeating: 0, count: (rows + 1) * w), si = sr
    for r in 0..<rows {
        var rr = 0.0, ri = 0.0
        for c in 0..<cols {
            rr += re[r * cols + c]; ri += im[r * cols + c]
            sr[(r + 1) * w + c + 1] = sr[r * w + c + 1] + rr
            si[(r + 1) * w + c + 1] = si[r * w + c + 1] + ri
        }
    }
    var out = [Double](repeating: 0, count: rows * cols)
    for r in 0..<rows {
        let r0 = max(0, r - half), r1 = min(rows, r + half + 1)
        for c in 0..<cols {
            let c0 = max(0, c - half), c1 = min(cols, c + half + 1)
            let a = sr[r1 * w + c1] - sr[r0 * w + c1] - sr[r1 * w + c0] + sr[r0 * w + c0]
            let b = si[r1 * w + c1] - si[r0 * w + c1] - si[r1 * w + c0] + si[r0 * w + c0]
            out[r * cols + c] = atan2(b, a)
        }
    }
    return out
}

/// Minimum-magnitude x + a*s over 0 <= a <= 1/2 (as in the RTI app's SVA).
@inline(__always) func svaPick(_ x: Float, _ s: Float) -> Float {
    if x * s >= 0 { return x }                      // a = 0: rectangular
    if abs(x) >= 0.5 * abs(s) { return x + 0.5 * s } // a = 1/2: Hann
    return 0                                        // some a in (0, 1/2) nulls it
}

/// Range profile of every position (after the mean subtraction and window), for checking the data.
func rangeProfiles(_ data: ParsedSAR, _ p: SARParams) -> (DBImage, maxFt: Double) {
    let M = data.positions, nt = data.cols
    let nfft = 1 << log2Ceil(4 * nt)
    let f = FFT(log2n: log2Ceil(nfft))
    // up-chirp: beat frequency f_b = 2*R*B/(c*Tp); each bin of nfft points over Tp is c/(2B) * nt/nfft
    let bwHz = (p.fStopMHz - p.fStartMHz) * 1e6
    let ftPerBin = speedOfLight / (2 * bwHz) * Double(nt) / Double(nfft) * feetPerMeter
    let keep = min(nfft / 2, Int(ceil(p.downStopFt / ftPerBin)))
    var mean = (re: [Double](repeating: 0, count: nt), im: [Double](repeating: 0, count: nt))
    if p.subtractMean && !data.prepared {
        for r in 0..<M { for k in 0..<nt { mean.re[k] += data.re[r * nt + k] / Double(M); mean.im[k] += data.im[r * nt + k] / Double(M) } }
    }
    let h = (1...nt).map { 0.5 + 0.5 * cos(2 * Double.pi * (Double($0) - Double(nt) / 2) / Double(nt)) }
    var db = [Float](repeating: -400, count: M * keep)
    var xr = [Double](repeating: 0, count: nfft), xi = xr
    for r in 0..<M {
        for k in 0..<nfft {
            xr[k] = k < nt ? (data.re[r * nt + k] - mean.re[k]) * h[k] : 0
            xi[k] = k < nt ? (data.im[r * nt + k] - mean.im[k]) * h[k] : 0
        }
        f.run(&xr, &xi, inverse: true)
        // the Hilbert step keeps the negative-frequency half, so range is in reversed bins
        for b in 0..<keep {
            let k = (nfft - b) % nfft
            db[r * keep + b] = Float(10 * log10(xr[k] * xr[k] + xi[k] * xi[k] + 1e-300))
        }
    }
    return (DBImage(db: db, rows: M, cols: keep, maxDB: Double(db.max() ?? 0)), Double(keep) * ftPerBin)
}
