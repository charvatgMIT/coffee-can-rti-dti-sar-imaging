// Coffee Can Radar web app: Doppler vs. time for the radar run as an unmodulated CW radar, after
// MIT's read_data_doppler.m. Ported from DopplerTime.swift (DTSettings, DTGeometry, DopplerTimeDSP,
// DopplerTimeEngine); keep them in step. Also a CW simulator (web only).
(function (C) {
  'use strict';
  const { fft, makeWindow, svaSpectrum, removeLinearTrend, rms, MatrixPencil, speedOfLight, swiftRound } = C;

  const MAX_LOG2 = 20;

  /** Settings the processing depends on (a change re-processes the history). */
  function dtSettings(p) {
    return {
      dwellMs: Math.min(2000, Math.max(20, p.dtDwellMs)),
      overlap: Math.min(0.9375, Math.max(0, p.dtOverlap || 0)),
      carrierMHz: Math.max(100, p.dtCarrierMHz),
      zeroPad: Math.max(1, p.dtZeroPad),
      window: p.dtWindow, sva: p.dtSVA, pga: p.dtPGA,
      pgaMinVelocity: Math.max(0, p.dtPGAMinVelocity), pgaIterations: Math.max(1, p.pgaIterations),
      method: p.dtMethod, orderRule: p.dtOrderRule, maxTargets: Math.max(1, p.dtMaxTargets), display: p.dtPencilDisplay,
      esterThreshold: p.esterThreshold, thresholdDB: p.pencilThresholdDB, peakWidth: p.pencilPeakWidth,
      forwardBackward: p.pencilForwardBackward, maxVelocity: Math.max(1, p.dtMaxVelocity),
      subtractMean: p.dtSubtractMean, ifOnLeft: p.syncOnRight,
    };
  }
  const sameSettings = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const lambdaOf = s => speedOfLight / (s.carrierMHz * 1e6);

  function dtGeometry(s, fs) {
    const n = Math.max(16, Math.round(s.dwellMs / 1000 * fs));
    const hop = Math.max(1, Math.min(n, Math.round(n * (1 - s.overlap))));   // dwell start to dwell start
    const log2m = Math.ceil(Math.log2(n)), m = 1 << log2m;
    const log2nfft = Math.min(MAX_LOG2, Math.max(log2m, Math.ceil(Math.log2(s.zeroPad * n))));
    const nfft = 1 << log2nfft, binHz = fs / nfft, lambda = lambdaOf(s);
    const cols = Math.max(4, Math.min(nfft / 2, Math.floor(2 * s.maxVelocity / lambda / binHz) + 1));
    return { fs, n, m, log2m, nfft, log2nfft, binHz, cols, mpsPerCol: binHz * lambda / 2, lambda, dwellSeconds: n / fs, hop, hopSeconds: hop / fs };
  }

  /** Per-dwell processing (DopplerTimeDSP). */
  class DopplerTimeDSP {
    constructor() { this.windowCache = null; this.pencilCache = null; }

    window(type, n) {
      const c = this.windowCache;
      if (c && c.n === n && c.type === type) return c;
      const w = makeWindow(C.defaultParams(), n, type);
      let sum = 0;
      for (let i = 0; i < n; i++) sum += w[i];
      this.windowCache = { n, type, w, sum };
      return this.windowCache;
    }

    /** One dwell x (mean already removed, length g.n) -> {db: Float32Array(cols), order, pga, lines}. */
    process(x, s, g) {
      const n = g.n;
      const dbRow = (re, im, scale) => {
        const out = new Float32Array(g.cols);
        for (let k = 0; k < g.cols; k++) out[k] = 10 * Math.log10((re[k] * re[k] + im[k] * im[k]) * scale * scale + 1e-30);
        return out;
      };
      if (!s.pga && s.method === 'FFT') {
        let re, im, scale;
        if (s.sva) {
          ({ re, im } = svaSpectrum(x, new Float64Array(n), n, g.log2nfft));
          scale = 2 / n;
        } else {
          const { w, sum } = this.window(s.window, n);
          re = new Float64Array(g.nfft); im = new Float64Array(g.nfft);
          for (let t = 0; t < n; t++) re[t] = x[t] * w[t];
          fft(re, im, g.log2nfft);
          scale = 2 / sum;
        }
        return { db: dbRow(re, im, scale), order: null, pga: null, lines: [] };
      }
      // analytic signal: a real sine of amplitude A becomes A e^{j phi(t)}
      const m = g.m;
      const ar = new Float64Array(m), ai = new Float64Array(m);
      for (let t = 0; t < n; t++) ar[t] = x[t];
      fft(ar, ai, g.log2m);
      for (let k = 1; k < m / 2; k++) { ar[k] *= 2; ai[k] *= 2; }
      for (let k = m / 2 + 1; k < m; k++) { ar[k] = 0; ai[k] = 0; }
      fft(ar, ai, g.log2m, true);
      let zr = new Float64Array(n), zi = new Float64Array(n);
      for (let t = 0; t < n; t++) { zr[t] = ar[t] / m; zi[t] = ai[t] / m; }
      let pgaApplied = null;
      if (s.pga) {
        const r = this.dwellPGA(zr, zi, s, g);
        pgaApplied = r.applied;
        if (r.applied) { zr = r.re; zi = r.im; }
      }
      if (s.method === 'Matrix pencil') {
        const row = this.pencil(zr, zi, s, g);
        row.pga = pgaApplied;
        return row;
      }
      let re, im, scale;
      if (s.sva) {
        ({ re, im } = svaSpectrum(zr, zi, n, g.log2nfft));
        scale = 1 / n;
      } else {
        const { w, sum } = this.window(s.window, n);
        re = new Float64Array(g.nfft); im = new Float64Array(g.nfft);
        for (let t = 0; t < n; t++) { re[t] = zr[t] * w[t]; im[t] = zi[t] * w[t]; }
        fft(re, im, g.log2nfft);
        scale = 1 / sum;
      }
      return { db: dbRow(re, im, scale), order: null, pga: pgaApplied, lines: [] };
    }

    /** Prominent-point PGA on the strongest mover of one dwell. {applied: null | false | true, re, im}. */
    dwellPGA(zr, zi, s, g) {
      const n = g.n, m = g.m, binM = g.fs / m;
      const kLo = Math.max(1, Math.ceil(2 * s.pgaMinVelocity / g.lambda / binM));
      const kHi = Math.min(m / 2 - 1, Math.trunc(g.cols * g.binHz / binM));
      if (!(kHi > kLo + 8)) return { applied: null };
      const gr = Float64Array.from(zr), gi = Float64Array.from(zi);
      let width = Math.max(16, Math.trunc(150 / binM));
      const minWidth = Math.max(8, Math.trunc(20 / binM));
      const re = new Float64Array(m), im = new Float64Array(m), sr = new Float64Array(m), si = new Float64Array(m);
      for (let it = 0; it < s.pgaIterations; it++) {
        re.fill(0); im.fill(0);
        for (let k = 0; k < n; k++) { re[k] = gr[k]; im[k] = gi[k]; }
        fft(re, im, g.log2m);
        let kp = kLo, best = -1;
        const band = new Float64Array(kHi - kLo + 1);
        for (let k = kLo; k <= kHi; k++) {
          const p = re[k] * re[k] + im[k] * im[k];
          band[k - kLo] = p;
          if (p > best) { best = p; kp = k; }
        }
        if (it === 0) {
          band.sort();
          if (!(best > 100 * band[Math.floor(band.length / 2)])) return { applied: null };
        }
        sr.fill(0); si.fill(0);
        const half = Math.trunc(width / 2);
        for (let dk = -half; dk <= half; dk++) {
          const src = ((kp + dk) % m + m) % m, dst = (dk + m) % m;
          sr[dst] = re[src]; si[dst] = im[src];
        }
        fft(sr, si, g.log2m, true);
        const residual = new Float64Array(n);
        for (let t = 1; t < n; t++) {
          const cr = sr[t] * sr[t - 1] + si[t] * si[t - 1], ci = si[t] * sr[t - 1] - sr[t] * si[t - 1];
          residual[t] = residual[t - 1] + Math.atan2(ci, cr);
        }
        removeLinearTrend(residual);
        for (let t = 0; t < n; t++) {
          const c = Math.cos(residual[t]), sn = Math.sin(residual[t]), a = gr[t], b = gi[t];
          gr[t] = a * c + b * sn; gi[t] = b * c - a * sn;
        }
        width = Math.max(minWidth, Math.trunc(width * 0.6));
        if (rms(residual) < 0.005) break;
      }
      if (!(this.sharpness(gr, gi, g, kLo, kHi) > this.sharpness(zr, zi, g, kLo, kHi) * 1.001)) return { applied: false };
      return { applied: true, re: gr, im: gi };
    }

    sharpness(zr, zi, g, lo, hi) {
      const re = new Float64Array(g.m), im = new Float64Array(g.m);
      for (let t = 0; t < g.n; t++) { re[t] = zr[t]; im[t] = zi[t]; }
      fft(re, im, g.log2m);
      let s2 = 0, s4 = 0;
      for (let k = lo; k <= hi; k++) { const p = re[k] * re[k] + im[k] * im[k]; s2 += p; s4 += p * p; }
      return s2 > 0 ? s4 / (s2 * s2) : 0;
    }

    /** Matrix pencil on the analytic dwell, band-limited to 0 ... max velocity and decimated. */
    pencil(zr, zi, s, g) {
      const n = g.n, m = g.m, binM = g.fs / m;
      const re = new Float64Array(m), im = new Float64Array(m);
      for (let t = 0; t < n; t++) { re[t] = zr[t]; im[t] = zi[t]; }
      fft(re, im, g.log2m);
      const fHi = g.cols * g.binHz * 1.05 + 2 * binM;
      const kb = Math.min(m / 2, Math.ceil(fHi / binM) + 1);
      let kp = 64;
      while (kp < 1.25 * kb) kp *= 2;
      kp = Math.min(kp, m);
      const log2kp = Math.round(Math.log2(kp));
      const c0 = Math.trunc(kb / 2);
      const yr = new Float64Array(kp), yi = new Float64Array(kp);
      for (let k = 0; k < kb; k++) { const d = ((k - c0) % kp + kp) % kp; yr[d] = re[k]; yi[d] = im[k]; }
      fft(yr, yi, log2kp, true);
      const nd = Math.min(kp, Math.trunc(n * kp / m));
      const fsd = g.fs * kp / m, fc0 = c0 * binM;
      const dr = new Float64Array(nd), di = new Float64Array(nd);
      for (let t = 0; t < nd; t++) { dr[t] = yr[t] / m; di[t] = yi[t] / m; }
      const row = { db: new Float32Array(g.cols).fill(-300), order: null, pga: null, lines: [] };
      if (nd < 12) return row;
      if (!this.pencilCache || this.pencilCache.n !== nd) this.pencilCache = new MatrixPencil(nd, Math.trunc(nd / 3));
      const r = this.pencilCache.analyze(dr, di, s.maxTargets, s.thresholdDB, s.orderRule, false, s.esterThreshold, s.forwardBackward);
      if (!r || r.order <= 0) return row;
      row.order = r.order;
      const fShow = g.cols * g.binHz;
      for (let k = 0; k < r.order; k++) {
        const f = Math.atan2(r.polesI[k], r.polesR[k]) / (2 * Math.PI) * fsd + fc0;
        if (f >= 0 && f <= fShow) row.lines.push({ velocity: f * g.lambda / 2, db: 10 * Math.log10(r.power[k] + 1e-30) });
      }
      if (s.display === 'Amplitude-weighted lines') {
        for (const l of row.lines) {
          const c = swiftRound(l.velocity / g.mpsPerCol);
          for (let cc = Math.max(0, c - 1); cc <= Math.min(g.cols - 1, c + 1); cc++) row.db[cc] = Math.max(row.db[cc], l.db - (cc === c ? 0 : 6));
        }
      } else {
        let top = 0;
        for (let k = 0; k < r.order; k++) if (r.power[k] > top) top = r.power[k];
        const omegas = new Float64Array(g.cols);
        for (let k = 0; k < g.cols; k++) omegas[k] = 2 * Math.PI * (k * g.binHz - fc0) / fsd;
        const eps = 2 * Math.PI * g.binHz / fsd * Math.max(0.1, s.peakWidth), eps2 = eps * eps;
        const s2 = MatrixPencil.sigmaMin2(r.schur, r.order, omegas);
        for (let k = 0; k < g.cols; k++) row.db[k] = 10 * Math.log10(top * eps2 / (s2[k] + eps2) + 1e-30);
      }
      return row;
    }
  }

  /** History, live input and recordings (DopplerTimeEngine). Snapshots go to `onSnapshot`. */
  class DopplerTimeEngine {
    constructor() {
      this.dsp = new DopplerTimeDSP();
      this.s = dtSettings(C.defaultParams());
      this.historySeconds = 60;
      this.liveFs = 48000;
      this.g = dtGeometry(this.s, 48000);
      this.samples = new Float32Array(0); this.count = 0;   // IF samples (a growable buffer)
      this.rows = []; this.rowMs = [];
      this.fileName = null; this.fileL = null; this.fileR = null; this.fileFs = 44100; this.fileMean = 0;
      this.levelL = 0; this.levelR = 0;
      this.onSnapshot = null;
    }
    get fs() { return this.fileName != null ? this.fileFs : this.liveFs; }

    setParams(p) {
      const ns = dtSettings(p);
      this.historySeconds = p.dtHistorySeconds;
      if (!sameSettings(ns, this.s)) {
        const channelChanged = ns.ifOnLeft !== this.s.ifOnLeft;
        this.s = ns;
        if (this.fileName != null) { if (channelChanged) this.selectFileChannel(); }
        else if (channelChanged) this.clearSamples();
        this.reprocessAll();
      } else { this.trimLive(); this.publish(); }
    }

    clearSamples() { this.samples = new Float32Array(0); this.count = 0; }
    append(x) {
      if (this.count + x.length > this.samples.length) {
        const bigger = new Float32Array(Math.max(this.count + x.length, this.samples.length * 2, 65536));
        bigger.set(this.samples.subarray(0, this.count));
        this.samples = bigger;
      }
      this.samples.set(x, this.count);
      this.count += x.length;
    }

    startLive(fs) {
      this.liveFs = fs;
      if (this.fileName != null) return;
      this.clearSamples();
      this.reprocessAll();
    }

    /** Samples the dwells so far have used (with overlap, the next dwell still reaches back into them). */
    used() { return this.rows.length ? (this.rows.length - 1) * this.g.hop + this.g.n : 0; }

    discontinuity() { if (this.fileName == null) this.count = Math.min(this.count, this.used()); }

    push(left, right) {
      if (this.fileName != null) return;
      const rmsOf = x => { let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * x[i]; return x.length ? Math.sqrt(s / x.length) : 0; };
      const a = 0.05;
      this.levelL = this.levelL * (1 - a) + a * rmsOf(left);
      this.levelR = this.levelR * (1 - a) + a * rmsOf(right);
      this.append(this.s.ifOnLeft ? left : right);
      let added = false;
      while (this.count >= this.rows.length * this.g.hop + this.g.n) { this.processDwell(this.rows.length); added = true; }
      if (added) { this.trimLive(); this.publish(); }
    }

    trimLive() {
      if (this.fileName != null) return;
      const keep = Math.max(1, Math.trunc(this.historySeconds / this.g.hopSeconds));
      if (this.rows.length > keep) {
        const drop = this.rows.length - keep, n = this.g.hop;
        this.rows.splice(0, drop); this.rowMs.splice(0, Math.min(drop, this.rowMs.length));
        this.samples.copyWithin(0, drop * n, this.count);
        this.count -= drop * n;
        this.dropped += drop;   // keeps the display's row groups fixed as the plot scrolls
      }
    }

    loadFile(name, left, right, fs) {
      this.fileName = name; this.fileL = left; this.fileR = right; this.fileFs = fs;
      const rmsOf = x => { let s = 0; for (let i = 0; i < x.length; i++) s += x[i] * x[i]; return x.length ? Math.sqrt(s / x.length) : 0; };
      this.levelL = rmsOf(left); this.levelR = right ? rmsOf(right) : 0;
      this.selectFileChannel();
      this.reprocessAll();
    }

    showLive() {
      if (this.fileName == null) return;
      this.fileName = null; this.fileL = null; this.fileR = null; this.levelL = 0; this.levelR = 0;
      this.clearSamples();
      this.reprocessAll();
    }

    selectFileChannel() {
      const x = this.s.ifOnLeft || !this.fileR ? this.fileL : this.fileR;
      this.samples = x; this.count = x.length;
      let sum = 0;
      for (let i = 0; i < x.length; i++) sum += x[i];
      this.fileMean = x.length ? sum / x.length : 0;   // read_data_doppler.m: sif = sif - mean(s)
    }

    dwell(i) {
      const n = this.g.n, x = new Float64Array(n);
      for (let t = 0, o = i * this.g.hop; t < n; t++) x[t] = this.samples[o + t];
      if (this.s.subtractMean) {
        let mean = this.fileMean;
        if (this.fileName == null) { mean = 0; for (let t = 0; t < n; t++) mean += x[t]; mean /= n; }
        for (let t = 0; t < n; t++) x[t] -= mean;
      }
      return x;
    }

    processDwell(i) {
      const t0 = performance.now();
      const row = this.dsp.process(this.dwell(i), this.s, this.g);
      if (i === this.rows.length) this.rows.push(row); else this.rows[i] = row;
      this.rowMs.push(performance.now() - t0);
      if (this.rowMs.length > this.rows.length) this.rowMs.splice(0, this.rowMs.length - this.rows.length);
    }

    reprocessAll() {
      this.g = dtGeometry(this.s, this.fs);
      this.rows = []; this.rowMs = []; this.dropped = 0;
      const count = this.count < this.g.n ? 0 : Math.floor((this.count - this.g.n) / this.g.hop) + 1;
      for (let i = 0; i < count; i++) this.processDwell(i);
      this.trimLive();
      this.publish();
    }

    snapshot() {
      const g = this.g, rows = this.rows, cols = g.cols;
      const packed = new Float32Array(rows.length * cols);
      let maxDB = -Infinity;
      rows.forEach((r, i) => { packed.set(r.db, i * cols); for (let k = 0; k < cols; k++) if (r.db[k] > maxDB) maxDB = r.db[k]; });
      const recent = this.rowMs.slice(-40);
      const orders = rows.map(r => r.order).filter(o => o != null).sort((a, b) => a - b);
      return {
        rows: packed, nRows: rows.length, cols, lines: rows.map(r => r.lines), maxDB: rows.length ? maxDB : 0,
        dwellSeconds: g.dwellSeconds, hopSeconds: g.hopSeconds, firstIndex: this.fileName == null ? (this.dropped || 0) : 0, mpsPerCol: g.mpsPerCol, fileName: this.fileName,
        msPerDwell: recent.length ? recent.reduce((a, b) => a + b, 0) / recent.length : null,
        medianOrder: orders.length ? orders[Math.floor(orders.length / 2)] : null,
        pgaTried: this.s.pga ? rows.length : 0, pgaDominant: rows.filter(r => r.pga != null).length, pgaApplied: rows.filter(r => r.pga === true).length,
        waitingSamples: Math.max(0, this.count - this.used()), samplesPerDwell: rows.length ? g.hop : g.n,
        ifRMS: this.s.ifOnLeft ? this.levelL : this.levelR, otherRMS: this.s.ifOnLeft ? this.levelR : this.levelL,
      };
    }
    publish() { if (this.onSnapshot) this.onSnapshot(this.snapshot()); }
  }

  /**
   * CW simulator (web only, for trying the Doppler mode without a radar): the IF of a car that comes
   * past at 28 m/s and slows to 8 m/s, and a person walking at about 1.4 m/s with the arm and leg
   * swing of a gait, every 25 s. IF on the IF input, nothing on the sync input.
   */
  class CWSimulator {
    constructor() { this.fs = 48000; this.phCar = 0; this.phWalk = 0; this.phLimb = 0; }
    generate(start, count, p) {
      const fs = this.fs, lam = speedOfLight / (Math.max(100, p.dtCarrierMHz) * 1e6);
      const ifc = new Float32Array(count), sync = new Float32Array(count);
      for (let k = 0; k < count; k++) {
        const t = (start + k) / fs, tc = t % 25;
        const vCar = 28 - 0.8 * tc;
        const aCar = 0.06 * Math.exp(-Math.pow((tc - 12) / 6, 2)) + 0.002;
        const gait = 2 * Math.PI * 1.8 * t;
        const vWalk = 1.4 + 0.35 * Math.sin(gait), vLimb = 1.4 + 2.2 * Math.sin(gait + 0.6);
        this.phCar += 2 * Math.PI * 2 * vCar / lam / fs;
        this.phWalk += 2 * Math.PI * 2 * vWalk / lam / fs;
        this.phLimb += 2 * Math.PI * 2 * vLimb / lam / fs;
        ifc[k] = aCar * Math.cos(this.phCar) + 0.02 * Math.cos(this.phWalk) + 0.006 * Math.cos(this.phLimb) + 0.02 + 0.002 * (Math.random() - 0.5);
      }
      return p.syncOnRight ? [ifc, sync] : [sync, ifc];
    }
  }

  Object.assign(C, { dtSettings, dtGeometry, DopplerTimeDSP, DopplerTimeEngine, CWSimulator });
})(globalThis.CCR = globalThis.CCR || {});
