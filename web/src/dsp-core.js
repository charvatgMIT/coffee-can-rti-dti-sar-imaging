// Coffee Can Radar web app: FFT, settings, windows, SVA and PGA.
// Ported from the Mac app (RadarParams.swift, SVA.swift, RangePGA.swift, VCO.swift); keep them in step.
(function (C) {
  'use strict';

  // ---------- FFT ----------
  const plans = new Map();
  function plan(log2n) {
    let p = plans.get(log2n);
    if (p) return p;
    const n = 1 << log2n;
    const rev = new Uint32Array(n);
    for (let i = 0; i < n; i++) {
      let r = 0, x = i;
      for (let b = 0; b < log2n; b++) { r = (r << 1) | (x & 1); x >>= 1; }
      rev[i] = r;
    }
    const cs = new Float64Array(n / 2 || 1), sn = new Float64Array(n / 2 || 1);
    for (let k = 0; k < n / 2; k++) { cs[k] = Math.cos(2 * Math.PI * k / n); sn[k] = Math.sin(2 * Math.PI * k / n); }
    p = { n, rev, cs, sn };
    plans.set(log2n, p);
    return p;
  }

  /** In-place complex FFT of the first 2^log2n values. Forward uses e^{-j}; the inverse is unscaled (as vDSP). */
  function fft(re, im, log2n, inverse) {
    const { n, rev, cs, sn } = plan(log2n);
    for (let i = 0; i < n; i++) {
      const j = rev[i];
      if (j > i) { let t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    const sg = inverse ? 1 : -1;
    for (let size = 2; size <= n; size <<= 1) {
      const half = size >> 1, step = n / size;
      for (let i = 0; i < n; i += size) {
        for (let k = 0, t = 0; k < half; k++, t += step) {
          const wr = cs[t], wi = sg * sn[t];
          const a = i + k, b = a + half;
          const xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr; im[b] = im[a] - xi;
          re[a] += xr; im[a] += xi;
        }
      }
    }
  }

  // ---------- settings ----------
  const speedOfLight = 3e8;

  /** Mini-Circuits ZX95-2536C+ typical frequency vs. tuning voltage at +25 °C. */
  const VCO = {
    name: 'Mini-Circuits ZX95-2536C+',
    curve: [[0.00, 2257.4], [0.50, 2297.3], [0.75, 2315.9], [1.00, 2334.4], [1.25, 2352.9],
      [1.50, 2371.3], [1.75, 2389.8], [2.00, 2408.5], [2.25, 2427.0], [2.50, 2445.3],
      [2.75, 2463.3], [3.00, 2481.0], [3.25, 2498.1], [3.50, 2514.5], [3.75, 2529.8],
      [4.00, 2544.2], [4.25, 2557.6], [4.50, 2570.1], [4.75, 2581.5], [5.00, 2591.8]],
    get minMHz() { return this.curve[0][1]; },
    get maxMHz() { return this.curve[this.curve.length - 1][1]; },
    volts(f) {
      const c = this.curve;
      const hi = c.findIndex(p => p[1] >= f);
      if (hi < 0) return null;
      if (hi === 0) return f === c[0][1] ? c[0][0] : null;
      const a = c[hi - 1], b = c[hi];
      return a[0] + (f - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
    },
  };

  const BANDS = {
    'Full VCO range (0–5 V)': [VCO.minMHz, VCO.maxMHz],
    'ISM band': [2402, 2495],
    'Custom': null,
  };

  /** Defaults follow read_data_RTI.m and the Mac app (RadarParams.swift). */
  function defaultParams() {
    return {
      tpMs: 5, band: 'Full VCO range (0–5 V)', fStartMHz: VCO.minMHz, fStopMHz: VCO.maxMHz,
      syncOnRight: false, invert: true, threshold: 0, holdoff: 11, interpolation: 16, align: true,
      background: 'Subtract mean pulse', meanLength: 200,
      window: 'Rectangular', taylorNbar: 4, taylorSidelobeDB: 30,
      rangeMethod: 'FFT', pencilDisplay: 'Pseudospectrum', pencilOrderRule: 'ESTER (adaptive)', esterThreshold: 0.3,
      autoTop: false, pencilForwardBackward: true, pencilMaxTargets: 8, pencilThresholdDB: 40, pencilL: 0, pencilPeakWidth: 1,
      svaEnabled: false, zeroPad: 4, traceAveraging: 1, peakHold: false,
      dbTop: -10, dbRange: 80, rtiDbRange: 80, maxRangeShown: 0, rtiSeconds: 30, rtiViewSeconds: 0, rangeUnit: 'Feet',
      pgaEnabled: false, pgaPulses: 64, pgaIterations: 8, pgaMinRange: 1.0, pgaMinAgreement: 0.8,
      rdEnabled: true, rdPulses: 64, rdWindow: 'Hann', rdDbRange: 40, rdRangePGA: true, rdDopplerPGA: true,
      rdSuperRes: 'Matrix pencil in range and Doppler', rdOrderRule: 'ESTER (adaptive)', rdShowScatterers: false,
      rejectGlitches: true,   // web only: skip pulses whose sync period jumps (dropped or repeated audio blocks)
      // Doppler vs. time (unmodulated CW), after read_data_doppler.m
      dtDwellMs: 250, dtCarrierMHz: 2590, dtZeroPad: 4, dtWindow: 'Rectangular', dtSVA: false, dtPGA: false,
      dtPGAMinVelocity: 1, dtMethod: 'FFT', dtOrderRule: 'ESTER (adaptive)', dtMaxTargets: 8,
      dtPencilDisplay: 'Pseudospectrum', dtMaxVelocity: 40, dtDbRange: 35, dtSubtractMean: true, dtHistorySeconds: 60,
    };
  }

  function bandMatches(name, p) {
    const r = BANDS[name];
    return !!r && Math.abs(p.fStartMHz - r[0]) < 0.05 && Math.abs(p.fStopMHz - r[1]) < 0.05;
  }

  /** Quantities that follow from the settings and the sample rate (Derived in RadarParams.swift). */
  function derived(p, fs) {
    const tp = p.tpMs * 1e-3;
    const n = Math.max(16, Math.round(tp * fs));
    const log2n = Math.ceil(Math.log2(Math.max(1, p.zeroPad) * n));
    const nfft = 1 << log2n;
    const bandwidth = Math.max(1, (p.fStopMHz - p.fStartMHz) * 1e6);
    const rangeRes = speedOfLight / (2 * bandwidth);
    const maxRange = rangeRes * n / 2;
    const metersPerBin = (fs / nfft) * speedOfLight * tp / (2 * bandwidth);
    const rShow = p.maxRangeShown > 0 ? Math.min(p.maxRangeShown, maxRange) : maxRange;
    const nBins = Math.max(2, Math.min(nfft / 2, Math.ceil(rShow / metersPerBin) + 1));
    return { fs, n, log2n, nfft, bandwidth, rangeRes, maxRange, metersPerBin, rShow, nBins };
  }

  function wavelength(p) { return speedOfLight / Math.max(1, (p.fStartMHz + p.fStopMHz) / 2 * 1e6); }

  /** As MATLAB's taylorwin(n, nbar, -sidelobeDB). */
  function taylorWindow(n, nbar, sidelobeDB) {
    nbar = Math.max(1, nbar);
    const a = Math.acosh(Math.pow(10, Math.abs(sidelobeDB) / 20)) / Math.PI;
    const sp2 = nbar * nbar / (a * a + Math.pow(nbar - 0.5, 2));
    const mi = [];
    for (let m = 1; m < Math.max(1, nbar); m++) mi.push(m);
    const fm = mi.map(m => {
      const numer = mi.reduce((acc, j) => acc * (1 - m * m / sp2 / (a * a + Math.pow(j - 0.5, 2))), 1);
      const denom = 2 * mi.filter(j => j !== m).reduce((acc, j) => acc * (1 - m * m / (j * j)), 1);
      return (m % 2 === 1 ? 1 : -1) * numer / denom;
    });
    const w = new Float64Array(n);
    for (let k = 0; k < n; k++) {
      const xi = (k - 0.5 * n + 0.5) / n;
      let s = 0;
      for (let i = 0; i < mi.length; i++) s += fm[i] * Math.cos(2 * Math.PI * mi[i] * xi);
      w[k] = 1 + 2 * s;
    }
    return w;
  }

  /** Window applied to each pulse before the FFT. `type` overrides p.window. */
  function makeWindow(p, n, type) {
    const t = type || p.window;
    const w = new Float64Array(n);
    for (let k = 0; k < n; k++) {
      const x = 2 * Math.PI * k / (n - 1);
      if (t === 'Hann') w[k] = 0.5 - 0.5 * Math.cos(x);
      else if (t === 'Blackman') w[k] = 0.42 - 0.5 * Math.cos(x) + 0.08 * Math.cos(2 * x);
      else w[k] = 1;
    }
    return t === 'Taylor' ? taylorWindow(n, p.taylorNbar, p.taylorSidelobeDB) : w;
  }

  // ---------- SVA ----------
  function svaComponent(x, s) {
    if (x * s >= 0) return x;                        // a <= 0: rectangular
    if (Math.abs(x) >= 0.5 * Math.abs(s)) return x + 0.5 * s;   // a >= 0.5: Hann
    return 0;                                        // some a in (0, 0.5) nulls it
  }

  /** Spatially variant apodization (Stankwitz et al. 1995) along range; unwindowed input, complex spectrum out. */
  function svaSpectrum(zr, zi, n, log2n) {
    const m = 1 << log2n;
    const xr = new Float64Array(m), xi = new Float64Array(m), sr = new Float64Array(m), si = new Float64Array(m);
    const c = (n - 1) / 2;
    const lim = Math.min(n, zr.length);
    for (let t = 0; t < lim; t++) {
      const g = 2 * Math.cos(2 * Math.PI * (t - c) / n);
      xr[t] = zr[t]; xi[t] = zi[t];
      sr[t] = zr[t] * g; si[t] = zi[t] * g;
    }
    fft(xr, xi, log2n);
    fft(sr, si, log2n);
    for (let k = 0; k < m; k++) { xr[k] = svaComponent(xr[k], sr[k]); xi[k] = svaComponent(xi[k], si[k]); }
    return { re: xr, im: xi };
  }

  // ---------- PGA ----------
  /** Removes the least-squares line a + b t. */
  function removeLinearTrend(x) {
    const n = x.length;
    if (n < 2) return;
    const tMean = (n - 1) / 2;
    let xMean = 0;
    for (let t = 0; t < n; t++) xMean += x[t];
    xMean /= n;
    let num = 0, den = 0;
    for (let t = 0; t < n; t++) { num += (t - tMean) * (x[t] - xMean); den += (t - tMean) * (t - tMean); }
    const b = num / den;
    for (let t = 0; t < n; t++) x[t] -= xMean + b * (t - tMean);
  }

  function rms(x) {
    if (!x.length) return 0;
    let s = 0;
    for (let i = 0; i < x.length; i++) s += x[i] * x[i];
    return Math.sqrt(s / x.length);
  }

  /** Phase gradient autofocus along fast time (range): the sweep phase error every pulse shares. */
  class RangePGA {
    constructor(n) {
      this.n = n;
      this.log2m = Math.ceil(Math.log2(n));
      this.m = 1 << this.log2m;
      this.block = [];
      this.sinceUpdate = 0;
      this.phase = null;
      this.updates = 0;
      this.accepted = 0;
      this.lastAgreement = 0;
      this.lastResidualRMS = 0;
    }

    /** Analytic signal of a real pulse (negative frequencies removed). */
    analytic(x) {
      const m = this.m, n = this.n;
      const re = new Float64Array(m), im = new Float64Array(m);
      for (let k = 0; k < Math.min(n, x.length); k++) re[k] = x[k];
      fft(re, im, this.log2m);
      for (let k = 1; k < m / 2; k++) { re[k] *= 2; im[k] *= 2; }
      for (let k = m / 2 + 1; k < m; k++) { re[k] = 0; im[k] = 0; }
      fft(re, im, this.log2m, true);
      const s = 1 / m;
      const ar = new Float64Array(n), ai = new Float64Array(n);
      for (let k = 0; k < n; k++) { ar[k] = re[k] * s; ai[k] = im[k] * s; }
      return { re: ar, im: ai };
    }

    add(a, blockSize, iterations, lo, hi, minAgreement) {
      // a copy: the caller corrects `a` in place afterwards (Swift arrays are values, so the Mac app copies too)
      this.block.push({ re: Float64Array.from(a.re), im: Float64Array.from(a.im) });
      if (this.block.length > blockSize) this.block.splice(0, this.block.length - blockSize);
      this.sinceUpdate += 1;
      if (this.block.length !== blockSize || this.sinceUpdate < Math.max(4, Math.floor(blockSize / 4))) return;
      this.sinceUpdate = 0;
      const r = this.clampBins(lo, hi);
      const half = Math.floor(this.block.length / 2);
      const estA = this.estimate(this.block.slice(0, half), iterations, r);
      const estB = this.estimate(this.block.slice(half), iterations, r);
      this.lastAgreement = correlation(estA, estB);
      const est = estA.map((v, i) => 0.5 * (v + estB[i]));
      const candidate = this.phase ? this.phase.map((v, i) => 0.5 * (v + est[i])) : est;
      this.updates += 1;
      if (this.lastAgreement >= minAgreement && this.sharpness(candidate, this.block, r) > this.sharpness(this.phase, this.block, r) * 1.001) {
        this.phase = candidate;
        this.accepted += 1;
      }
    }

    clampBins(lo0, hi0) {
      const m = this.m;
      const lo = Math.max(1, Math.min(lo0, m / 2 - 2));
      return [lo, Math.max(lo + 1, Math.min(hi0, m / 2 - 1))];
    }

    sharpness(phi, pulses, bins) {
      const m = this.m, n = this.n;
      const re = new Float64Array(m), im = new Float64Array(m);
      let total = 0;
      for (const pulse of pulses) {
        re.fill(0); im.fill(0);
        for (let t = 0; t < n; t++) {
          if (phi) {
            const c = Math.cos(phi[t]), s = Math.sin(phi[t]);
            re[t] = pulse.re[t] * c + pulse.im[t] * s;
            im[t] = pulse.im[t] * c - pulse.re[t] * s;
          } else { re[t] = pulse.re[t]; im[t] = pulse.im[t]; }
        }
        fft(re, im, this.log2m);
        let s2 = 0, s4 = 0;
        for (let k = bins[0]; k <= bins[1]; k++) { const p = re[k] * re[k] + im[k] * im[k]; s2 += p; s4 += p * p; }
        total += s2 > 0 ? s4 / (s2 * s2) : 0;
      }
      return total / Math.max(1, pulses.length);
    }

    /** Multiplies a pulse by exp(-j phase). */
    correct(a) {
      const phi = this.phase;
      if (!phi || phi.length !== a.re.length) return;
      for (let t = 0; t < phi.length; t++) {
        const c = Math.cos(phi[t]), s = Math.sin(phi[t]);
        const r = a.re[t], i = a.im[t];
        a.re[t] = r * c + i * s;
        a.im[t] = i * c - r * s;
      }
    }

    estimate(pulses, iterations, bins) {
      const m = this.m, n = this.n;
      const g = pulses.map(p => ({ re: Float64Array.from(p.re), im: Float64Array.from(p.im) }));
      const phi = new Float64Array(n);
      let width = Math.floor(m / 4);
      const re = new Float64Array(m), im = new Float64Array(m), sr = new Float64Array(m), si = new Float64Array(m);
      const lo = bins[0], hi = bins[1];
      for (let it = 0; it < Math.max(1, iterations); it++) {
        const accRe = new Float64Array(n), accIm = new Float64Array(n);
        for (const pulse of g) {
          for (let k = 0; k < m; k++) { re[k] = k < n ? pulse.re[k] : 0; im[k] = k < n ? pulse.im[k] : 0; }
          fft(re, im, this.log2m);
          for (let k = 0; k < m; k++) if (k < lo || k > hi) { re[k] = 0; im[k] = 0; }
          let kp = lo, best = -1;
          for (let k = lo; k <= hi; k++) { const p = re[k] * re[k] + im[k] * im[k]; if (p > best) { best = p; kp = k; } }
          sr.fill(0); si.fill(0);
          const half = Math.floor(width / 2);
          for (let dk = -half; dk <= half; dk++) {
            const src = ((kp + dk) % m + m) % m, dst = (dk + m) % m;
            sr[dst] = re[src]; si[dst] = im[src];
          }
          fft(sr, si, this.log2m, true);
          for (let t = 1; t < n; t++) {
            accRe[t] += sr[t] * sr[t - 1] + si[t] * si[t - 1];
            accIm[t] += si[t] * sr[t - 1] - sr[t] * si[t - 1];
          }
        }
        const residual = new Float64Array(n);
        for (let t = 1; t < n; t++) residual[t] = residual[t - 1] + Math.atan2(accIm[t], accRe[t]);
        removeLinearTrend(residual);
        for (let t = 0; t < n; t++) phi[t] += residual[t];
        for (const p of g) {
          for (let t = 0; t < n; t++) {
            const c = Math.cos(residual[t]), s = Math.sin(residual[t]);
            const r = p.re[t], i = p.im[t];
            p.re[t] = r * c + i * s;
            p.im[t] = i * c - r * s;
          }
        }
        width = Math.max(16, Math.floor(width * 0.6));
        this.lastResidualRMS = rms(residual);
        if (this.lastResidualRMS < 0.005) break;
      }
      return Array.from(phi);
    }
  }

  function correlation(a, b) {
    const n = a.length;
    let ma = 0, mb = 0;
    for (let i = 0; i < n; i++) { ma += a[i]; mb += b[i]; }
    ma /= n; mb /= n;
    let ab = 0, aa = 0, bb = 0;
    for (let i = 0; i < n; i++) { const x = a[i] - ma, y = b[i] - mb; ab += x * y; aa += x * x; bb += y * y; }
    return aa > 0 && bb > 0 ? ab / Math.sqrt(aa * bb) : 0;
  }

  /** Slow-time (Doppler) PGA on a [range bin][pulse] block, in place; returns the correction (rad). */
  function slowTimePGA(re, im, m, log2m, binLo, binHi, iterations) {
    const total = new Float64Array(m);
    if (binHi <= binLo || m < 8) return total;
    const bins = [];
    for (let kb = binLo; kb < binHi; kb++) bins.push(kb);
    const energy = bins.map(kb => { let e = 0; for (let j = 0; j < m; j++) { const i = kb * m + j; e += re[i] * re[i] + im[i] * im[i]; } return e; });
    let emax = 0;
    for (const e of energy) if (e > emax) emax = e;
    if (!(emax > 0)) return total;
    const use = bins.filter((kb, i) => energy[i] >= emax * 0.01);
    const cr = use.map(() => new Float64Array(m)), ci = use.map(() => new Float64Array(m));
    const gr = new Float64Array(m), gi = new Float64Array(m);
    const nBinsAll = re.length / m;
    for (let it = 0; it < iterations; it++) {
      const avg = new Float64Array(m);
      use.forEach((kb, u) => {
        for (let j = 0; j < m; j++) { gr[j] = re[kb * m + j]; gi[j] = im[kb * m + j]; }
        fft(gr, gi, log2m);
        let q0 = 0, best = -1;
        for (let q = 0; q < m; q++) { const p = gr[q] * gr[q] + gi[q] * gi[q]; if (p > best) { best = p; q0 = q; } }
        for (let q = 0; q < m; q++) {
          const s = (q + q0) % m;
          cr[u][q] = gr[s]; ci[u][q] = gi[s];
          avg[q] += gr[s] * gr[s] + gi[s] * gi[s];
        }
      });
      let ext = 0;
      while (ext < m / 2 - 1 && (avg[(ext + 1) % m] > 0.1 * avg[0] || avg[(m - ext - 1) % m] > 0.1 * avg[0])) ext += 1;
      const half = Math.min(m / 2, Math.max(1, Math.ceil(1.5 * (ext + 1))));
      const sr = new Float64Array(m), si = new Float64Array(m);
      for (let u = 0; u < use.length; u++) {
        for (let q = 0; q < m; q++) {
          const signed = q <= m / 2 ? q : q - m;
          const keep = Math.abs(signed) <= half;
          gr[q] = keep ? cr[u][q] : 0; gi[q] = keep ? ci[u][q] : 0;
        }
        fft(gr, gi, log2m, true);
        for (let j = 1; j < m; j++) {
          sr[j] += gr[j - 1] * gr[j] + gi[j - 1] * gi[j];
          si[j] += gr[j - 1] * gi[j] - gi[j - 1] * gr[j];
        }
      }
      const phi = new Float64Array(m);
      for (let j = 1; j < m; j++) phi[j] = phi[j - 1] + Math.atan2(si[j], sr[j]);
      removeLinearTrend(phi);
      for (let j = 0; j < m; j++) {
        total[j] += phi[j];
        const c = Math.cos(phi[j]), sn = -Math.sin(phi[j]);
        for (let kb = 0; kb < nBinsAll; kb++) {
          const i = kb * m + j;
          const a = re[i], b = im[i];
          re[i] = a * c - b * sn; im[i] = a * sn + b * c;
        }
      }
      if (rms(phi) < 0.01) break;
    }
    removeLinearTrend(total);
    return total;
  }

  Object.assign(C, {
    fft, speedOfLight, VCO, BANDS, defaultParams, bandMatches, derived, wavelength, makeWindow, taylorWindow,
    svaSpectrum, removeLinearTrend, rms, RangePGA, slowTimePGA,
  });
})(globalThis.CCR = globalThis.CCR || {});
