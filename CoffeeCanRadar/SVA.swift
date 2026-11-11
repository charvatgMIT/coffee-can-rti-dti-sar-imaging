import Accelerate
import Foundation

/// Spatially variant apodization (Stankwitz, Dallaire & Fienup, 1995) along range.
///
/// SVA picks, separately for every FFT bin and separately for I and Q, the raised-cosine
/// window w(t) = 1 + 2a·cos(2π(t − c)/N), 0 ≤ a ≤ 0.5, that gives the smallest output.
/// a = 0 is rectangular (narrowest mainlobe) and a = 0.5 is Hann (lowest sidelobes), so
/// mainlobes keep close to the rectangular-window resolution while sidelobes are suppressed.
///
/// The windowed spectrum is X(k) + a·S(k), where X = FFT(z) and S = FFT(2z·cos(2π(t − c)/N)).
/// S equals the sum of X at ±1 Nyquist bin, computed exactly so any zero-padding works.
/// The input must be unwindowed; the output is the complex spectrum, length 2^log2n.
func svaSpectrum(setup: FFTSetupD, re zr: [Double], im zi: [Double], n: Int, log2n: Int)
    -> (re: [Double], im: [Double]) {
    let m = 1 << log2n
    var xr = [Double](repeating: 0, count: m), xi = xr
    var sr = xr, si = xr
    let c = Double(n - 1) / 2
    for t in 0..<min(n, zr.count) {
        let g = 2 * cos(2 * Double.pi * (Double(t) - c) / Double(n))
        xr[t] = zr[t]; xi[t] = zi[t]
        sr[t] = zr[t] * g; si[t] = zi[t] * g
    }
    fftInPlace(setup, &xr, &xi, log2n: log2n)
    fftInPlace(setup, &sr, &si, log2n: log2n)
    for k in 0..<m {
        xr[k] = svaComponent(xr[k], sr[k])
        xi[k] = svaComponent(xi[k], si[k])
    }
    return (xr, xi)
}

/// Minimum-magnitude choice of x + a·s over 0 ≤ a ≤ 0.5.
@inline(__always)
private func svaComponent(_ x: Double, _ s: Double) -> Double {
    if x * s >= 0 { return x }                          // a <= 0: rectangular
    if abs(x) >= 0.5 * abs(s) { return x + 0.5 * s }    // a >= 0.5: Hann
    return 0                                            // some a in (0, 0.5) nulls it
}
