// Coffee Can Radar web app: SAR imaging (MIT Experiment 3 parsing, range migration, AFRL backprojection,
// autofocus, SVA, matrix pencil super-resolution, grating-lobe blanking). Ported from SARProcessing.swift;
// keep them in step.
(function (C) {
  'use strict';
  const { fft, removeLinearTrend, rms, MatrixPencil, solveComplex, speedOfLight, swiftRound, sincKernel, interpolate, KH } = C;
  const FT_PER_M = 1 / 0.3048;
  const log2Ceil = n => Math.ceil(Math.log2(Math.max(2, n)));

  /** Defaults follow SBAND_RMA_opendata.m / SBAND_RMA_IFP.m and the Mac app (SARParams). */
  function sarDefaults() {
    return {
      invert: true, syncOnRight: false, tpMs: 20, trpSeconds: 0.25, fStartMHz: 2260, fStopMHz: 2590, syncThreshold: 0.08,
      alignment: 'Sub-sample edge (RTI interpolation)', interpolation: 16, holdoff: 11, chirpsPerPosition: 20,
      spacingInches: 2, fullFOV: false, subtractMean: true, mitMean: false, rsFeet: 0, zpad: 2048, kStart: 73, kStop: 108.5,
      nKy: 1024, hannAfterStolt: false, crossRangeFt: 200, downStartFt: 1, downStopFt: 350, rangeScaling: true,
      blankGratingLobes: true, scaleBySlantRange: true, dbRange: 40, algorithm: 'Backprojection (AFRL bpBasic.m)',
      bpNfft: 8192, bpPixelFt: 0.25, bpR0Ft: 0, bpHann: true, sva: false, svaMode: 'Joint I/Q', svaHannCap: true,
      superRes: 'Off', bweFactor: 3, pencilRule: 'Largest singular-value gap (adaptive)', pencilMaxTargets: 8, pencilFB: true,
      esterThreshold: 0.3, crossPeakWidth: 0.1, rangePGA: true, crossPGA: true, pgaIterations: 8,
      colorTopOffsetDB: 0,   // display only (web): top of the colour scale relative to the image's strongest pixel
    };
  }
  const MIT_ALIGN = 'Integer sample (MIT script)';
  const RMA = 'Range migration (MIT SBAND_RMA_IFP.m)';
  const deltaX = p => p.spacingInches / 12 / FT_PER_M;
  const inRange = p => p.superRes === 'Matrix pencil in range' || p.superRes === 'Matrix pencil in range and crossrange';
  const inCross = p => p.superRes === 'Matrix pencil in crossrange' || p.superRes === 'Matrix pencil in range and crossrange';

  function linspace(a, b, n) {
    const out = new Float64Array(n);
    if (n === 1) { out[0] = b; return out; }
    for (let i = 0; i < n; i++) out[i] = a + (b - a) * i / (n - 1);
    return out;
  }
  function stdDev(a) { if (!a.length) return 0; const m = a.reduce((s, v) => s + v, 0) / a.length; return Math.sqrt(a.reduce((s, v) => s + (v - m) * (v - m), 0) / a.length); }
  /** IEEE remainder (Swift's remainder): a - n*b with n = a/b rounded to nearest, ties to even. */
  function ieeeRem(a, b) {
    const q = a / b; let n = Math.round(q);
    if (Math.abs(q - Math.trunc(q)) === 0.5) n = 2 * Math.round(q / 2);
    return a - n * b;
  }

  /** Direct DFT for any length (the up-chirp is 882 samples at 44.1 kHz). Inverse scaled by 1/N (MATLAB's ifft). */
  function dft(re, im, inverse) {
    const n = re.length;
    const c = new Float64Array(n), s = new Float64Array(n);
    for (let i = 0; i < n; i++) { c[i] = Math.cos(2 * Math.PI * i / n); s[i] = (inverse ? 1 : -1) * Math.sin(2 * Math.PI * i / n); }
    const or = new Float64Array(n), oi = new Float64Array(n);
    for (let k = 0; k < n; k++) {
      let ar = 0, ai = 0, idx = 0;
      for (let t = 0; t < n; t++) {
        ar += re[t] * c[idx] - im[t] * s[idx];
        ai += re[t] * s[idx] + im[t] * c[idx];
        idx += k; if (idx >= n) idx -= n;
      }
      or[k] = inverse ? ar / n : ar; oi[k] = inverse ? ai / n : ai;
    }
    return [or, oi];
  }

  /** In-place FFT of length 2^log2n with the inverse scaled by 1/n (the Mac app's FFT class). */
  function fftScaled(re, im, log2n, inverse) {
    fft(re, im, log2n, inverse);
    if (inverse) { const s = 1 / (1 << log2n); for (let i = 0; i < (1 << log2n); i++) { re[i] *= s; im[i] *= s; } }
  }

  // ---------- SBAND_RMA_opendata.m: positions and pulses ----------
  function interpolatedEdges(rt, th, holdoff, u, last) {
    const edges = [];
    let below = 0;
    const start = KH + 2;
    if (last <= start) return edges;
    for (let i = start; i < last; i++) {
      if (rt[i] > th) {
        if (below >= holdoff) {
          let pt = i - 1, pv = rt[i - 1], tEdge = i;
          for (let j = 1; j <= u; j++) {
            const t = (i - 1) + j / u;
            const v = j === u ? rt[i] : interpolate(rt, t);
            if (v > th) { tEdge = pt + (th - pv) / (v - pv) / u; break; }
            pt = t; pv = v;
          }
          edges.push({ i, t: tEdge });
        }
        below = 0;
      } else below += 1;
    }
    return edges;
  }

  function alignedPulse(x, t0, n) {
    const n0 = Math.floor(t0), f = t0 - n0, out = new Float64Array(n);
    if (f === 0) { for (let k = 0; k < n; k++) out[k] = x[n0 + k]; return out; }
    const taps = new Float64Array(2 * KH);
    for (let m = 0; m < 2 * KH; m++) taps[m] = sincKernel(f - (m - KH + 1));
    for (let k = 0; k < n; k++) {
      let s = 0;
      const base = n0 + k - KH + 1;
      for (let m = 0; m < 2 * KH; m++) s += x[base + m] * taps[m];
      out[k] = s;
    }
    return out;
  }

  /** rec: {left, right (Float32Array), fs}. Throws Error('…') when no positions are found. */
  function parseSAR(rec, p) {
    const fs = rec.fs, sg = p.invert ? -1 : 1;
    const total = rec.left.length;
    const trig = new Float32Array(total), s = new Float32Array(total);
    const tsrc = p.syncOnRight ? rec.right : rec.left, ssrc = p.syncOnRight ? rec.left : rec.right;
    for (let i = 0; i < total; i++) { trig[i] = sg * tsrc[i]; s[i] = sg * ssrc[i]; }
    const n = Math.round(p.tpMs * 1e-3 * fs), nrp = Math.round(p.trpSeconds * fs);
    // rpstart = abs(trig) > mean(abs(trig))
    let sumAbs = 0;
    for (let i = 0; i < total; i++) sumAbs += Math.abs(trig[i]);
    const meanAbs = Math.fround(sumAbs / total);
    const rpstart = new Uint8Array(total);
    for (let i = 0; i < total; i++) rpstart[i] = Math.abs(trig[i]) > meanAbs ? 1 : 0;
    const starts = [];
    let ones = 0;
    if (total > 2 * nrp) {
      for (let i = 0; i < nrp; i++) if (rpstart[i]) ones++;
      for (let ii = nrp; ii < total - nrp; ii++) {
        if (rpstart[ii] && ones === 0) starts.push(ii);
        if (rpstart[ii]) ones++;
        if (rpstart[ii - nrp]) ones--;
      }
    }
    if (!starts.length) throw new Error('No aperture positions found. Check the sync channel, Trp and the invert setting.');
    const th = p.syncThreshold, half = Math.floor(n / 2), fixed = p.chirpsPerPosition > 0;
    const edgesPer = [], segments = [];
    starts.forEach((st, row) => {
      const end = fixed ? Math.min(row + 1 < starts.length ? starts[row + 1] : total, st + Math.floor(30 * fs)) : st + nrp;
      segments.push([st, end]);
      const rt = trig.subarray(st, end), last = rt.length - 2 * n;
      let edges = [];
      if (p.alignment !== MIT_ALIGN) {
        edges = interpolatedEdges(rt, th, p.holdoff, Math.max(10, p.interpolation), last);
      } else if (last > 11) {
        const thf = Math.fround(th);
        for (let i = 11; i < last; i++) {
          let quiet = true;
          for (let k = i - 10; k <= i - 2; k++) if (rt[k] > thf) { quiet = false; break; }
          if (!quiet) continue;
          const v = rt[i];
          let first = true;
          for (let k = i + 1; k <= i + 2 * n; k++) if (rt[k] > v) { first = false; break; }
          if (first) edges.push({ i, t: i });
        }
      }
      edgesPer.push(edges);
    });
    let k = p.chirpsPerPosition;
    let availableMin = null;
    if (fixed) {
      availableMin = Math.min(...edgesPer.map(e => Math.max(0, e.length - 1)));
      k = Math.min(k, availableMin);
      if (!(k > 0)) throw new Error('No aperture positions found. Check the sync channel, Trp and the invert setting.');
    }
    const outRe = new Float64Array(starts.length * half), outIm = new Float64Array(starts.length * half);
    const pulses = [], periodsInt = [], periodsInterp = [];
    segments.forEach(([a, b], row) => {
      const rp = s.subarray(a, b);
      const edges = fixed ? edgesPer[row].slice(0, k) : edgesPer[row];
      const sif = new Float64Array(n);
      for (const e of edges) {
        if (p.alignment !== MIT_ALIGN) { const x = alignedPulse(rp, e.t, n); for (let j = 0; j < n; j++) sif[j] += x[j]; }
        else for (let j = 0; j < n; j++) sif[j] += rp[e.i + j];
      }
      for (let j = 1; j < Math.max(1, edges.length); j++) {
        periodsInt.push(edges[j].i - edges[j - 1].i);
        if (p.alignment !== MIT_ALIGN) periodsInterp.push(edges[j].t - edges[j - 1].t);
      }
      const count = edges.length;
      pulses.push(count);
      const scaled = sif.map(v => v / count);
      const [qr, qi] = dft(scaled, new Float64Array(n), true);
      const [yr, yi] = dft(qr.slice(half, n), qi.slice(half, n), false);
      for (let j = 0; j < half; j++) {
        outRe[row * half + j] = isNaN(yr[j]) ? 1e-30 : yr[j];
        outIm[row * half + j] = isNaN(yi[j]) ? 0 : yi[j];
      }
    });
    const jitter = (a) => {
      if (a.length <= 2) return null;
      const med = a.slice().sort((x, y) => x - y)[Math.floor(a.length / 2)];
      const near = a.filter(v => Math.abs(v - med) < 0.25 * med);
      return near.length > 2 ? stdDev(near) / fs * 1e6 : null;
    };
    return {
      fs, n, positions: starts.length, pulsesPerPosition: pulses, re: outRe, im: outIm, seconds: total / fs,
      jitterIntegerUs: jitter(periodsInt), jitterInterpUs: jitter(periodsInterp), prepared: false,
      rangePhase: null, crossPhase: null, requestedChirps: p.chirpsPerPosition, availableChirpsMin: availableMin,
      get cols() { return Math.floor(this.n / 2); },
    };
  }

  // ---------- mean subtraction ----------
  function subtractApertureMean(re, im, M, nt, mit) {
    if (mit) { subtractMeanLikeMATLAB(re, im, M, nt); return; }
    for (let k = 0; k < nt; k++) {
      let mr = 0, mi = 0;
      for (let r = 0; r < M; r++) { mr += re[r * nt + k]; mi += im[r * nt + k]; }
      mr /= M; mi /= M;
      for (let r = 0; r < M; r++) { re[r * nt + k] -= mr; im[r * nt + k] -= mi; }
    }
  }
  function subtractMeanLikeMATLAB(re, im, M, nt) {
    const sr = new Float64Array(nt), si = new Float64Array(nt);
    for (let r = 0; r < M; r++) for (let k = 0; k < nt; k++) { sr[k] += re[r * nt + k]; si[k] += im[r * nt + k]; }
    for (let r = 0; r < M; r++) for (let k = 0; k < nt; k++) {
      const mr = sr[k] / M, mi = si[k] / M;
      re[r * nt + k] -= mr; im[r * nt + k] -= mi; sr[k] -= mr; si[k] -= mi;
    }
  }
  const hannN = (nt) => { const h = new Float64Array(nt); for (let i = 1; i <= nt; i++) h[i - 1] = 0.5 + 0.5 * Math.cos(2 * Math.PI * (i - nt / 2) / nt); return h; };

  // ---------- SBAND_RMA_IFP.m: range migration ----------
  const RMA_SIGNS = [1, 1, -1];
  function formImageRMA(data, p) {
    const M = data.positions, nt = data.cols;
    const re = Float64Array.from(data.re), im = Float64Array.from(data.im);
    if (p.subtractMean && !data.prepared) subtractApertureMean(re, im, M, nt, p.mitMean);
    const h = hannN(nt);
    if (!p.sva && p.bpHann) for (let r = 0; r < M; r++) for (let k = 0; k < nt; k++) { re[r * nt + k] *= h[k]; im[r * nt + k] *= h[k]; }
    const zpad = Math.max(p.zpad, 1 << log2Ceil(M)), lz = log2Ceil(zpad);
    const index = swiftRound((zpad - M) / 2);
    const Sr = new Float64Array(zpad * nt), Si = new Float64Array(zpad * nt);
    const colR = new Float64Array(zpad), colI = new Float64Array(zpad);
    for (let k = 0; k < nt; k++) {
      colR.fill(0); colI.fill(0);
      for (let r = 0; r < M; r++) { colR[index + r] = re[r * nt + k]; colI[index + r] = im[r * nt + k]; }
      fftScaled(colR, colI, lz, false);
      for (let i = 0; i < zpad; i++) { const sh = (i + zpad / 2) % zpad; Sr[sh * nt + k] = colR[i]; Si[sh * nt + k] = colI[i]; }
    }
    const dx = deltaX(p);
    const kx = linspace(-Math.PI / dx, Math.PI / dx, zpad);
    const kr = linspace(4 * Math.PI / speedOfLight * p.fStartMHz * 1e6, 4 * Math.PI / speedOfLight * p.fStopMHz * 1e6, nt);
    const rs = p.rsFeet / FT_PER_M;
    if (rs !== 0) {
      for (let i = 0; i < zpad; i++) for (let k = 0; k < nt; k++) {
        const d = kr[k] * kr[k] - kx[i] * kx[i];
        const cr = d >= 0 ? Math.cos(rs * Math.sqrt(d)) : Math.exp(-rs * Math.sqrt(-d)), ci = d >= 0 ? Math.sin(rs * Math.sqrt(d)) : 0;
        const a = Sr[i * nt + k], b = Si[i * nt + k];
        Sr[i * nt + k] = a * cr - b * ci; Si[i * nt + k] = a * ci + b * cr;
      }
    }
    const nky = p.nKy, kyEven = linspace(p.kStart, p.kStop, nky);
    const Str = new Float64Array(zpad * nky).fill(1e-30), Sti = new Float64Array(zpad * nky);
    const hk = hannN(nky), ky = new Float64Array(nt);
    for (let i = 0; i < zpad; i++) {
      for (let k = 0; k < nt; k++) ky[k] = Math.sqrt(kr[k] * kr[k] - kx[i] * kx[i]);
      let j = 0;
      for (let o = 0; o < nky; o++) {
        const y = kyEven[o];
        if (!(y >= ky[0] && y <= ky[nt - 1])) continue;
        while (j < nt - 2 && ky[j + 1] < y) j++;
        const f = (y - ky[j]) / (ky[j + 1] - ky[j]);
        const w = p.hannAfterStolt && !p.sva ? hk[o] : 1;
        Str[i * nky + o] = (Sr[i * nt + j] * (1 - f) + Sr[i * nt + j + 1] * f) * w;
        Sti[i * nky + o] = (Si[i * nt + j] * (1 - f) + Si[i * nt + j + 1] * f) * w;
      }
    }
    const kdb = new Float32Array(zpad * nky);
    let kmax = -Infinity;
    for (let i = 0; i < zpad * nky; i++) { kdb[i] = 10 * Math.log10(Str[i] * Str[i] + Sti[i] * Sti[i] + 1e-30); if (kdb[i] > kmax) kmax = kdb[i]; }
    const kSpace = { db: kdb, rows: zpad, cols: nky, maxDB: kmax };
    const m = 4 * zpad, n = 4 * nky;
    const bw = speedOfLight * (p.kStop - p.kStart) / (4 * Math.PI);
    const maxRange = speedOfLight * nky / (2 * bw) * FT_PER_M;
    const dr1 = p.downStartFt + p.rsFeet, dr2 = p.downStopFt + p.rsFeet;
    const apertureFt = zpad * dx * FT_PER_M;
    const dr1i = Math.max(1, swiftRound(dr1 / maxRange * n));
    const dr2i = Math.min(n, Math.max(dr1i, swiftRound(dr2 / maxRange * n)));
    const cr1i = Math.max(1, swiftRound((-p.crossRangeFt + apertureFt / 2) / apertureFt * m));
    const cr2i = Math.min(m, Math.max(cr1i, swiftRound((p.crossRangeFt + apertureFt / 2) / apertureFt * m)));
    const rows = dr2i - dr1i + 1, cols = cr2i - cr1i + 1;
    const k0 = n - dr2i, ln = log2Ceil(n), lm = log2Ceil(m);
    const Ar = new Float64Array(rows * zpad), Ai = new Float64Array(rows * zpad);
    const rr = new Float64Array(n), ri = new Float64Array(n);
    for (let i = 0; i < zpad; i++) {
      rr.fill(0); ri.fill(0);
      for (let k = 0; k < nky; k++) { rr[k] = Str[i * nky + k]; ri[k] = Sti[i * nky + k]; }
      fftScaled(rr, ri, ln, true);
      for (let c = 0; c < rows; c++) { Ar[c * zpad + i] = rr[k0 + c]; Ai[c * zpad + i] = ri[k0 + c]; }
    }
    const cre = new Float32Array(rows * cols), cim = new Float32Array(rows * cols);
    const xr = new Float64Array(m), xi = new Float64Array(m);
    for (let c = 0; c < rows; c++) {
      xr.fill(0); xi.fill(0);
      for (let i = 0; i < zpad; i++) { xr[i] = Ar[c * zpad + i]; xi[i] = Ai[c * zpad + i]; }
      fftScaled(xr, xi, lm, true);
      const row = dr2i - c - dr1i;
      for (let col = 0; col < cols; col++) { const x = m - (cr1i + col); cre[row * cols + col] = xr[x]; cim[row * cols + col] = xi[x]; }
    }
    const crShown = [cr1i / m * apertureFt - apertureFt / 2, cr2i / m * apertureFt - apertureFt / 2];
    if (p.sva) {
      const kc = 4 * Math.PI * (p.fStartMHz + p.fStopMHz) / 2 * 1e6 / speedOfLight;
      const ys = linspace(p.downStartFt, p.downStopFt, rows), xs = linspace(crShown[0], crShown[1], cols);
      for (let r = 0; r < rows; r++) {
        const y = ys[r] / FT_PER_M;
        for (let col = 0; col < cols; col++) {
          const x = xs[col] / FT_PER_M, R = Math.sqrt(x * x + y * y);
          const ph = RMA_SIGNS[0] * kc * R + RMA_SIGNS[1] * Math.PI / dx * x + RMA_SIGNS[2] * p.kStart * y;
          const cs = Math.fround(Math.cos(ph)), sn = Math.fround(Math.sin(ph));
          const i = r * cols + col, a = cre[i], b = cim[i];
          cre[i] = a * cs - b * sn; cim[i] = a * sn + b * cs;
        }
      }
    }
    const image = finishImage(cre, cim, rows, cols, crShown, [p.downStartFt, p.downStopFt], 0, M, p);
    return { image, kSpace };
  }

  // ---------- bpBasic.m: backprojection ----------
  const C_BP = 299792458;
  class BPProfiles {
    constructor(re, im, M, K, p, hann) {
      this.f = linspace(p.fStartMHz * 1e6, p.fStopMHz * 1e6, K);
      const deltaF = this.f[1] - this.f[0], L = deltaX(p) * M;
      this.antX = linspace(L / 2, -L / 2, M);
      this.r0 = (p.bpR0Ft > 0 ? p.bpR0Ft : (p.downStartFt + p.downStopFt) / 2) / FT_PER_M;
      this.nfft = 1 << log2Ceil(Math.max(p.bpNfft, 2 * K));
      const maxWr = C_BP / (2 * deltaF);
      this.binM = maxWr / this.nfft;
      this.rMin = -(this.nfft / 2) * this.binM; this.rMax = (this.nfft / 2 - 1) * this.binM;
      const h = new Float64Array(K);
      for (let i = 1; i <= K; i++) h[i - 1] = hann ? 0.5 + 0.5 * Math.cos(2 * Math.PI * (i - K / 2) / K) : 1;
      const nfft = this.nfft, lg = log2Ceil(nfft);
      this.rcRe = new Float64Array(M * nfft); this.rcIm = new Float64Array(M * nfft);
      const xr = new Float64Array(nfft), xi = new Float64Array(nfft);
      for (let ii = 0; ii < M; ii++) {
        xr.fill(0); xi.fill(0);
        for (let k = 0; k < K; k++) {
          const a = re[ii * K + k] * h[k], b = -im[ii * K + k] * h[k];
          const ph = 4 * Math.PI * this.f[k] * this.r0 / C_BP, cs = Math.cos(ph), sn = Math.sin(ph);
          xr[k] = a * cs - b * sn; xi[k] = a * sn + b * cs;
        }
        fftScaled(xr, xi, lg, true);
        for (let k = 0; k < nfft; k++) { const sh = (k + nfft / 2) % nfft; this.rcRe[ii * nfft + sh] = xr[k]; this.rcIm[ii * nfft + sh] = xi[k]; }
      }
      this.k4 = 4 * Math.PI * this.f[0] / C_BP;
      this.M = M;
    }
    /** Fields needed to rebuild in another worker. */
    pack() { return { f: this.f, antX: this.antX, r0: this.r0, nfft: this.nfft, binM: this.binM, rMin: this.rMin, rMax: this.rMax, rcRe: this.rcRe, rcIm: this.rcIm, k4: this.k4, M: this.M }; }
    static unpack(o) { const b = Object.create(BPProfiles.prototype); Object.assign(b, o); return b; }
    /** Contribution of position ii to the pixel (x, y) metres, into out[0], out[1]. */
    contribution(ii, x, y, out) {
      const ddx = this.antX[ii] - x, dR = Math.sqrt(ddx * ddx + y * y) - this.r0;
      out[0] = 0; out[1] = 0;
      if (!(dR > this.rMin && dR < this.rMax)) return;
      const u = dR / this.binM + this.nfft / 2, i0 = Math.trunc(u), fr = u - i0;
      if (!(i0 + 1 < this.nfft)) return;
      const base = ii * this.nfft;
      const vr = this.rcRe[base + i0] * (1 - fr) + this.rcRe[base + i0 + 1] * fr;
      const vi = this.rcIm[base + i0] * (1 - fr) + this.rcIm[base + i0 + 1] * fr;
      const ph = this.k4 * dR, cs = Math.cos(ph), sn = Math.sin(ph);
      out[0] = vr * cs - vi * sn; out[1] = vr * sn + vi * cs;
    }
  }

  /** Backprojects image rows r0 ..< r1 (the per-row work, also run in helper workers). */
  function backprojectRows(bp, xs, ys, cols, r0, r1, sva, fMid) {
    const M = bp.M, nfft = bp.nfft, out = new Float32Array((r1 - r0) * cols * 2);
    const accRe = new Float64Array(cols), accIm = new Float64Array(cols);
    for (let r = r0; r < r1; r++) {
      const y = ys[r];
      accRe.fill(0); accIm.fill(0);
      for (let ii = 0; ii < M; ii++) {
        const ax = bp.antX[ii], base = ii * nfft;
        for (let col = 0; col < cols; col++) {
          const ddx = ax - xs[col], dR = Math.sqrt(ddx * ddx + y * y) - bp.r0;
          if (!(dR > bp.rMin && dR < bp.rMax)) continue;
          const u = dR / bp.binM + nfft / 2, i0 = Math.trunc(u), fr = u - i0;
          if (!(i0 + 1 < nfft)) continue;
          const vr = bp.rcRe[base + i0] * (1 - fr) + bp.rcRe[base + i0 + 1] * fr;
          const vi = bp.rcIm[base + i0] * (1 - fr) + bp.rcIm[base + i0 + 1] * fr;
          const ph = bp.k4 * dR, cs = Math.cos(ph), sn = Math.sin(ph);
          accRe[col] += vr * cs - vi * sn;
          accIm[col] += vr * sn + vi * cs;
        }
      }
      const o = (r - r0) * cols * 2;
      for (let col = 0; col < cols; col++) {
        let a = accRe[col], b = accIm[col];
        if (sva) {
          const R = Math.sqrt(xs[col] * xs[col] + y * y), ph = -4 * Math.PI * fMid * (R - bp.r0) / C_BP;
          const cs = Math.cos(ph), sn = Math.sin(ph);
          const t = a * cs - b * sn; b = a * sn + b * cs; a = t;
        }
        out[o + col] = a; out[o + cols + col] = b;
      }
    }
    return out;
  }

  /** Runs `rowsFn(r0, r1)` over all rows, in parallel when a pool is given (async), else in this thread. */
  async function runRows(rows, pool, task, local) {
    if (!pool || pool.size < 2 || rows < 64) return [local(0, rows)];
    const chunks = Math.min(rows, pool.size * 4), step = Math.ceil(rows / chunks), jobs = [];
    for (let r0 = 0; r0 < rows; r0 += step) jobs.push(pool.run(Object.assign({}, task, { r0, r1: Math.min(rows, r0 + step) })));
    return Promise.all(jobs);
  }

  async function backproject(data, p, pool) {
    const M = data.positions, K = data.cols;
    const re = Float64Array.from(data.re), im = Float64Array.from(data.im);
    if (p.subtractMean && !data.prepared) subtractApertureMean(re, im, M, K, p.mitMean);
    const bp = new BPProfiles(re, im, M, K, p, p.bpHann && !p.sva);
    const px = Math.max(0.01, p.bpPixelFt);
    const cols = Math.max(2, swiftRound(2 * p.crossRangeFt / px) + 1);
    const rows = Math.max(2, swiftRound((p.downStopFt - p.downStartFt) / px) + 1);
    const xs = linspace(-p.crossRangeFt, p.crossRangeFt, cols).map(v => v / FT_PER_M);
    const ys = linspace(p.downStartFt, p.downStopFt, rows).map(v => v / FT_PER_M);
    const fMid = (bp.f[0] + bp.f[K - 1]) / 2;
    if (pool) pool.setShared({ bp: bp.pack(), xs, ys, cols, sva: p.sva, fMid });
    const parts = await runRows(rows, pool, { op: 'bp' }, (r0, r1) => ({ r0, r1, out: backprojectRows(bp, xs, ys, cols, r0, r1, p.sva, fMid) }));
    const cre = new Float32Array(rows * cols), cim = new Float32Array(rows * cols);
    for (const part of parts) {
      for (let r = part.r0; r < part.r1; r++) {
        const o = (r - part.r0) * cols * 2;
        cre.set(part.out.subarray(o, o + cols), r * cols);
        cim.set(part.out.subarray(o + cols, o + 2 * cols), r * cols);
      }
    }
    let note = null;
    if (inCross(p)) note = await crossrangePencil(bp, xs, ys, cre, cim, rows, cols, M, p, pool);
    const img = finishImage(cre, cim, rows, cols, [-p.crossRangeFt, p.crossRangeFt], [p.downStartFt, p.downStopFt], 0, M, p);
    img.pencilNote = note;
    return img;
  }

  // ---------- autofocus ----------
  function autofocus(data, p) {
    const d = Object.assign({}, data, { re: Float64Array.from(data.re), im: Float64Array.from(data.im) });
    Object.defineProperty(d, 'cols', { get() { return Math.floor(this.n / 2); } });
    const M = d.positions, K = d.cols;
    if (p.subtractMean) subtractApertureMean(d.re, d.im, M, K, p.mitMean);
    if (p.rangePGA) d.rangePhase = rangePGA(d.re, d.im, M, K, Math.max(1, p.pgaIterations));
    if (p.crossPGA) {
      const psi = crossAutofocus(d.re, d.im, M, K, p);
      for (let ii = 0; ii < M; ii++) {
        const cs = Math.cos(psi[ii]), sn = -Math.sin(psi[ii]);
        for (let k = 0; k < K; k++) {
          const i = ii * K + k, a = d.re[i], b = d.im[i];
          d.re[i] = a * cs - b * sn; d.im[i] = a * sn + b * cs;
        }
      }
      d.crossPhase = Array.from(psi, v => -v);
    }
    d.prepared = true;
    return d;
  }

  function rangePGA(re, im, M, K, iterations) {
    const P = 1 << log2Ceil(2 * K), lp = log2Ceil(P);
    const total = new Float64Array(K), gr = new Float64Array(P), gi = new Float64Array(P);
    const cr = Array.from({ length: M }, () => new Float64Array(P)), ci = Array.from({ length: M }, () => new Float64Array(P));
    for (let it = 0; it < iterations; it++) {
      const avg = new Float64Array(P);
      for (let r = 0; r < M; r++) {
        for (let t = 0; t < P; t++) { gr[t] = t < K ? re[r * K + t] : 0; gi[t] = t < K ? im[r * K + t] : 0; }
        fftScaled(gr, gi, lp, false);
        let q0 = 0, best = -1;
        for (let q = 0; q < P; q++) { const pw = gr[q] * gr[q] + gi[q] * gi[q]; if (pw > best) { best = pw; q0 = q; } }
        for (let q = 0; q < P; q++) { const s = (q + q0) % P; cr[r][q] = gr[s]; ci[r][q] = gi[s]; avg[q] += gr[s] * gr[s] + gi[s] * gi[s]; }
      }
      let ext = 0;
      while (ext < P / 2 - 1 && (avg[(ext + 1) % P] > 0.1 * avg[0] || avg[(P - ext - 1) % P] > 0.1 * avg[0])) ext++;
      const half = Math.min(P / 2, Math.max(3, Math.ceil(1.5 * (ext + 1))));
      const sr = new Float64Array(K), si = new Float64Array(K);
      for (let r = 0; r < M; r++) {
        for (let q = 0; q < P; q++) { const signed = q <= P / 2 ? q : q - P, keep = Math.abs(signed) <= half; gr[q] = keep ? cr[r][q] : 0; gi[q] = keep ? ci[r][q] : 0; }
        fftScaled(gr, gi, lp, true);
        for (let t = 1; t < K; t++) { sr[t] += gr[t - 1] * gr[t] + gi[t - 1] * gi[t]; si[t] += gr[t - 1] * gi[t] - gi[t - 1] * gr[t]; }
      }
      const phi = new Float64Array(K);
      for (let t = 1; t < K; t++) phi[t] = phi[t - 1] + Math.atan2(si[t], sr[t]);
      removeLinearTrend(phi);
      for (let t = 0; t < K; t++) {
        total[t] += phi[t];
        const cs = Math.cos(phi[t]), sn = -Math.sin(phi[t]);
        for (let r = 0; r < M; r++) { const i = r * K + t, a = re[i], b = im[i]; re[i] = a * cs - b * sn; im[i] = a * sn + b * cs; }
      }
      if (rms(phi) < 0.01) break;
    }
    removeLinearTrend(total);
    return Array.from(total);
  }

  function crossAutofocus(re, im, M, K, p) {
    const bp = new BPProfiles(re, im, M, K, p, true);
    const span = Math.min(p.crossRangeFt, 150), y0 = Math.max(30, p.downStartFt), y1 = p.downStopFt, step = 1;
    const nx = Math.trunc(2 * span / step) + 1, ny = Math.trunc((y1 - y0) / step) + 1;
    const mag = new Float64Array(nx * ny), v = new Float64Array(2);
    for (let r = 0; r < ny; r++) {
      const y = (y0 + r * step) / FT_PER_M;
      for (let c = 0; c < nx; c++) {
        const x = (-span + c * step) / FT_PER_M;
        let a = 0, b = 0;
        for (let ii = 0; ii < M; ii++) { bp.contribution(ii, x, y, v); a += v[0]; b += v[1]; }
        mag[r * nx + c] = a * a + b * b;
      }
    }
    const cand = [];
    for (let r = 1; r < Math.max(1, ny - 1); r++) {
      const y = y0 + r * step;
      for (let c = 1; c < Math.max(1, nx - 1); c++) {
        const i = r * nx + c, val = mag[i];
        if (val > mag[i - 1] && val >= mag[i + 1] && val > mag[i - nx] && val >= mag[i + nx]) cand.push({ x: -span + c * step, y, w: val * Math.pow(y, 3) });
      }
    }
    cand.sort((a, b) => b.w - a.w);
    const picks = [];
    for (const c of cand) {
      if (picks.length >= 200) break;
      if (!picks.some(q => Math.abs(q.x - c.x) < 3 && Math.abs(q.y - c.y) < 3)) picks.push(c);
    }
    if (picks.length < 3) return new Float64Array(M);
    const J = picks.length, cr = new Float64Array(M * J), ci = new Float64Array(M * J);
    picks.forEach((pk, j) => {
      let e = 0;
      for (let ii = 0; ii < M; ii++) { bp.contribution(ii, pk.x / FT_PER_M, pk.y / FT_PER_M, v); cr[ii * J + j] = v[0]; ci[ii * J + j] = v[1]; e += v[0] * v[0] + v[1] * v[1]; }
      const g = e > 0 ? 1 / Math.sqrt(e) : 0;
      for (let ii = 0; ii < M; ii++) { cr[ii * J + j] *= g; ci[ii * J + j] *= g; }
    });
    const psi = new Float64Array(M), Ir = new Float64Array(J), Ii = new Float64Array(J);
    for (let ii = 0; ii < M; ii++) for (let j = 0; j < J; j++) { Ir[j] += cr[ii * J + j]; Ii[j] += ci[ii * J + j]; }
    for (let it = 0; it < Math.max(1, p.pgaIterations); it++) {
      let change = 0;
      for (let ii = 0; ii < M; ii++) {
        const cs = Math.cos(psi[ii]), sn = Math.sin(psi[ii]);
        let ar = 0, ai = 0;
        for (let j = 0; j < J; j++) {
          const vr = cr[ii * J + j] * cs - ci[ii * J + j] * sn, vi = cr[ii * J + j] * sn + ci[ii * J + j] * cs;
          const orr = Ir[j] - vr, oi = Ii[j] - vi;
          ar += orr * cr[ii * J + j] + oi * ci[ii * J + j];
          ai += oi * cr[ii * J + j] - orr * ci[ii * J + j];
        }
        const nw = Math.atan2(ai, ar);
        change = Math.max(change, Math.abs(ieeeRem(nw - psi[ii], 2 * Math.PI)));
        const ncs = Math.cos(nw), nsn = Math.sin(nw);
        for (let j = 0; j < J; j++) {
          const vr = cr[ii * J + j] * cs - ci[ii * J + j] * sn, vi = cr[ii * J + j] * sn + ci[ii * J + j] * cs;
          const wr = cr[ii * J + j] * ncs - ci[ii * J + j] * nsn, wi = cr[ii * J + j] * nsn + ci[ii * J + j] * ncs;
          Ir[j] += wr - vr; Ii[j] += wi - vi;
        }
        psi[ii] = nw;
      }
      if (change < 0.01) break;
    }
    for (let ii = 1; ii < M; ii++) psi[ii] = psi[ii - 1] + ieeeRem(psi[ii] - psi[ii - 1], 2 * Math.PI);
    removeLinearTrend(psi);
    return psi;
  }

  // ---------- entry point ----------
  async function formSARImage(data, p, pool) {
    let d = data, q = p;
    const note = [];
    if (inCross(p)) q = Object.assign({}, q, { sva: false });
    if (inCross(p) && p.algorithm === RMA) note.push('crossrange pencil needs backprojection');
    if (inRange(p)) {
      const t0 = Date.now();
      const r = bandwidthExtrapolate(data, p);
      d = r.data; q = r.params;   // as the Mac app: the range step's settings (from p) replace q
      note.push(`range pencil: median order ${r.medianOrder}, band ${q.fStartMHz.toFixed(0)}–${q.fStopMHz.toFixed(0)} MHz (${((Date.now() - t0) / 1000).toFixed(2)} s)`);
    }
    const res = await formUnmasked(d, q, pool);
    if (res.image.pencilNote) note.push(res.image.pencilNote);
    res.image.pencilNote = note.length ? note.join('; ') : null;
    if (p.blankGratingLobes) blankGratingLobes(res.image, q);
    return res;
  }

  async function formUnmasked(data, p, pool) {
    const form = async q => q.algorithm === RMA ? formImageRMA(data, q) : { image: await backproject(data, q, pool), kSpace: null };
    if (!(p.sva && (p.svaMode === 'Dual apodization (rect/Hann minimum)' || p.svaHannCap))) return form(p);
    const hann = Object.assign({}, p, { sva: false, bpHann: true });
    const rect = await form(p), h = await form(hann);
    const out = rect.image, gain = Math.fround(20 * Math.log10(2));
    let mx = -Infinity;
    for (let i = 0; i < out.db.length; i++) { out.db[i] = Math.min(out.db[i], h.image.db[i] + gain); if (out.db[i] > mx) mx = out.db[i]; }
    out.maxDB = mx;
    return rect;
  }

  function gratingLobeFreeAngle(p) {
    const lambdaMin = speedOfLight / (p.fStopMHz * 1e6);
    return Math.asin(Math.min(1, lambdaMin / (4 * deltaX(p))));
  }

  function blankGratingLobes(img, p) {
    const sinMax = Math.sin(gratingLobeFreeAngle(p));
    if (!(sinMax < 1)) return;
    const ys = linspace(img.downRange[0], img.downRange[1], img.rows), xs = linspace(img.crossRange[0], img.crossRange[1], img.cols);
    let mx = -Infinity;
    for (let r = 0; r < img.rows; r++) for (let c = 0; c < img.cols; c++) {
      const x = xs[c], y = ys[r], R = Math.sqrt(x * x + y * y), i = r * img.cols + c;
      if (R > 0 && Math.abs(x) / R > sinMax) img.db[i] = -Infinity;
      if (img.db[i] > mx) mx = img.db[i];
    }
    img.maxDB = mx;
  }

  // ---------- matrix pencil super-resolution ----------
  function bandwidthExtrapolate(d, p) {
    const M = d.positions, K = d.cols;
    const E = Math.trunc(K * Math.max(0, p.bweFactor - 1) / 2), K2 = K + 2 * E;
    const df = (p.fStopMHz - p.fStartMHz) / (K - 1);
    const outRe = new Float64Array(M * K2), outIm = new Float64Array(M * K2), orders = new Array(M).fill(0);
    const mp = new MatrixPencil(K, Math.trunc(K / 3));
    for (let ii = 0; ii < M; ii++) {
      const re = d.re.subarray(ii * K, ii * K + K), im = d.im.subarray(ii * K, ii * K + K);
      const rowR = new Float64Array(K2), rowI = new Float64Array(K2);
      for (let k = 0; k < K; k++) { rowR[E + k] = re[k]; rowI[E + k] = im[k]; }
      const r = mp.analyze(re, im, Math.max(1, p.pencilMaxTargets), 40, p.pencilRule, false, p.esterThreshold, p.pencilFB);
      if (r && r.order > 0) {
        const J = r.order, pr = new Float64Array(J), pi = new Float64Array(J);
        for (let m = 0; m < J; m++) { const a = Math.max(1e-12, Math.hypot(r.polesR[m], r.polesI[m])); pr[m] = r.polesR[m] / a; pi[m] = r.polesI[m] / a; }
        const vr = new Float64Array(J * J), vi = new Float64Array(J * J), zr = new Float64Array(J), zi = new Float64Array(J);
        const wr = new Float64Array(J).fill(1), wi = new Float64Array(J);
        for (let k = 0; k < K; k++) {
          for (let a = 0; a < J; a++) {
            zr[a] += wr[a] * re[k] + wi[a] * im[k]; zi[a] += wr[a] * im[k] - wi[a] * re[k];
            for (let b = 0; b < J; b++) { vr[a * J + b] += wr[a] * wr[b] + wi[a] * wi[b]; vi[a * J + b] += wr[a] * wi[b] - wi[a] * wr[b]; }
          }
          for (let a = 0; a < J; a++) { const x = wr[a], y = wi[a]; wr[a] = x * pr[a] - y * pi[a]; wi[a] = x * pi[a] + y * pr[a]; }
        }
        let tr = 0;
        for (let a = 0; a < J; a++) tr += vr[a * J + a];
        for (let a = 0; a < J; a++) vr[a * J + a] += 1e-10 * tr;
        const amp = solveComplex(vr, vi, zr, zi, J);
        if (amp) {
          for (let a = 0; a < J; a++) {
            const ir = pr[a], ii2 = -pi[a];
            let lr = amp.re[a], li = amp.im[a], hr = amp.re[a], hi = amp.im[a];
            for (let k = 0; k < K; k++) { const x = hr, y = hi; hr = x * pr[a] - y * pi[a]; hi = x * pi[a] + y * pr[a]; }
            for (let e = 0; e < E; e++) {
              { const x = lr, y = li; lr = x * ir - y * ii2; li = x * ii2 + y * ir; }
              rowR[E - 1 - e] += lr; rowI[E - 1 - e] += li;
              rowR[E + K + e] += hr; rowI[E + K + e] += hi;
              { const x = hr, y = hi; hr = x * pr[a] - y * pi[a]; hi = x * pi[a] + y * pr[a]; }
            }
          }
        }
        orders[ii] = r.order;
      }
      outRe.set(rowR, ii * K2); outIm.set(rowI, ii * K2);
    }
    const out = Object.assign({}, d, { n: 2 * K2, re: outRe, im: outIm });
    Object.defineProperty(out, 'cols', { get() { return Math.floor(this.n / 2); } });
    const q = Object.assign({}, p, { bpHann: false, fStartMHz: p.fStartMHz - E * df, fStopMHz: p.fStopMHz + E * df });
    const kAdd = 4 * Math.PI * E * df * 1e6 / speedOfLight;
    q.kStop = p.kStop + kAdd;
    q.kStart = Math.max(1, p.kStart - kAdd);
    q.nKy = 1 << log2Ceil(Math.trunc(p.nKy * (q.kStop - q.kStart) / (p.kStop - p.kStart)));
    return { data: out, params: q, medianOrder: orders.slice().sort((a, b) => a - b)[Math.floor(M / 2)] };
  }

  const pencilScale = (p) => (x, y) => p.rangeScaling ? Math.pow(p.scaleBySlantRange ? x * x + y * y : y * y, 1.5) : 1;

  /** Crossrange pencil for rows r0 ..< r1 (also run in helper workers). Writes re/im rows in place; returns [fitted, orderSum]. */
  function crossPencilRows(bp, xs, ys, re, im, cols, r0, r1, M, p, floorPow, rowOffset) {
    const scale = pencilScale(p);
    const sinMax = p.blankGratingLobes ? Math.sin(gratingLobeFreeAngle(p)) : 2;
    const eps = 2 * Math.PI / M * Math.max(0.02, p.crossPeakWidth), eps2 = eps * eps;
    const mp = new MatrixPencil(M, Math.max(2, Math.trunc(M / 3)));
    const cr = new Float64Array(M), ci = new Float64Array(M), v = new Float64Array(2);
    let fitted = 0, orderSum = 0;
    for (let r = r0; r < r1; r++) {
      const y = ys[r];
      for (let c = 0; c < cols; c++) {
        const i = (r - rowOffset) * cols + c, x = xs[c];
        const a = re[i], b = im[i], pw = a * a + b * b;
        if (!(pw * scale(x, y) >= floorPow)) continue;
        const R = Math.sqrt(x * x + y * y);
        if (!(R > 0 && Math.abs(x) / R <= sinMax)) continue;
        for (let ii = 0; ii < M; ii++) { bp.contribution(ii, x, y, v); cr[ii] = v[0]; ci[ii] = v[1]; }
        const fit = mp.analyze(cr, ci, Math.max(1, p.pencilMaxTargets), 40, p.pencilRule, false, p.esterThreshold, p.pencilFB);
        if (!fit || fit.order <= 0) continue;
        let power = 0;
        for (let m = 0; m < fit.order; m++) { const w = Math.atan2(fit.polesI[m], fit.polesR[m]); power += fit.power[m] * M * M * eps2 / (w * w + eps2); }
        const mag = Math.sqrt(power), old = Math.sqrt(pw);
        re[i] = old > 0 ? a / old * mag : mag;
        im[i] = old > 0 ? b / old * mag : 0;
        fitted++; orderSum += fit.order;
      }
    }
    return [fitted, orderSum];
  }

  async function crossrangePencil(bp, xs, ys, re, im, rows, cols, M, p, pool) {
    const t0 = Date.now(), scale = pencilScale(p);
    let top = 0;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) { const i = r * cols + c; top = Math.max(top, (re[i] * re[i] + im[i] * im[i]) * scale(xs[c], ys[r])); }
    const floorPow = top * Math.pow(10, -p.dbRange / 10);
    let fitted = 0, orderSum = 0;
    if (pool && pool.size > 1 && rows >= 64) {
      const chunks = Math.min(rows, pool.size * 4), step = Math.ceil(rows / chunks), jobs = [];
      for (let r0 = 0; r0 < rows; r0 += step) {
        const r1 = Math.min(rows, r0 + step);
        jobs.push(pool.run({ op: 'xpencil', r0, r1, re: re.slice(r0 * cols, r1 * cols), im: im.slice(r0 * cols, r1 * cols), p, floorPow }));
      }
      for (const res of await Promise.all(jobs)) { re.set(res.re, res.r0 * cols); im.set(res.im, res.r0 * cols); fitted += res.fitted; orderSum += res.orderSum; }
    } else {
      [fitted, orderSum] = crossPencilRows(bp, xs, ys, re, im, cols, 0, rows, M, p, floorPow, 0);
    }
    return `crossrange pencil: ${fitted} pixels, mean order ${fitted ? (orderSum / fitted).toFixed(1) : '0.0'} (${((Date.now() - t0) / 1000).toFixed(1)} s)`;
  }

  // ---------- finishing: SVA, range scaling, dB ----------
  function finishImage(re, im, rows, cols, crossRange, downRange, rangeOffsetFt, M, p) {
    if (p.sva && p.svaMode !== 'Dual apodization (rect/Hann minimum)') svaImage(re, im, rows, cols, crossRange, downRange, M, p);
    const db = new Float32Array(rows * cols);
    const ys = linspace(downRange[0], downRange[1], rows), xs = linspace(crossRange[0], crossRange[1], cols);
    let mx = -Infinity;
    for (let r = 0; r < rows; r++) {
      const y = (ys[r] - rangeOffsetFt) / FT_PER_M;
      for (let c = 0; c < cols; c++) {
        let scale = 1;
        if (p.rangeScaling) { const x = xs[c] / FT_PER_M; scale = Math.fround(Math.pow(p.scaleBySlantRange ? Math.sqrt(x * x + y * y) : Math.abs(y), 1.5)); }
        const a = Math.fround(re[r * cols + c] * scale), b = Math.fround(im[r * cols + c] * scale);
        const v = 10 * Math.log10(Math.fround(Math.fround(a * a) + Math.fround(b * b)) + 1e-38);
        db[r * cols + c] = v;
        if (db[r * cols + c] > mx) mx = db[r * cols + c];
      }
    }
    return { db, rows, cols, crossRange, downRange, maxDB: mx, pencilNote: null };
  }

  class SummedArea {
    constructor(re, im, rows, cols) {
      this.rows = rows; this.cols = cols;
      const w = cols + 1;
      this.sr = new Float64Array((rows + 1) * w); this.si = new Float64Array((rows + 1) * w);
      for (let r = 0; r < rows; r++) {
        let rr = 0, ri = 0;
        for (let c = 0; c < cols; c++) {
          rr += re[r * cols + c]; ri += im[r * cols + c];
          this.sr[(r + 1) * w + c + 1] = this.sr[r * w + c + 1] + rr;
          this.si[(r + 1) * w + c + 1] = this.si[r * w + c + 1] + ri;
        }
      }
    }
    sum(r, c, half) {
      const w = this.cols + 1, sr = this.sr, si = this.si;
      const r0 = Math.max(0, r - half), r1 = Math.min(this.rows, r + half + 1), c0 = Math.max(0, c - half), c1 = Math.min(this.cols, c + half + 1);
      return [sr[r1 * w + c1] - sr[r0 * w + c1] - sr[r1 * w + c0] + sr[r0 * w + c0], si[r1 * w + c1] - si[r0 * w + c1] - si[r1 * w + c0] + si[r0 * w + c0]];
    }
  }

  function svaPick(x, s) {
    if (x * s >= 0) return x;
    if (Math.abs(x) >= 0.5 * Math.abs(s)) return x + 0.5 * s;
    return 0;
  }

  /** SVA on the complex image (Stankwitz et al.), along then across the line of sight; in place. */
  function svaImage(re, im, rows, cols, crossRange, downRange, M, p) {
    if (rows <= 2 || cols <= 2) return;
    const x0 = crossRange[0], y0 = downRange[0];
    const sx = (crossRange[1] - crossRange[0]) / (cols - 1), sy = (downRange[1] - downRange[0]) / (rows - 1);
    const rhoR = speedOfLight / (2 * (p.fStopMHz - p.fStartMHz) * 1e6) * FT_PER_M;
    const lambda = speedOfLight / ((p.fStartMHz + p.fStopMHz) / 2 * 1e6);
    const aperture = M * deltaX(p), step = Math.max(sx, sy), joint = p.svaMode === 'Joint I/Q';
    const f32 = Math.fround;
    function pass(sre, sim, along) {
      const sample = (x, y, out) => {
        const fc = (x - x0) / sx, fr = (y - y0) / sy;
        if (!(fc >= 0 && fr >= 0 && fc <= cols - 1 && fr <= rows - 1)) { out[0] = 0; out[1] = 0; return; }
        const c0 = Math.min(cols - 2, Math.trunc(fc)), r0 = Math.min(rows - 2, Math.trunc(fr));
        const tc = f32(fc - c0), tr = f32(fr - r0);
        const i00 = r0 * cols + c0, i01 = i00 + 1, i10 = i00 + cols, i11 = i10 + 1;
        const w00 = f32(f32(1 - tr) * f32(1 - tc)), w01 = f32(f32(1 - tr) * tc), w10 = f32(tr * f32(1 - tc)), w11 = f32(tr * tc);
        out[0] = f32(f32(f32(f32(sre[i00] * w00) + f32(sre[i01] * w01)) + f32(sre[i10] * w10)) + f32(sre[i11] * w11));
        out[1] = f32(f32(f32(f32(sim[i00] * w00) + f32(sim[i01] * w01)) + f32(sim[i10] * w10)) + f32(sim[i11] * w11));
      };
      const n = rows * cols;
      const F = new Float32Array(5 * n), Dr = new Float64Array(n), Di = new Float64Array(n);
      const a = new Float64Array(2), b = new Float64Array(2), e = new Float64Array(2);
      for (let r = 0; r < rows; r++) {
        const y = y0 + r * sy;
        for (let c = 0; c < cols; c++) {
          const x = x0 + c * sx, dd = along(x, y), dx = dd[0], dy = dd[1];
          sample(x - dx, y - dy, a); sample(x + dx, y + dy, b);
          const i = r * cols + c, xr = sre[i], xi = sim[i];
          F[i] = a[0]; F[n + i] = a[1]; F[2 * n + i] = b[0]; F[3 * n + i] = b[1];
          const len = Math.max(1e-9, Math.sqrt(dx * dx + dy * dy));
          F[4 * n + i] = len;
          sample(x + step * dx / len, y + step * dy / len, e);
          Dr[i] = e[0] * xr + e[1] * xi; Di[i] = e[1] * xr - e[0] * xi;
        }
      }
      const sat = new SummedArea(Dr, Di, rows, cols);
      const oRe = Float32Array.from(sre), oIm = Float32Array.from(sim);
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          const i = r * cols + c;
          const half = Math.min(80, Math.max(swiftRound(3 / step), swiftRound(1.5 * F[4 * n + i] / step)));
          const g = sat.sum(r, c, half);
          const kd = Math.atan2(g[1], g[0]) / step * F[4 * n + i];
          const cp = f32(Math.cos(kd)), sp = f32(Math.sin(kd)), cm = f32(Math.cos(-kd)), sm = f32(Math.sin(-kd));
          const aR = F[i], aI = F[n + i], bR = F[2 * n + i], bI = F[3 * n + i];
          const sRe = f32(f32(f32(bR * cp) + f32(bI * sp)) + f32(f32(aR * cm) + f32(aI * sm)));
          const sIm = f32(f32(f32(bI * cp) - f32(bR * sp)) + f32(f32(aI * cm) - f32(aR * sm)));
          const xr = sre[i], xi = sim[i];
          if (joint) {
            const s2 = f32(f32(sRe * sRe) + f32(sIm * sIm));
            const aa = s2 > 0 ? Math.min(0.5, Math.max(0, f32(-f32(f32(xr * sRe) + f32(xi * sIm)) / s2))) : 0;
            oRe[i] = f32(xr + f32(aa * sRe)); oIm[i] = f32(xi + f32(aa * sIm));
          } else { oRe[i] = svaPick(xr, sRe); oIm[i] = svaPick(xi, sIm); }
        }
      }
      return [oRe, oIm];
    }
    const r1 = pass(re, im, (x, y) => { const R = Math.max(1e-6, Math.sqrt(x * x + y * y)); return [rhoR * x / R, rhoR * y / R]; });
    const r2 = pass(r1[0], r1[1], (x, y) => {
      const R = Math.max(1e-6, Math.sqrt(x * x + y * y)), cosT = Math.max(0.2, y / R);
      const rho = lambda * (R / FT_PER_M) / (2 * aperture * cosT) * FT_PER_M;
      return [rho * y / R, -rho * x / R];
    });
    re.set(r2[0]); im.set(r2[1]);
  }

  /** Range profile of every position (after mean subtraction and window). */
  function rangeProfiles(data, p) {
    const M = data.positions, nt = data.cols, nfft = 1 << log2Ceil(4 * nt), lg = log2Ceil(nfft);
    const bwHz = (p.fStopMHz - p.fStartMHz) * 1e6;
    const ftPerBin = speedOfLight / (2 * bwHz) * nt / nfft * FT_PER_M;
    const keep = Math.min(nfft / 2, Math.ceil(p.downStopFt / ftPerBin));
    const mr = new Float64Array(nt), mi = new Float64Array(nt);
    if (p.subtractMean && !data.prepared) for (let r = 0; r < M; r++) for (let k = 0; k < nt; k++) { mr[k] += data.re[r * nt + k] / M; mi[k] += data.im[r * nt + k] / M; }
    const h = hannN(nt), db = new Float32Array(M * keep).fill(-400);
    const xr = new Float64Array(nfft), xi = new Float64Array(nfft);
    let mx = -Infinity;
    for (let r = 0; r < M; r++) {
      xr.fill(0); xi.fill(0);
      for (let k = 0; k < nt; k++) { xr[k] = (data.re[r * nt + k] - mr[k]) * h[k]; xi[k] = (data.im[r * nt + k] - mi[k]) * h[k]; }
      fftScaled(xr, xi, lg, true);
      for (let b = 0; b < keep; b++) {
        const k = (nfft - b) % nfft;
        db[r * keep + b] = 10 * Math.log10(xr[k] * xr[k] + xi[k] * xi[k] + 1e-300);
        if (db[r * keep + b] > mx) mx = db[r * keep + b];
      }
    }
    return { profiles: { db, rows: M, cols: keep, maxDB: mx }, maxFt: keep * ftPerBin };
  }

  /** The whole chain, as SARModel.process: parse (unless `parsed` is given), autofocus, image, range profiles. */
  async function processSAR(rec, p, parsed, pool) {
    const t0 = Date.now();
    const data = parsed || parseSAR(rec, p);
    const t1 = Date.now();
    const focused = autofocus(data, p);
    const { image, kSpace } = await formSARImage(focused, p, pool);
    const rp = rangeProfiles(data, p);
    const t2 = Date.now();
    return { data, focused, image, kSpace, rangeProfiles: rp.profiles, rangeProfileMaxFt: rp.maxFt, algorithm: p.algorithm,
      parseSeconds: parsed ? 0 : (t1 - t0) / 1000, imageSeconds: (t2 - t1) / 1000 };
  }

  const sameParsing = (a, b) => ['invert', 'syncOnRight', 'tpMs', 'trpSeconds', 'syncThreshold', 'alignment', 'interpolation', 'holdoff', 'chirpsPerPosition'].every(k => a[k] === b[k]);

  Object.assign(C, {
    SAR: { sarDefaults, deltaX, parseSAR, autofocus, formSARImage, rangeProfiles, processSAR, sameParsing, gratingLobeFreeAngle,
      BPProfiles, backprojectRows, crossPencilRows, FT_PER_M, RMA, MIT_ALIGN, inRange, inCross },
  });
})(globalThis.CCR = globalThis.CCR || {});
