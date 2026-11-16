import Accelerate
import Foundation

// Copied from Coffee Can Radar RTI (MatrixPencil.swift) so this app stands alone.

/// How the matrix pencil chooses its model order (number of scattering centres).
enum PencilOrderRule: String, CaseIterable, Identifiable, Codable {
    case ester = "ESTER (adaptive)"
    case gap = "Largest singular-value gap (adaptive)"
    case threshold = "Singular-value threshold"
    var id: String { rawValue }
}

/// Minimal complex number for the small matrices in the matrix pencil.
struct Cx {
    var re: Double, im: Double
    init(_ re: Double, _ im: Double = 0) { self.re = re; self.im = im }
    static let zero = Cx(0)
    var conj: Cx { Cx(re, -im) }
    var abs2: Double { re * re + im * im }
    var mag: Double { abs2.squareRoot() }
    var arg: Double { atan2(im, re) }
    static func + (a: Cx, b: Cx) -> Cx { Cx(a.re + b.re, a.im + b.im) }
    static func - (a: Cx, b: Cx) -> Cx { Cx(a.re - b.re, a.im - b.im) }
    static func * (a: Cx, b: Cx) -> Cx { Cx(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    static func * (a: Double, b: Cx) -> Cx { Cx(a * b.re, a * b.im) }
    static func / (a: Cx, b: Cx) -> Cx {
        let d = b.abs2
        return Cx((a.re * b.re + a.im * b.im) / d, (a.im * b.re - a.re * b.im) / d)
    }
}

/// Solves A x = b (A n×n, row-major) by Gaussian elimination with partial pivoting.
func solveComplex(_ a: [Cx], _ b: [Cx], n: Int) -> [Cx]? {
    var a = a, b = b
    for col in 0..<n {
        var piv = col, best = a[col * n + col].abs2
        for r in (col + 1)..<max(col + 1, n) where a[r * n + col].abs2 > best { best = a[r * n + col].abs2; piv = r }
        guard best > 1e-300 else { return nil }
        if piv != col {
            for c in 0..<n { a.swapAt(col * n + c, piv * n + c) }
            b.swapAt(col, piv)
        }
        let inv = Cx(1) / a[col * n + col]
        for r in (col + 1)..<max(col + 1, n) {
            let f = a[r * n + col] * inv
            if f.abs2 == 0 { continue }
            for c in col..<n { a[r * n + c] = a[r * n + c] - f * a[col * n + c] }
            b[r] = b[r] - f * b[col]
        }
    }
    var x = [Cx](repeating: .zero, count: n)
    for r in stride(from: n - 1, through: 0, by: -1) {
        var s = b[r]
        for c in (r + 1)..<max(r + 1, n) { s = s - a[r * n + c] * x[c] }
        x[r] = s / a[r * n + r]
    }
    return x
}

/// Matrix pencil method (Hua & Sarkar, 1990) for the range profile of one pulse.
///
/// The pulse is modelled as a sum of M complex exponentials z(t) = sum_k a_k p_k^t, one per
/// target (two per target for a real pulse, a conjugate pair). With the Hankel matrix
/// Y[i, j] = z(i + j), i < N - L, j <= L, the M dominant right singular vectors W span the
/// signal space; dropping the last or first row gives W1 and W2, and the poles p_k are the
/// eigenvalues of E = pinv(W1) W2 (the TLS form, which suppresses noise). Amplitudes come
/// from a least-squares fit, and range from each pole's angle.
///
/// The pseudospectrum is 1 / sigma_min(E - z I) on the unit circle z = exp(j w): it peaks at
/// the poles, computed from the Schur form of E.
final class MatrixPencil {
    struct Result {
        var poles: [Cx]
        var amplitudes: [Cx]
        var power: [Double]          // mean |a p^t|^2 over the pulse, per pole
        var order: Int
        var singularDB: [Double]     // singular values (dB below the largest), largest first
        var schur: [Cx]              // upper-triangular Schur factor of E, row-major M×M
    }

    let n: Int
    let l: Int
    private var gram: [Double]       // column-major, interleaved complex, (L+1)²
    private var work: [Double] = []
    private var rwork: [Double] = []
    private var iwork: [__LAPACK_int] = []

    init(n: Int, pencil: Int) {
        self.n = n
        l = max(2, min(pencil, n - 2))
        gram = [Double](repeating: 0, count: 2 * (l + 1) * (l + 1))
    }

    /// Runs the pencil on z (length n). `maxOrder` caps the model order; singular values more
    /// than `thresholdDB` below the largest are treated as noise.
    func analyze(re zr: [Double], im zi: [Double], maxOrder: Int, thresholdDB: Double,
                 rule: PencilOrderRule = .threshold, pairs: Bool = false, esterThreshold: Double = 0.3,
                 forwardBackward: Bool = false) -> Result? {
        let c = l + 1, rows = n - l
        // Gram matrix G = Y^H Y, using the Hankel structure:
        // G[j+1, k+1] = G[j, k] - conj(y[j]) y[k] + conj(y[j+rows]) y[k+rows].
        // With forward-backward averaging, the Hankel matrix of the reversed, conjugated pulse
        // y_b(t) = conj(z(N-1-t)) is stacked under Y, so G = Y^H Y + Y_b^H Y_b. Undamped poles
        // are shared by both, while correlated (coherent) components are decorrelated.
        func set(_ j: Int, _ k: Int, _ v: Cx, add: Bool) {
            let i = 2 * (j + k * c)
            if add { gram[i] += v.re; gram[i + 1] += v.im } else { gram[i] = v.re; gram[i + 1] = v.im }
        }
        func z(_ t: Int) -> Cx { Cx(zr[t], zi[t]) }
        func accumulateGram(_ y: (Int) -> Cx, add: Bool) {
            var row = [Cx](repeating: .zero, count: c)          // G_y[j, k] along each diagonal
            for k in 0..<c {
                var s = Cx.zero
                for i in 0..<rows { s = s + y(i).conj * y(i + k) }
                row[k] = s
                set(0, k, s, add: add)
            }
            for d0 in 0..<c {                                   // diagonal k - j = d0
                var g = row[d0]
                for j in 0..<(c - 1 - d0) {
                    let k = j + d0
                    g = g - y(j).conj * y(k) + y(j + rows).conj * y(k + rows)
                    set(j + 1, k + 1, g, add: add)
                }
            }
        }
        accumulateGram(z, add: false)
        if forwardBackward { accumulateGram({ z(self.n - 1 - $0).conj }, add: true) }
        // Eigen-decomposition of G (ascending eigenvalues; vectors overwrite G).
        var nn = __LAPACK_int(c), info: __LAPACK_int = 0
        var lwork = __LAPACK_int(2 * c + c * c), lrwork = __LAPACK_int(1 + 5 * c + 2 * c * c), liwork = __LAPACK_int(3 + 5 * c)
        if work.count < 2 * Int(lwork) { work = [Double](repeating: 0, count: 2 * Int(lwork)) }
        if rwork.count < Int(lrwork) { rwork = [Double](repeating: 0, count: Int(lrwork)) }
        if iwork.count < Int(liwork) { iwork = [__LAPACK_int](repeating: 0, count: Int(liwork)) }
        var w = [Double](repeating: 0, count: c)
        var jobz = CChar(UInt8(ascii: "V")), uplo = CChar(UInt8(ascii: "U"))
        gram.withUnsafeMutableBytes { gp in
            work.withUnsafeMutableBytes { wp in
                zheevd_(&jobz, &uplo, &nn, OpaquePointer(gp.baseAddress!), &nn, &w, OpaquePointer(wp.baseAddress!), &lwork,
                        &rwork, &lrwork, &iwork, &liwork, &info)
            }
        }
        guard info == 0, let lmax = w.last, lmax > 0 else { return nil }
        let sv = w.reversed().map { 10 * log10(max($0, 1e-300) / lmax) }   // eigenvalues are sigma^2, so this is 20 log10(sigma/sigma_max)
        let floor = -abs(thresholdDB)
        let cap = max(1, min(maxOrder, l / 2))
        var order: Int
        switch rule {
        case .threshold:
            order = sv.filter { $0 >= floor }.count
        case .gap:
            // the largest drop (dB) between consecutive singular values, after an even count for pairs
            var best = 1, bestDrop = -Double.infinity
            for k in stride(from: pairs ? 2 : 1, through: min(cap, sv.count - 1), by: pairs ? 2 : 1) where sv[k] - sv[k - 1] < 0 {
                let drop = sv[k - 1] - sv[k]
                if drop > bestDrop { bestDrop = drop; best = k }
            }
            order = best
        case .ester:
            order = ester(cap: cap, pairs: pairs, threshold: esterThreshold)
        }
        if pairs && order % 2 == 1 { order += 1 }     // a real pulse's poles come in conjugate pairs
        order = max(pairs ? 2 : 1, min(cap, order))

        // W = conj(top `order` eigenvectors), (L+1)×M; W1 = rows 0..<L, W2 = rows 1...L.
        func wv(_ row: Int, _ col: Int) -> Cx { let i = 2 * (row + (c - 1 - col) * c); return Cx(gram[i], -gram[i + 1]) }
        let m = order
        var a11 = [Cx](repeating: .zero, count: m * m), a12 = a11
        for p in 0..<m {
            for q in 0..<m {
                var s1 = Cx.zero, s2 = Cx.zero
                for r in 0..<l {
                    let w1p = wv(r, p).conj
                    s1 = s1 + w1p * wv(r, q)
                    s2 = s2 + w1p * wv(r + 1, q)
                }
                a11[p * m + q] = s1; a12[p * m + q] = s2
            }
        }
        // E = (W1^H W1)^-1 W1^H W2, column by column
        var e = [Cx](repeating: .zero, count: m * m)
        for q in 0..<m {
            guard let col = solveComplex(a11, (0..<m).map { a12[$0 * m + q] }, n: m) else { return nil }
            for p in 0..<m { e[p * m + q] = col[p] }
        }
        guard let (t, poles) = schur(e, m) else { return nil }

        // Least-squares amplitudes: (Z^H Z) a = Z^H z, Z[t, k] = p_k^t.
        var zhz = [Cx](repeating: .zero, count: m * m), zhy = [Cx](repeating: .zero, count: m)
        var pw = [Cx](repeating: Cx(1), count: m)
        var energy = [Double](repeating: 0, count: m)
        for tt in 0..<n {
            let y = z(tt)
            for k in 0..<m {
                zhy[k] = zhy[k] + pw[k].conj * y
                energy[k] += pw[k].abs2
            }
            for p in 0..<m { for q in p..<m { zhz[p * m + q] = zhz[p * m + q] + pw[p].conj * pw[q] } }
            for k in 0..<m { pw[k] = pw[k] * poles[k] }
        }
        var trace = 0.0
        for p in 0..<m { trace += zhz[p * m + p].re; for q in 0..<p { zhz[p * m + q] = zhz[q * m + p].conj } }
        for p in 0..<m { zhz[p * m + p] = zhz[p * m + p] + Cx(1e-10 * trace / Double(m)) }
        let amps = solveComplex(zhz, zhy, n: m) ?? [Cx](repeating: .zero, count: m)
        let power = (0..<m).map { amps[$0].abs2 * energy[$0] / Double(n) }
        return Result(poles: poles, amplitudes: amps, power: power, order: m, singularDB: sv, schur: t)
    }

    /// ESTER (Badeau, David & Richard, 2006): for each candidate order p, the shift-invariance
    /// error E(p) = ||W2 - W1 pinv(W1) W2||_2 of the first p signal vectors. True signal
    /// subspaces are shift-invariant (E small); adding a noise vector breaks it. Returns the
    /// largest p with 1/E(p)^2 >= threshold * max. Uses the eigenvectors left in `gram`.
    private func ester(cap: Int, pairs: Bool, threshold: Double) -> Int {
        let c = l + 1
        func wv(_ row: Int, _ col: Int) -> Cx { let i = 2 * (row + (c - 1 - col) * c); return Cx(gram[i], -gram[i + 1]) }
        let m = cap
        var a11 = [Cx](repeating: .zero, count: m * m), a12 = a11, a22 = a11
        for p in 0..<m {
            for q in 0..<m {
                var s1 = Cx.zero, s2 = Cx.zero, s3 = Cx.zero
                for r in 0..<l {
                    let x1 = wv(r, p).conj, x2 = wv(r + 1, p).conj
                    s1 = s1 + x1 * wv(r, q); s2 = s2 + x1 * wv(r + 1, q); s3 = s3 + x2 * wv(r + 1, q)
                }
                a11[p * m + q] = s1; a12[p * m + q] = s2; a22[p * m + q] = s3
            }
        }
        var j: [(p: Int, v: Double)] = []
        for p in stride(from: pairs ? 2 : 1, through: m, by: pairs ? 2 : 1) {
            let b11 = (0..<(p * p)).map { a11[($0 / p) * m + $0 % p] }
            var phi = [Cx](repeating: .zero, count: p * p)
            var okSolve = true
            for q in 0..<p {
                guard let col = solveComplex(b11, (0..<p).map { a12[$0 * m + q] }, n: p) else { okSolve = false; break }
                for r in 0..<p { phi[r * p + q] = col[r] }
            }
            guard okSolve else { break }
            // residual Gram: A22 - A12^H Phi  (p×p, Hermitian PSD); its largest eigenvalue is E^2
            var res = [Cx](repeating: .zero, count: p * p)
            for r in 0..<p {
                for q in 0..<p {
                    var s = a22[r * m + q]
                    for k in 0..<p { s = s - a12[k * m + r].conj * phi[k * p + q] }
                    res[r * p + q] = s
                }
            }
            var v = [Cx](repeating: Cx(1), count: p), e2 = 0.0
            for _ in 0..<30 {
                var u = [Cx](repeating: .zero, count: p)
                for r in 0..<p { for q in 0..<p { u[r] = u[r] + res[r * p + q] * v[q] } }
                let nrm = u.reduce(0) { $0 + $1.abs2 }.squareRoot()
                guard nrm > 0 else { e2 = 0; break }
                e2 = nrm
                v = u.map { (1 / nrm) * $0 }
            }
            j.append((p, 1 / max(e2, 1e-30)))
        }
        guard let jmax = j.map({ $0.v }).max() else { return pairs ? 2 : 1 }
        return j.filter { $0.v >= threshold * jmax }.map { $0.p }.max() ?? (pairs ? 2 : 1)
    }

    /// Complex Schur form of a small matrix (row-major in and out) and its eigenvalues.
    private func schur(_ e: [Cx], _ m: Int) -> ([Cx], [Cx])? {
        var a = [Double](repeating: 0, count: 2 * m * m)   // column-major for LAPACK
        for r in 0..<m { for c in 0..<m { a[2 * (r + c * m)] = e[r * m + c].re; a[2 * (r + c * m) + 1] = e[r * m + c].im } }
        var jobvs = CChar(UInt8(ascii: "N")), sort = CChar(UInt8(ascii: "N"))
        var nn = __LAPACK_int(m), sdim: __LAPACK_int = 0, ldvs: __LAPACK_int = 1, info: __LAPACK_int = 0
        var lwork = __LAPACK_int(max(1, 4 * m))
        var wv = [Double](repeating: 0, count: 2 * m), vs = [Double](repeating: 0, count: 2)
        var wk = [Double](repeating: 0, count: 2 * Int(lwork)), rw = [Double](repeating: 0, count: m)
        a.withUnsafeMutableBytes { ap in wv.withUnsafeMutableBytes { wp in vs.withUnsafeMutableBytes { vp in wk.withUnsafeMutableBytes { kp in
            zgees_(&jobvs, &sort, nil, &nn, OpaquePointer(ap.baseAddress!), &nn, &sdim, OpaquePointer(wp.baseAddress!),
                   OpaquePointer(vp.baseAddress!), &ldvs, OpaquePointer(kp.baseAddress!), &lwork, &rw, nil, &info)
        } } } }
        guard info == 0 else { return nil }
        var t = [Cx](repeating: .zero, count: m * m)
        for r in 0..<m { for c in r..<m { t[r * m + c] = Cx(a[2 * (r + c * m)], a[2 * (r + c * m) + 1]) } }
        return (t, (0..<m).map { Cx(wv[2 * $0], wv[2 * $0 + 1]) })
    }

    /// sigma_min(T - z I)^2 for upper-triangular T at z = exp(j w) for each w, by inverse
    /// iteration on (A A^H)^-1 with triangular solves, warm-started from the previous point.
    static func sigmaMin2(schur t: [Cx], order m: Int, omegas: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: omegas.count)
        var x = [Cx](repeating: Cx(1 / Double(m).squareRoot()), count: m)
        var u = x, v = x
        for (i, om) in omegas.enumerated() {
            let zz = Cx(cos(om), sin(om))
            func d(_ k: Int) -> Cx { t[k * m + k] - zz }
            var est = 0.0
            for _ in 0..<3 {
                // u = A^-H x  (A^H is lower triangular)
                for r in 0..<m {
                    var s = x[r]
                    for c in 0..<r { s = s - t[c * m + r].conj * u[c] }
                    u[r] = s / d(r).conj
                }
                // v = A^-1 u  (upper triangular)
                for r in stride(from: m - 1, through: 0, by: -1) {
                    var s = u[r]
                    for c in (r + 1)..<max(r + 1, m) { s = s - t[r * m + c] * v[c] }
                    v[r] = s / d(r)
                }
                var nv = 0.0, nu = 0.0
                for k in 0..<m { nv += v[k].abs2; nu += u[k].abs2 }
                est = nu                           // x^H (A A^H)^-1 x
                let s = 1 / max(nv.squareRoot(), 1e-300)
                for k in 0..<m { x[k] = s * v[k] }
                if !nv.isFinite { break }
            }
            out[i] = est.isFinite && est > 0 ? 1 / est : 0   // infinite: z is on a pole
            if !x.allSatisfy({ $0.re.isFinite && $0.im.isFinite }) { x = [Cx](repeating: Cx(1 / Double(m).squareRoot()), count: m) }
        }
        return out
    }
}
