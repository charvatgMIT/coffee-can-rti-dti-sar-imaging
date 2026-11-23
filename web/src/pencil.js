// Coffee Can Radar web app: matrix pencil (Hua & Sarkar TLS) with ESTER / gap / threshold model order.
// Ported from MatrixPencil.swift. The Mac app uses LAPACK (zheevd, zgees); here the Hermitian
// eigenproblem is Householder tridiagonalization + implicit QL, and the Schur form is a shifted QR.
(function (C) {
  'use strict';

  // ---------- small complex helpers (values as [re, im]) ----------
  const cabs2 = (r, i) => r * r + i * i;

  /** Solves A x = b (n×n, row-major split arrays) by Gaussian elimination with partial pivoting; null if singular. */
  function solveComplex(ar0, ai0, br0, bi0, n) {
    const ar = Float64Array.from(ar0), ai = Float64Array.from(ai0), br = Float64Array.from(br0), bi = Float64Array.from(bi0);
    for (let col = 0; col < n; col++) {
      let piv = col, best = cabs2(ar[col * n + col], ai[col * n + col]);
      for (let r = col + 1; r < n; r++) { const v = cabs2(ar[r * n + col], ai[r * n + col]); if (v > best) { best = v; piv = r; } }
      if (!(best > 1e-300)) return null;
      if (piv !== col) {
        for (let c = 0; c < n; c++) {
          let t = ar[col * n + c]; ar[col * n + c] = ar[piv * n + c]; ar[piv * n + c] = t;
          t = ai[col * n + c]; ai[col * n + c] = ai[piv * n + c]; ai[piv * n + c] = t;
        }
        let t = br[col]; br[col] = br[piv]; br[piv] = t;
        t = bi[col]; bi[col] = bi[piv]; bi[piv] = t;
      }
      const pr = ar[col * n + col], pi = ai[col * n + col], pd = pr * pr + pi * pi;
      const invr = pr / pd, invi = -pi / pd;
      for (let r = col + 1; r < n; r++) {
        const xr = ar[r * n + col], xi = ai[r * n + col];
        const fr = xr * invr - xi * invi, fi = xr * invi + xi * invr;
        if (fr === 0 && fi === 0) continue;
        for (let c = col; c < n; c++) {
          const yr = ar[col * n + c], yi = ai[col * n + c];
          ar[r * n + c] -= fr * yr - fi * yi;
          ai[r * n + c] -= fr * yi + fi * yr;
        }
        br[r] -= fr * br[col] - fi * bi[col];
        bi[r] -= fr * bi[col] + fi * br[col];
      }
    }
    const xr = new Float64Array(n), xi = new Float64Array(n);
    for (let r = n - 1; r >= 0; r--) {
      let sr = br[r], si = bi[r];
      for (let c = r + 1; c < n; c++) {
        const a = ar[r * n + c], b = ai[r * n + c];
        sr -= a * xr[c] - b * xi[c];
        si -= a * xi[c] + b * xr[c];
      }
      const dr = ar[r * n + r], di = ai[r * n + r], dd = dr * dr + di * di;
      xr[r] = (sr * dr + si * di) / dd;
      xi[r] = (si * dr - sr * di) / dd;
    }
    return { re: xr, im: xi };
  }

  /**
   * Scratch space for heevTop, reused from fit to fit. Each fit used to allocate ~20 KB of temporaries;
   * in Chrome, workers of one page share the memory those come from, so parallel workers queued on it.
   */
  function heevWorkspace(n) {
    const f = () => new Float64Array(n), ff = () => new Float64Array(n * n);
    return { n, ar: ff(), ai: ff(), Vr: ff(), Vi: ff(), z: ff(), beta: f(), has: new Uint8Array(n), e: f(), d: f(), er: f(), ei: f(),
      pr: f(), pi: f(), dlr: f(), dli: f(), w: f(), order: new Int32Array(n), outR: [], outI: [] };
  }

  /**
   * Eigen-decomposition of a Hermitian n×n matrix (row-major split arrays, full).
   * Returns all eigenvalues ascending, and the eigenvectors of the `k` largest, largest first
   * (vr[j], vi[j] = eigenvector of the j-th largest eigenvalue). With a workspace `ws` the results
   * live in it and are valid until the next call with the same workspace.
   */
  function heevTop(A_r, A_i, n, k, ws) {
    if (!ws || ws.n !== n) ws = heevWorkspace(n);
    const ar = ws.ar, ai = ws.ai, Vr = ws.Vr, Vi = ws.Vi, beta = ws.beta, has = ws.has;
    ar.set(A_r); ai.set(A_i);
    const e = ws.e, d = ws.d, er = ws.er, ei = ws.ei, p_r = ws.pr, p_i = ws.pi;
    for (let kk = 0; kk < n - 2; kk++) {
      let s = 0;
      for (let i = kk + 1; i < n; i++) s += cabs2(ar[i * n + kk], ai[i * n + kk]);
      const xnorm = Math.sqrt(s);
      const x0r = ar[(kk + 1) * n + kk], x0i = ai[(kk + 1) * n + kk];
      const r0 = Math.hypot(x0r, x0i);
      if (xnorm === 0 || xnorm === r0 && s - r0 * r0 <= 0) {
        // already tridiagonal in this column
        er[kk] = x0r; ei[kk] = x0i;
        has[kk] = 0;
        continue;
      }
      const phr = r0 > 0 ? x0r / r0 : 1, phi = r0 > 0 ? x0i / r0 : 0;
      const alr = -phr * xnorm, ali = -phi * xnorm;
      const len = n - kk - 1, vo = kk * n;      // Householder vector kk in row kk of Vr/Vi
      for (let i = 0; i < len; i++) { Vr[vo + i] = ar[(kk + 1 + i) * n + kk]; Vi[vo + i] = ai[(kk + 1 + i) * n + kk]; }
      Vr[vo] -= alr; Vi[vo] -= ali;
      let vhv = 0;
      for (let i = 0; i < len; i++) vhv += Vr[vo + i] * Vr[vo + i] + Vi[vo + i] * Vi[vo + i];
      const b2 = 2 / vhv;
      // p = beta A_sub v
      for (let i = 0; i < len; i++) {
        let sr = 0, si = 0;
        const row = (kk + 1 + i) * n + kk + 1;
        for (let j = 0; j < len; j++) {
          const a = ar[row + j], b = ai[row + j];
          sr += a * Vr[vo + j] - b * Vi[vo + j];
          si += a * Vi[vo + j] + b * Vr[vo + j];
        }
        p_r[i] = b2 * sr; p_i[i] = b2 * si;
      }
      // K = beta/2 v^H p (real), q = p - K v
      let kr = 0;
      for (let i = 0; i < len; i++) kr += Vr[vo + i] * p_r[i] + Vi[vo + i] * p_i[i];
      kr *= b2 / 2;
      for (let i = 0; i < len; i++) { p_r[i] -= kr * Vr[vo + i]; p_i[i] -= kr * Vi[vo + i]; }
      // A_sub -= v q^H + q v^H
      for (let i = 0; i < len; i++) {
        const row = (kk + 1 + i) * n + kk + 1, vri = Vr[vo + i], vii = Vi[vo + i], pri = p_r[i], pii = p_i[i];
        for (let j = 0; j < len; j++) {
          // v_i conj(q_j) + q_i conj(v_j)
          ar[row + j] -= vri * p_r[j] + vii * p_i[j] + pri * Vr[vo + j] + pii * Vi[vo + j];
          ai[row + j] -= vii * p_r[j] - vri * p_i[j] + pii * Vr[vo + j] - pri * Vi[vo + j];
        }
      }
      er[kk] = alr; ei[kk] = ali;
      beta[kk] = b2; has[kk] = 1;
    }
    er[n - 2] = ar[(n - 1) * n + n - 2]; ei[n - 2] = ai[(n - 1) * n + n - 2];
    for (let i = 0; i < n; i++) d[i] = ar[i * n + i];
    // diagonal phases making the off-diagonals real and non-negative
    const dlr = ws.dlr, dli = ws.dli;
    dlr[0] = 1; dli[0] = 0;
    for (let i = 0; i < n - 1; i++) {
      const m = Math.hypot(er[i], ei[i]);
      e[i] = m;
      if (m > 0) {
        const ur = er[i] / m, ui = ei[i] / m;
        dlr[i + 1] = dlr[i] * ur - dli[i] * ui;
        dli[i + 1] = dlr[i] * ui + dli[i] * ur;
      } else { dlr[i + 1] = dlr[i]; dli[i + 1] = dli[i]; }
    }
    e[n - 1] = 0;
    const z = ws.z;
    z.fill(0);
    for (let i = 0; i < n; i++) z[i * n + i] = 1;
    if (!tql2(d, e, z, n)) return null;
    const order = ws.order;
    for (let i = 0; i < n; i++) order[i] = i;
    order.sort((a, b) => d[a] - d[b]);
    const w = ws.w;
    for (let i = 0; i < n; i++) w[i] = d[order[i]];
    const kk2 = Math.min(k, n);
    while (ws.outR.length < kk2) { ws.outR.push(new Float64Array(n)); ws.outI.push(new Float64Array(n)); }
    for (let j = 0; j < kk2; j++) {
      const col = order[n - 1 - j];
      const yr = ws.outR[j], yi = ws.outI[j];
      for (let i = 0; i < n; i++) { const zz = z[i * n + col]; yr[i] = dlr[i] * zz; yi[i] = dli[i] * zz; }
      for (let kk = n - 3; kk >= 0; kk--) {
        if (!has[kk]) continue;
        const off = kk + 1, len = n - kk - 1, vo = kk * n, b2 = beta[kk];
        let sr = 0, si = 0;   // v^H y
        for (let i = 0; i < len; i++) {
          sr += Vr[vo + i] * yr[off + i] + Vi[vo + i] * yi[off + i];
          si += Vr[vo + i] * yi[off + i] - Vi[vo + i] * yr[off + i];
        }
        sr *= b2; si *= b2;
        for (let i = 0; i < len; i++) {
          yr[off + i] -= Vr[vo + i] * sr - Vi[vo + i] * si;
          yi[off + i] -= Vr[vo + i] * si + Vi[vo + i] * sr;
        }
      }
    }
    return { w, vr: ws.outR, vi: ws.outI, k: kk2 };
  }

  /** Implicit QL for a real symmetric tridiagonal matrix (d diagonal, e[i] couples i and i+1); z gets the eigenvectors (columns). */
  function tql2(d, e, z, n) {
    for (let l = 0; l < n; l++) {
      let iter = 0, m;
      do {
        for (m = l; m < n - 1; m++) {
          const dd = Math.abs(d[m]) + Math.abs(d[m + 1]);
          if (Math.abs(e[m]) <= 2.2e-16 * dd) break;
        }
        if (m !== l) {
          if (iter++ === 60) return false;
          let g = (d[l + 1] - d[l]) / (2 * e[l]);
          let r = Math.hypot(g, 1);
          g = d[m] - d[l] + e[l] / (g + (g >= 0 ? r : -r));
          let s = 1, c = 1, p = 0, i;
          let underflow = false;
          for (i = m - 1; i >= l; i--) {
            let f = s * e[i];
            const b = c * e[i];
            r = Math.hypot(f, g);
            e[i + 1] = r;
            if (r === 0) { d[i + 1] -= p; e[m] = 0; underflow = true; break; }
            s = f / r; c = g / r;
            g = d[i + 1] - p;
            r = (d[i] - g) * s + 2 * c * b;
            p = s * r;
            d[i + 1] = g + p;
            g = c * r - b;
            for (let k = 0; k < n; k++) {
              const zi1 = k * n + i + 1, zi = k * n + i;
              f = z[zi1];
              z[zi1] = s * z[zi] + c * f;
              z[zi] = c * z[zi] - s * f;
            }
          }
          if (underflow) continue;
          d[l] -= p; e[l] = g; e[m] = 0;
        }
      } while (m !== l);
    }
    return true;
  }

  function csqrt(r, i) {
    const m = Math.hypot(r, i);
    let sr = Math.sqrt((m + r) / 2), si = Math.sqrt(Math.max(0, (m - r) / 2));
    if (i < 0) si = -si;
    return [sr, si];
  }

  /** Complex Schur form of a small general matrix (row-major split arrays): upper-triangular T and its diagonal. */
  function schur(Er, Ei, m) {
    const hr = Float64Array.from(Er), hi_ = Float64Array.from(Ei);
    // Hessenberg reduction (Householder similarity)
    for (let k = 0; k < m - 2; k++) {
      let s = 0;
      for (let i = k + 1; i < m; i++) s += cabs2(hr[i * m + k], hi_[i * m + k]);
      const xnorm = Math.sqrt(s);
      if (xnorm === 0) continue;
      const x0r = hr[(k + 1) * m + k], x0i = hi_[(k + 1) * m + k], r0 = Math.hypot(x0r, x0i);
      const phr = r0 > 0 ? x0r / r0 : 1, phi = r0 > 0 ? x0i / r0 : 0;
      const len = m - k - 1;
      const vr = new Float64Array(len), vi = new Float64Array(len);
      for (let i = 0; i < len; i++) { vr[i] = hr[(k + 1 + i) * m + k]; vi[i] = hi_[(k + 1 + i) * m + k]; }
      vr[0] += phr * xnorm; vi[0] += phi * xnorm;
      let vhv = 0;
      for (let i = 0; i < len; i++) vhv += vr[i] * vr[i] + vi[i] * vi[i];
      if (vhv === 0) continue;
      const beta = 2 / vhv;
      // left: rows k+1.., all columns from k
      for (let j = k; j < m; j++) {
        let sr = 0, si = 0;
        for (let i = 0; i < len; i++) {
          const a = hr[(k + 1 + i) * m + j], b = hi_[(k + 1 + i) * m + j];
          sr += vr[i] * a + vi[i] * b; si += vr[i] * b - vi[i] * a;
        }
        sr *= beta; si *= beta;
        for (let i = 0; i < len; i++) {
          hr[(k + 1 + i) * m + j] -= vr[i] * sr - vi[i] * si;
          hi_[(k + 1 + i) * m + j] -= vr[i] * si + vi[i] * sr;
        }
      }
      // right: columns k+1.., all rows
      for (let r = 0; r < m; r++) {
        let sr = 0, si = 0;
        for (let i = 0; i < len; i++) {
          const a = hr[r * m + k + 1 + i], b = hi_[r * m + k + 1 + i];
          sr += a * vr[i] - b * vi[i]; si += a * vi[i] + b * vr[i];
        }
        sr *= beta; si *= beta;
        for (let i = 0; i < len; i++) {
          // -= s * conj(v_i)
          hr[r * m + k + 1 + i] -= sr * vr[i] + si * vi[i];
          hi_[r * m + k + 1 + i] -= si * vr[i] - sr * vi[i];
        }
      }
      for (let i = k + 2; i < m; i++) { hr[i * m + k] = 0; hi_[i * m + k] = 0; }
    }
    // shifted QR (Givens) on the Hessenberg matrix, applied to the whole matrix so T stays a Schur form
    let hiIdx = m - 1, iter = 0, total = 0;
    const cs = new Float64Array(m), sr_ = new Float64Array(m), si_ = new Float64Array(m);
    while (hiIdx > 0) {
      let l = hiIdx;
      while (l > 0) {
        const sub = Math.hypot(hr[l * m + l - 1], hi_[l * m + l - 1]);
        const dsum = Math.hypot(hr[(l - 1) * m + l - 1], hi_[(l - 1) * m + l - 1]) + Math.hypot(hr[l * m + l], hi_[l * m + l]);
        if (sub <= 2.2e-16 * (dsum || 1)) { hr[l * m + l - 1] = 0; hi_[l * m + l - 1] = 0; break; }
        l--;
      }
      if (l === hiIdx) { hiIdx--; iter = 0; continue; }
      iter++;
      if (++total > 60 * m) return null;
      let mur, mui;
      if (iter % 11 === 10) {
        mur = hr[hiIdx * m + hiIdx] + Math.hypot(hr[hiIdx * m + hiIdx - 1], hi_[hiIdx * m + hiIdx - 1]);
        mui = hi_[hiIdx * m + hiIdx];
      } else {
        const ar = hr[(hiIdx - 1) * m + hiIdx - 1], ai = hi_[(hiIdx - 1) * m + hiIdx - 1];
        const br = hr[(hiIdx - 1) * m + hiIdx], bi = hi_[(hiIdx - 1) * m + hiIdx];
        const cr = hr[hiIdx * m + hiIdx - 1], ci = hi_[hiIdx * m + hiIdx - 1];
        const dr = hr[hiIdx * m + hiIdx], di = hi_[hiIdx * m + hiIdx];
        const tr = (ar - dr) / 2, ti = (ai - di) / 2;
        const [qr, qi] = csqrt(tr * tr - ti * ti + br * cr - bi * ci, 2 * tr * ti + br * ci + bi * cr);
        const mr = (ar + dr) / 2, mi = (ai + di) / 2;
        const m1r = mr + qr, m1i = mi + qi, m2r = mr - qr, m2i = mi - qi;
        if (cabs2(m1r - dr, m1i - di) <= cabs2(m2r - dr, m2i - di)) { mur = m1r; mui = m1i; } else { mur = m2r; mui = m2i; }
      }
      for (let k = l; k <= hiIdx; k++) { hr[k * m + k] -= mur; hi_[k * m + k] -= mui; }
      for (let k = l; k < hiIdx; k++) {
        const xr = hr[k * m + k], xi = hi_[k * m + k], yr = hr[(k + 1) * m + k], yi = hi_[(k + 1) * m + k];
        const ax = Math.hypot(xr, xi), r = Math.hypot(ax, Math.hypot(yr, yi));
        let c, s_r, s_i;
        if (r === 0) { c = 1; s_r = 0; s_i = 0; }
        else if (ax === 0) { c = 0; s_r = 1; s_i = 0; }
        else {
          c = ax / r;
          // s = (x/|x|) conj(y) / r
          const ur = xr / ax, ui = xi / ax;
          s_r = (ur * yr + ui * yi) / r; s_i = (ui * yr - ur * yi) / r;
        }
        cs[k] = c; sr_[k] = s_r; si_[k] = s_i;
        for (let j = k; j < m; j++) {
          const a_r = hr[k * m + j], a_i = hi_[k * m + j], b_r = hr[(k + 1) * m + j], b_i = hi_[(k + 1) * m + j];
          hr[k * m + j] = c * a_r + s_r * b_r - s_i * b_i;
          hi_[k * m + j] = c * a_i + s_r * b_i + s_i * b_r;
          // -conj(s) a + c b
          hr[(k + 1) * m + j] = -(s_r * a_r + s_i * a_i) + c * b_r;
          hi_[(k + 1) * m + j] = -(s_r * a_i - s_i * a_r) + c * b_i;
        }
      }
      for (let k = l; k < hiIdx; k++) {
        const c = cs[k], s_r = sr_[k], s_i = si_[k];
        const top = Math.min(k + 2, hiIdx);
        for (let i = 0; i <= top; i++) {
          const a_r = hr[i * m + k], a_i = hi_[i * m + k], b_r = hr[i * m + k + 1], b_i = hi_[i * m + k + 1];
          // col k = a c + b conj(s); col k+1 = -a s + b c
          hr[i * m + k] = a_r * c + b_r * s_r + b_i * s_i;
          hi_[i * m + k] = a_i * c + b_i * s_r - b_r * s_i;
          hr[i * m + k + 1] = -(a_r * s_r - a_i * s_i) + b_r * c;
          hi_[i * m + k + 1] = -(a_r * s_i + a_i * s_r) + b_i * c;
        }
      }
      for (let k = l; k <= hiIdx; k++) { hr[k * m + k] += mur; hi_[k * m + k] += mui; }
    }
    const pr = new Float64Array(m), pi = new Float64Array(m);
    for (let k = 0; k < m; k++) { pr[k] = hr[k * m + k]; pi[k] = hi_[k * m + k]; }
    for (let r = 1; r < m; r++) for (let c = 0; c < r; c++) { hr[r * m + c] = 0; hi_[r * m + c] = 0; }
    return { tr: hr, ti: hi_, pr, pi };
  }

  // ---------- matrix pencil ----------
  class MatrixPencil {
    constructor(n, pencil) {
      this.n = n;
      this.l = Math.max(2, Math.min(pencil, n - 2));
    }

    /**
     * Runs the pencil on z (length n). Returns {poles: [[re, im]], power, order, singularDB, schur: {tr, ti}} or null.
     * rule: 'ESTER (adaptive)' | 'Largest singular-value gap (adaptive)' | 'Singular-value threshold'.
     */
    analyze(zr, zi, maxOrder, thresholdDB, rule, pairs, esterThreshold, forwardBackward) {
      const n = this.n, l = this.l, c = l + 1, rows = n - l;
      if (!this.ws || this.ws.n !== c) { this.ws = heevWorkspace(c); this.gr = new Float64Array(c * c); this.gi = new Float64Array(c * c);
        this.rr = new Float64Array(c); this.ri = new Float64Array(c); this.br = new Float64Array(n); this.bi = new Float64Array(n); }
      const gr = this.gr, gi = this.gi;   // G[j][k], row-major, upper triangle (reused from fit to fit)
      gr.fill(0); gi.fill(0);
      const accumulate = (yr, yi) => {
        const rr = this.rr, ri = this.ri;
        for (let k = 0; k < c; k++) {
          let sr = 0, si = 0;
          for (let i = 0; i < rows; i++) {
            const ar = yr[i], ai = -yi[i], br = yr[i + k], bi = yi[i + k];
            sr += ar * br - ai * bi; si += ar * bi + ai * br;
          }
          rr[k] = sr; ri[k] = si;
          gr[k] += sr; gi[k] += si;
        }
        for (let d0 = 0; d0 < c; d0++) {
          let g_r = rr[d0], g_i = ri[d0];
          for (let j = 0; j < c - 1 - d0; j++) {
            const k = j + d0;
            // g = g - conj(y[j]) y[k] + conj(y[j+rows]) y[k+rows]
            g_r -= yr[j] * yr[k] + yi[j] * yi[k];
            g_i -= yr[j] * yi[k] - yi[j] * yr[k];
            g_r += yr[j + rows] * yr[k + rows] + yi[j + rows] * yi[k + rows];
            g_i += yr[j + rows] * yi[k + rows] - yi[j + rows] * yr[k + rows];
            gr[(j + 1) * c + k + 1] += g_r; gi[(j + 1) * c + k + 1] += g_i;
          }
        }
      };
      accumulate(zr, zi);
      if (forwardBackward) {
        const br = this.br, bi = this.bi;
        for (let t = 0; t < n; t++) { br[t] = zr[n - 1 - t]; bi[t] = -zi[n - 1 - t]; }
        accumulate(br, bi);
      }
      // full Hermitian matrix from the upper triangle
      for (let j = 0; j < c; j++) for (let k = 0; k < j; k++) { gr[j * c + k] = gr[k * c + j]; gi[j * c + k] = -gi[k * c + j]; }
      for (let j = 0; j < c; j++) gi[j * c + j] = 0;
      const cap = Math.max(1, Math.min(maxOrder, Math.floor(l / 2)));
      const eig = heevTop(gr, gi, c, cap + 1, this.ws);
      if (!eig) return null;
      const lmax = eig.w[c - 1];
      if (!(lmax > 0)) return null;
      const sv = [];
      for (let i = c - 1; i >= 0; i--) sv.push(10 * Math.log10(Math.max(eig.w[i], 1e-300) / lmax));
      // W(row, col) = conj(eigenvector of the col-th largest eigenvalue)
      const Wr = eig.vr, Wi = eig.vi;
      for (let j = 0; j < eig.k; j++) { const v = Wi[j]; for (let i = 0; i < c; i++) v[i] = -v[i]; }   // conj, in place
      const floorDB = -Math.abs(thresholdDB);
      let order;
      if (rule === 'Singular-value threshold') {
        order = sv.filter(v => v >= floorDB).length;
      } else if (rule === 'Largest singular-value gap (adaptive)') {
        let best = 1, bestDrop = -Infinity;
        for (let k = pairs ? 2 : 1; k <= Math.min(cap, sv.length - 1); k += pairs ? 2 : 1) {
          if (sv[k] - sv[k - 1] < 0) {
            const drop = sv[k - 1] - sv[k];
            if (drop > bestDrop) { bestDrop = drop; best = k; }
          }
        }
        order = best;
      } else {
        order = ester(Wr, Wi, l, cap, pairs, esterThreshold);
      }
      if (pairs && order % 2 === 1) order += 1;
      order = Math.max(pairs ? 2 : 1, Math.min(cap, order));
      const m = order;
      // A11 = W1^H W1, A12 = W1^H W2
      const a11r = new Float64Array(m * m), a11i = new Float64Array(m * m), a12r = new Float64Array(m * m), a12i = new Float64Array(m * m);
      for (let p = 0; p < m; p++) {
        for (let q = 0; q < m; q++) {
          let s1r = 0, s1i = 0, s2r = 0, s2i = 0;
          const pr = Wr[p], pi = Wi[p], qr = Wr[q], qi = Wi[q];
          for (let r = 0; r < l; r++) {
            const xr = pr[r], xi = -pi[r];   // conj(W[r][p])
            s1r += xr * qr[r] - xi * qi[r]; s1i += xr * qi[r] + xi * qr[r];
            s2r += xr * qr[r + 1] - xi * qi[r + 1]; s2i += xr * qi[r + 1] + xi * qr[r + 1];
          }
          a11r[p * m + q] = s1r; a11i[p * m + q] = s1i; a12r[p * m + q] = s2r; a12i[p * m + q] = s2i;
        }
      }
      const er = new Float64Array(m * m), ei = new Float64Array(m * m);
      for (let q = 0; q < m; q++) {
        const br = new Float64Array(m), bi = new Float64Array(m);
        for (let p = 0; p < m; p++) { br[p] = a12r[p * m + q]; bi[p] = a12i[p * m + q]; }
        const col = solveComplex(a11r, a11i, br, bi, m);
        if (!col) return null;
        for (let p = 0; p < m; p++) { er[p * m + q] = col.re[p]; ei[p * m + q] = col.im[p]; }
      }
      const sch = schur(er, ei, m);
      if (!sch) return null;
      const polesR = sch.pr, polesI = sch.pi;
      // least-squares amplitudes: (Z^H Z) a = Z^H z, Z[t][k] = p_k^t
      const zhzr = new Float64Array(m * m), zhzi = new Float64Array(m * m), zhyr = new Float64Array(m), zhyi = new Float64Array(m);
      const pwr = new Float64Array(m).fill(1), pwi = new Float64Array(m);
      const energy = new Float64Array(m);
      for (let t = 0; t < n; t++) {
        const yr = zr[t], yi = zi[t];
        for (let k = 0; k < m; k++) {
          zhyr[k] += pwr[k] * yr + pwi[k] * yi;
          zhyi[k] += pwr[k] * yi - pwi[k] * yr;
          energy[k] += pwr[k] * pwr[k] + pwi[k] * pwi[k];
        }
        for (let p = 0; p < m; p++) {
          for (let q = p; q < m; q++) {
            zhzr[p * m + q] += pwr[p] * pwr[q] + pwi[p] * pwi[q];
            zhzi[p * m + q] += pwr[p] * pwi[q] - pwi[p] * pwr[q];
          }
        }
        for (let k = 0; k < m; k++) {
          const a = pwr[k], b = pwi[k];
          pwr[k] = a * polesR[k] - b * polesI[k];
          pwi[k] = a * polesI[k] + b * polesR[k];
        }
      }
      let trace = 0;
      for (let p = 0; p < m; p++) {
        trace += zhzr[p * m + p];
        for (let q = 0; q < p; q++) { zhzr[p * m + q] = zhzr[q * m + p]; zhzi[p * m + q] = -zhzi[q * m + p]; }
      }
      for (let p = 0; p < m; p++) zhzr[p * m + p] += 1e-10 * trace / m;
      const amps = solveComplex(zhzr, zhzi, zhyr, zhyi, m) || { re: new Float64Array(m), im: new Float64Array(m) };
      const power = new Float64Array(m);
      for (let k = 0; k < m; k++) power[k] = cabs2(amps.re[k], amps.im[k]) * energy[k] / n;
      return { polesR, polesI, ampsR: amps.re, ampsI: amps.im, power, order: m, singularDB: sv, schur: { tr: sch.tr, ti: sch.ti } };
    }

    /** sigma_min(T - zI)^2 for upper-triangular T at z = e^{jw}, for each w (inverse iteration, warm start). */
    static sigmaMin2(sch, m, omegas) {
      const tr = sch.tr, ti = sch.ti;
      const out = new Float64Array(omegas.length);
      const init = 1 / Math.sqrt(m);
      const xr = new Float64Array(m).fill(init), xi = new Float64Array(m);
      const ur = new Float64Array(m), ui = new Float64Array(m), vr = new Float64Array(m), vi = new Float64Array(m);
      for (let w = 0; w < omegas.length; w++) {
        const zr = Math.cos(omegas[w]), zi = Math.sin(omegas[w]);
        let est = 0;
        for (let it = 0; it < 3; it++) {
          // u = A^-H x  (A^H lower triangular), A = T - zI
          for (let r = 0; r < m; r++) {
            let sr = xr[r], si = xi[r];
            for (let c = 0; c < r; c++) {
              // conj(t[c][r]) * u[c]
              const a = tr[c * m + r], b = -ti[c * m + r];
              sr -= a * ur[c] - b * ui[c]; si -= a * ui[c] + b * ur[c];
            }
            // divide by conj(d_r)
            const dr = tr[r * m + r] - zr, di = -(ti[r * m + r] - zi), dd = dr * dr + di * di;
            ur[r] = (sr * dr + si * di) / dd; ui[r] = (si * dr - sr * di) / dd;
          }
          // v = A^-1 u (upper triangular)
          for (let r = m - 1; r >= 0; r--) {
            let sr = ur[r], si = ui[r];
            for (let c = r + 1; c < m; c++) {
              const a = tr[r * m + c], b = ti[r * m + c];
              sr -= a * vr[c] - b * vi[c]; si -= a * vi[c] + b * vr[c];
            }
            const dr = tr[r * m + r] - zr, di = ti[r * m + r] - zi, dd = dr * dr + di * di;
            vr[r] = (sr * dr + si * di) / dd; vi[r] = (si * dr - sr * di) / dd;
          }
          let nv = 0, nu = 0;
          for (let k = 0; k < m; k++) { nv += vr[k] * vr[k] + vi[k] * vi[k]; nu += ur[k] * ur[k] + ui[k] * ui[k]; }
          est = nu;
          const s = 1 / Math.max(Math.sqrt(nv), 1e-300);
          for (let k = 0; k < m; k++) { xr[k] = s * vr[k]; xi[k] = s * vi[k]; }
          if (!isFinite(nv)) break;
        }
        out[w] = isFinite(est) && est > 0 ? 1 / est : 0;
        let ok = true;
        for (let k = 0; k < m; k++) if (!isFinite(xr[k]) || !isFinite(xi[k])) { ok = false; break; }
        if (!ok) { xr.fill(init); xi.fill(0); }
      }
      return out;
    }
  }

  /** ESTER (Badeau, David & Richard 2006): largest order whose signal subspace is still shift-invariant. */
  function ester(Wr, Wi, l, cap, pairs, threshold) {
    const m = cap;
    const a11r = new Float64Array(m * m), a11i = new Float64Array(m * m), a12r = new Float64Array(m * m), a12i = new Float64Array(m * m);
    const a22r = new Float64Array(m * m), a22i = new Float64Array(m * m);
    for (let p = 0; p < m; p++) {
      for (let q = 0; q < m; q++) {
        let s1r = 0, s1i = 0, s2r = 0, s2i = 0, s3r = 0, s3i = 0;
        const pr = Wr[p], pi = Wi[p], qr = Wr[q], qi = Wi[q];
        for (let r = 0; r < l; r++) {
          const x1r = pr[r], x1i = -pi[r], x2r = pr[r + 1], x2i = -pi[r + 1];
          s1r += x1r * qr[r] - x1i * qi[r]; s1i += x1r * qi[r] + x1i * qr[r];
          s2r += x1r * qr[r + 1] - x1i * qi[r + 1]; s2i += x1r * qi[r + 1] + x1i * qr[r + 1];
          s3r += x2r * qr[r + 1] - x2i * qi[r + 1]; s3i += x2r * qi[r + 1] + x2i * qr[r + 1];
        }
        a11r[p * m + q] = s1r; a11i[p * m + q] = s1i; a12r[p * m + q] = s2r; a12i[p * m + q] = s2i; a22r[p * m + q] = s3r; a22i[p * m + q] = s3i;
      }
    }
    const j = [];
    for (let p = pairs ? 2 : 1; p <= m; p += pairs ? 2 : 1) {
      const b11r = new Float64Array(p * p), b11i = new Float64Array(p * p);
      for (let i = 0; i < p * p; i++) { b11r[i] = a11r[Math.floor(i / p) * m + i % p]; b11i[i] = a11i[Math.floor(i / p) * m + i % p]; }
      const phr = new Float64Array(p * p), phi = new Float64Array(p * p);
      let okSolve = true;
      for (let q = 0; q < p; q++) {
        const br = new Float64Array(p), bi = new Float64Array(p);
        for (let r = 0; r < p; r++) { br[r] = a12r[r * m + q]; bi[r] = a12i[r * m + q]; }
        const col = solveComplex(b11r, b11i, br, bi, p);
        if (!col) { okSolve = false; break; }
        for (let r = 0; r < p; r++) { phr[r * p + q] = col.re[r]; phi[r * p + q] = col.im[r]; }
      }
      if (!okSolve) break;
      // residual Gram A22 - A12^H Phi
      const rr = new Float64Array(p * p), ri = new Float64Array(p * p);
      for (let r = 0; r < p; r++) {
        for (let q = 0; q < p; q++) {
          let sr = a22r[r * m + q], si = a22i[r * m + q];
          for (let k = 0; k < p; k++) {
            const ar = a12r[k * m + r], ai = -a12i[k * m + r];   // conj(A12[k][r])
            sr -= ar * phr[k * p + q] - ai * phi[k * p + q];
            si -= ar * phi[k * p + q] + ai * phr[k * p + q];
          }
          rr[r * p + q] = sr; ri[r * p + q] = si;
        }
      }
      let vr = new Float64Array(p).fill(1), vi = new Float64Array(p), e2 = 0;
      for (let it = 0; it < 30; it++) {
        const ur = new Float64Array(p), ui = new Float64Array(p);
        for (let r = 0; r < p; r++) for (let q = 0; q < p; q++) {
          const a = rr[r * p + q], b = ri[r * p + q];
          ur[r] += a * vr[q] - b * vi[q]; ui[r] += a * vi[q] + b * vr[q];
        }
        let nrm = 0;
        for (let r = 0; r < p; r++) nrm += ur[r] * ur[r] + ui[r] * ui[r];
        nrm = Math.sqrt(nrm);
        if (!(nrm > 0)) { e2 = 0; break; }
        e2 = nrm;
        for (let r = 0; r < p; r++) { ur[r] /= nrm; ui[r] /= nrm; }
        vr = ur; vi = ui;
      }
      j.push([p, 1 / Math.max(e2, 1e-30)]);
    }
    if (!j.length) return pairs ? 2 : 1;
    const jmax = Math.max(...j.map(x => x[1]));
    const ok = j.filter(x => x[1] >= threshold * jmax).map(x => x[0]);
    return ok.length ? Math.max(...ok) : (pairs ? 2 : 1);
  }

  Object.assign(C, { MatrixPencil, solveComplex, heevTop, schur });
})(globalThis.CCR = globalThis.CCR || {});
