// Coffee Can Radar web app: the RTI processor (sync trigger, pulse extraction, range profiles,
// background removal, PGA, SVA, matrix pencil, range-Doppler collection) and the simulator.
// Ported from RadarProcessor.swift and AudioInput.swift (SyncIFSimulator).
(function (C) {
  'use strict';
  const { fft, derived, defaultParams, makeWindow, svaSpectrum, RangePGA, MatrixPencil, speedOfLight } = C;

  const KH = 16;   // half-width (taps per side) of the windowed-sinc interpolator

  /** sinc(u) tapered by a Blackman window spanning ±KH samples. */
  function sincKernel(u) {
    if (u === 0) return 1;
    if (Math.abs(u) >= KH) return 0;
    const pu = Math.PI * u, wx = Math.PI * (u / KH + 1);
    return Math.sin(pu) / pu * (0.42 - 0.5 * Math.cos(wx) + 0.08 * Math.cos(2 * wx));
  }

  /** Band-limited value of x at fractional index t. */
  function interpolate(x, t) {
    const n0 = Math.floor(t), f = t - n0;
    if (f === 0) return x[n0];
    let s = 0;
    for (let m = -KH + 1; m <= KH; m++) s += x[n0 + m] * sincKernel(f - m);
    return s;
  }

  function stdDev(a) {
    if (!a.length) return 0;
    const m = a.reduce((s, v) => s + v, 0) / a.length;
    return Math.sqrt(a.reduce((s, v) => s + (v - m) * (v - m), 0) / a.length);
  }

  const RD_CAP = 256;

  class RadarProcessor {
    constructor() {
      this.params = defaultParams();
      this.fs = 48000;
      this.d = derived(this.params, this.fs);
      this.paused = false;
      this.cap = 8 * 48000;
      this.bufL = new Float32Array(this.cap);
      this.bufR = new Float32Array(this.cap);
      this.generation = 0;
      this.slips = 0;
      this.resetBuffer();
      this.resetProcessing();
      // range-Doppler ring (complex profiles and fast-time samples)
      this.rdBins = 0; this.rdRe = null; this.rdIm = null; this.rdNewest = 0; this.rdCount = 0;
      this.rdFastRe = null; this.rdFastIm = null; this.rdFastN = 0; this.rdAnalytic = false;
      this.rdDirty = false; this.rdLastBuild = 0; this.rdLastMs = 0; this.rdBusy = false;
    }

    update(p, fs) {
      const old = { params: this.params, fs: this.fs, d: this.d };
      this.params = p;
      this.fs = fs;
      this.d = derived(p, fs);
      if (fs !== old.fs) {
        this.cap = Math.max(Math.floor(8 * fs), 48000);
        this.bufL = new Float32Array(this.cap); this.bufR = new Float32Array(this.cap);
        this.resetBuffer();
      } else if (p.syncOnRight !== old.params.syncOnRight) {
        this.resetBuffer();
      }
      const o = old.params, d = this.d;
      if (fs !== old.fs || p.syncOnRight !== o.syncOnRight || d.n !== old.d.n || d.nfft !== old.d.nfft
        || p.window !== o.window || p.taylorNbar !== o.taylorNbar || p.taylorSidelobeDB !== o.taylorSidelobeDB
        || p.pgaEnabled !== o.pgaEnabled || p.svaEnabled !== o.svaEnabled || p.rangeMethod !== o.rangeMethod
        || p.pencilL !== o.pencilL || p.pencilDisplay !== o.pencilDisplay) {
        this.resetProcessing();
      } else if (p.background !== o.background) {
        this.meanPulse = null; this.nMean = 0; this.prevPulse = null; this.pga = null;
      } else if (p.pgaPulses !== o.pgaPulses) {
        this.pga = null;
      }
      if (p.rdRangePGA !== o.rdRangePGA) this.rdCount = 0;
      this.rdDirty = true;
    }

    resetPGA() { this.pga = null; }
    discontinuity() { this.resetBuffer(); }
    restart() { this.resetBuffer(); this.resetProcessing(); }
    clearHold() { this.holdPow = this.avgPow ? Float64Array.from(this.avgPow) : null; this.generation += 1; this.pendingRows = []; }

    resetBuffer() {
      this.w = 0; this.scan = KH + 2; this.below = 0; this.abs0 = 0;
      this.edgeHistory = []; this.lastEdge = null; this.edgeIsNew = false;
      // glitch guard (web only): the previous edge, the sync period estimate and the pulse waiting for its check
      this.prevEdgeAbs = null; this.periodEst = null; this.periodSeed = []; this.oddRun = []; this.pendingPulse = null;
      this.peakL = 0; this.peakR = 0;
      this.sqCount = 0; this.sqSum = [0, 0]; this.sqMax = [0, 0]; this.squareness = null;
    }

    resetProcessing() {
      const p = this.params, d = this.d;
      this.meanPulse = null; this.nMean = 0; this.prevPulse = null;
      this.avgPow = null; this.holdPow = null; this.pendingRows = [];
      this.pulseCount = 0;
      this.generation += 1;
      this.window = p.svaEnabled ? new Float64Array(d.n).fill(1) : makeWindow(p, d.n);
      let s = 0;
      for (let i = 0; i < d.n; i++) s += this.window[i];
      this.windowScale = 2 / s;
      this.pga = null;
      this.pencil = null; this.pencilTargets = []; this.pencilOrder = null; this.pencilMs = null;
      this.rdCount = 0; this.rdNewest = 0; this.rdRangeWindow = null;
    }

    // ---------- input ----------
    push(left, right) {
      if (this.paused) return;
      const p = this.params, d = this.d;
      const trig = p.syncOnRight ? right : left, ifc = p.syncOnRight ? left : right;
      const n = Math.min(trig.length, ifc.length);
      if (n <= 0) return;
      if (this.w + n > this.cap) {
        const keep = Math.max(0, this.scan - d.n - 4 * KH - 64);
        if (keep > 0) {
          this.bufL.copyWithin(0, keep, this.w); this.bufR.copyWithin(0, keep, this.w);
          this.w -= keep; this.scan -= keep; this.abs0 += keep;
          if (this.lastEdge) this.lastEdge = this.lastEdge.i - keep >= 0 ? { i: this.lastEdge.i - keep, t: this.lastEdge.t - keep } : null;
        }
        if (this.w + n > this.cap) { this.abs0 += this.w; this.w = 0; this.scan = KH + 2; this.below = 0; this.lastEdge = null; }
      }
      this.bufL.set(trig.subarray(0, n), this.w);
      this.bufR.set(ifc.subarray(0, n), this.w);
      let mxL = 0, msL = 0, mxR = 0, msR = 0;
      for (let k = 0; k < n; k++) {
        const a = Math.abs(trig[k]), b = Math.abs(ifc[k]);
        if (a > mxL) mxL = a;
        if (b > mxR) mxR = b;
        msL += trig[k] * trig[k]; msR += ifc[k] * ifc[k];
      }
      this.peakL = Math.max(this.peakL, mxL); this.peakR = Math.max(this.peakR, mxR);
      this.sqMax[0] = Math.max(this.sqMax[0], mxL); this.sqSum[0] += msL;
      this.sqMax[1] = Math.max(this.sqMax[1], mxR); this.sqSum[1] += msR;
      this.sqCount += n;
      if (this.sqCount >= this.fs) {
        const c = this.sqCount;
        this.squareness = [this.sqMax[0] > 0 ? Math.sqrt(this.sqSum[0] / c) / this.sqMax[0] : 0,
          this.sqMax[1] > 0 ? Math.sqrt(this.sqSum[1] / c) / this.sqMax[1] : 0];
        this.sqCount = 0; this.sqSum = [0, 0]; this.sqMax = [0, 0];
      }
      this.w += n;
      this.detectEdges();
    }

    // ---------- trigger ----------
    detectEdges() {
      const p = this.params, sg = p.invert ? -1 : 1, th = p.threshold;
      const need = this.d.n + KH + 2;
      const bufL = this.bufL;
      while (this.scan < this.w - need) {
        const i = this.scan;
        if (sg * bufL[i] > th) {
          if (this.below >= p.holdoff && i >= KH + 2) this.onEdge(i);
          this.below = 0;
        } else {
          this.below += 1;
        }
        this.scan += 1;
      }
    }

    onEdge(i) {
      const p = this.params, sg = p.invert ? -1 : 1, th = p.threshold;
      const u = Math.max(10, p.interpolation);
      const bufL = this.bufL, bufR = this.bufR;
      let pt = i - 1, pv = sg * bufL[i - 1], tEdge = i;
      for (let j = 1; j <= u; j++) {
        const t = (i - 1) + j / u;
        const v = j === u ? sg * bufL[i] : sg * interpolate(bufL, t);
        if (v > th) { tEdge = pt + (th - pv) / (v - pv) / u; break; }
        pt = t; pv = v;
      }
      this.edgeHistory.push({ i: this.abs0 + i, t: this.abs0 + tEdge });
      if (this.edgeHistory.length > 128) this.edgeHistory.splice(0, this.edgeHistory.length - 128);
      this.lastEdge = { i, t: tEdge };
      this.edgeIsNew = true;
      const clean = this.checkPeriod(this.abs0 + tEdge);

      const n = this.d.n;
      const pulse = new Float64Array(n);
      const t0 = p.align ? tEdge : i;
      const n0 = Math.floor(t0), f = t0 - n0;
      if (f === 0) {
        for (let k = 0; k < n; k++) pulse[k] = sg * bufR[n0 + k];
      } else {
        const taps = new Float64Array(2 * KH);
        for (let m = 0; m < 2 * KH; m++) taps[m] = sincKernel(f - (m - KH + 1));
        for (let k = 0; k < n; k++) {
          const base = n0 + k - KH + 1;
          let s = 0;
          for (let m = 0; m < 2 * KH; m++) s += bufR[base + m] * taps[m];
          pulse[k] = sg * s;
        }
      }
      if (!p.rejectGlitches) { this.processPulse(pulse); return; }
      // A browser can drop or repeat a block of audio samples (its audio clock and the interface's
      // drift apart); the sync period then jumps by the block length. Each pulse waits for the next
      // edge: if the period it starts is normal it is processed, otherwise it is skipped.
      if (this.pendingPulse) {
        if (clean) this.processPulse(this.pendingPulse);
        else { this.slips += 1; if (p.background === '2-pulse canceller') this.prevPulse = null; }
      }
      this.pendingPulse = pulse;
    }

    /** True if the sync period ending at this edge matches the running estimate (within 16 samples: a browser
     *  drops or repeats audio in blocks of at least 128 samples, while real sync periods wander by a few). */
    checkPeriod(tAbs) {
      const prev = this.prevEdgeAbs;
      this.prevEdgeAbs = tAbs;
      if (prev == null) return true;
      const dt = tAbs - prev;
      if (this.periodEst == null) {
        // seed with the median of the first five periods
        this.periodSeed.push(dt);
        if (this.periodSeed.length >= 5) this.periodEst = this.periodSeed.slice().sort((a, b) => a - b)[2];
        return true;
      }
      if (Math.abs(dt - this.periodEst) <= 16) {
        this.periodEst += 0.05 * (dt - this.periodEst);
        this.oddRun = [];
        return true;
      }
      // five odd periods in a row: the sync period itself changed (e.g. a new Tp), so re-seed
      this.oddRun.push(dt);
      if (this.oddRun.length >= 5) { this.periodEst = this.oddRun.slice().sort((a, b) => a - b)[2]; this.oddRun = []; }
      return false;
    }

    // ---------- per pulse ----------
    processPulse(pulse) {
      const p = this.params, d = this.d, n = d.n;
      let x = Float64Array.from(pulse);
      if (p.background === 'Subtract mean pulse') {
        if (!this.meanPulse || this.meanPulse.length !== n) { this.meanPulse = new Float64Array(n); this.nMean = 0; }
        this.nMean = Math.min(this.nMean + 1, Math.max(1, p.meanLength));
        const a = 1 / this.nMean, mp = this.meanPulse;
        for (let k = 0; k < n; k++) { mp[k] += a * (pulse[k] - mp[k]); x[k] = pulse[k] - mp[k]; }
        this.prevPulse = pulse;
      } else if (p.background === '2-pulse canceller') {
        const prev = this.prevPulse;
        if (!prev || prev.length !== n) { this.prevPulse = pulse; return; }
        for (let k = 0; k < n; k++) x[k] = pulse[k] - prev[k];
        this.prevPulse = pulse;
      } else {
        this.prevPulse = pulse;
      }

      const nfft = d.nfft, nb = nfft / 2;
      const pow = new Float64Array(nb);
      const rdPGA = p.rdEnabled && p.rdRangePGA;
      let corrected = null;
      if (p.pgaEnabled || rdPGA) {
        if (!this.pga || this.pga.n !== n) this.pga = new RangePGA(n);
        const g = this.pga;
        const a = g.analytic(x);
        const mPerBin = d.metersPerBin * nfft / g.m;
        const lo = Math.ceil(p.pgaMinRange / mPerBin);
        const hi = Math.max(lo + 1, Math.floor(d.rShow / mPerBin));
        g.add(a, Math.max(4, p.pgaPulses), p.pgaIterations, lo, hi, p.pgaMinAgreement);
        g.correct(a);
        corrected = a;
      }
      if (rdPGA && corrected) this.recordDoppler(corrected.re, corrected.im); else this.recordDoppler(x, null);

      const ws = this.windowScale, win = this.window;
      if (p.pgaEnabled && corrected) {
        const a = corrected;
        if (p.rangeMethod === 'Matrix pencil') { this.pencilProfile(a.re, a.im, false, pow); this.accumulate(pow); return; }
        if (p.svaEnabled) {
          const y = svaSpectrum(a.re, a.im, n, d.log2n);
          const s2 = ws * ws / 4;
          for (let k = 0; k < nb; k++) pow[k] = (y.re[k] * y.re[k] + y.im[k] * y.im[k]) * s2;
          this.accumulate(pow); return;
        }
        const re = new Float64Array(nfft), im = new Float64Array(nfft);
        for (let k = 0; k < n; k++) { re[k] = a.re[k] * win[k]; im[k] = a.im[k] * win[k]; }
        fft(re, im, d.log2n);
        const s2 = ws * ws / 4;
        for (let k = 0; k < nb; k++) pow[k] = (re[k] * re[k] + im[k] * im[k]) * s2;
        this.accumulate(pow); return;
      }
      if (p.rangeMethod === 'Matrix pencil') { this.pencilProfile(x, new Float64Array(n), true, pow); this.accumulate(pow); return; }
      if (p.svaEnabled) {
        const y = svaSpectrum(x, new Float64Array(n), n, d.log2n);
        const s2 = ws * ws;
        for (let k = 0; k < nb; k++) pow[k] = (y.re[k] * y.re[k] + y.im[k] * y.im[k]) * s2;
        this.accumulate(pow); return;
      }
      // real FFT: a sine of amplitude A peaks at A*sum(w)/2 (0 dBFS for A = 1)
      const re = new Float64Array(nfft), im = new Float64Array(nfft);
      for (let k = 0; k < n; k++) re[k] = x[k] * win[k];
      fft(re, im, d.log2n);
      const s2 = ws * ws;
      pow[0] = re[0] * re[0] * s2;
      for (let k = 1; k < nb; k++) pow[k] = (re[k] * re[k] + im[k] * im[k]) * s2;
      this.accumulate(pow);
    }

    pencilProfile(re, im, real, pow) {
      const p = this.params, d = this.d, n = d.n, nfft = d.nfft;
      const lp = p.pencilL > 0 ? p.pencilL : Math.floor(n / 3);
      if (!this.pencil || this.pencil.n !== n || this.pencil.l !== Math.max(2, Math.min(lp, n - 2))) this.pencil = new MatrixPencil(n, lp);
      const t0 = Date.now();
      const targets = Math.max(1, p.pencilMaxTargets);
      const r = this.pencil.analyze(re, im, real ? 2 * targets : targets, p.pencilThresholdDB, p.pencilOrderRule, real,
        p.esterThreshold, p.pencilForwardBackward);
      if (!r) { pow.fill(0); return; }
      const scale = real ? 4 : 1;
      const found = [];
      for (let k = 0; k < r.order; k++) {
        const ang = Math.atan2(r.polesI[k], r.polesR[k]);
        if (!(ang > 0)) continue;
        found.push({ range: ang / (2 * Math.PI) * nfft * d.metersPerBin, db: 10 * Math.log10(r.power[k] * scale + 1e-20), k });
      }
      const eps = 2 * Math.PI / nfft * Math.max(0.1, p.pencilPeakWidth), eps2 = eps * eps;
      const omegas = new Float64Array(pow.length);
      for (let k = 0; k < pow.length; k++) omegas[k] = 2 * Math.PI * k / nfft;
      if (p.pencilDisplay === 'Amplitude-weighted lines') {
        pow.fill(0);
        for (const f of found) {
          const pr = r.polesR[f.k], pi = r.polesI[f.k], mag = Math.hypot(pr, pi), ur = pr / mag, ui = pi / mag, pk = r.power[f.k] * scale;
          for (let b = 0; b < pow.length; b++) {
            const dr = Math.cos(omegas[b]) - ur, di = Math.sin(omegas[b]) - ui;
            pow[b] += pk * eps2 / (dr * dr + di * di + eps2);
          }
        }
      } else {
        let top = 0;
        for (const f of found) if (r.power[f.k] > top) top = r.power[f.k];
        top *= scale;
        const s2 = MatrixPencil.sigmaMin2(r.schur, r.order, omegas);
        for (let k = 0; k < pow.length; k++) pow[k] = top * eps2 / (s2[k] + eps2);
      }
      this.pencilTargets = found.map(f => ({ range: f.range, db: f.db }));
      this.pencilOrder = r.order;
      const ms = Date.now() - t0;
      this.pencilMs = this.pencilMs == null ? ms : 0.9 * this.pencilMs + 0.1 * ms;
    }

    // ---------- range-Doppler ----------
    recordDoppler(re, im) {
      const p = this.params, d = this.d;
      if (!p.rdEnabled) return;
      const n = d.n, nfft = d.nfft, nb = nfft / 2;
      if (this.rdBins !== nb || !this.rdRe || this.rdRe.length !== RD_CAP * nb || this.rdFastN !== n || this.rdAnalytic !== (im != null)) {
        this.rdBins = nb;
        this.rdRe = new Float32Array(RD_CAP * nb); this.rdIm = new Float32Array(RD_CAP * nb);
        this.rdFastN = n; this.rdAnalytic = im != null;
        this.rdFastRe = new Float32Array(RD_CAP * n); this.rdFastIm = new Float32Array(RD_CAP * n);
        this.rdCount = 0; this.rdNewest = 0;
      }
      if (!this.rdRangeWindow || this.rdRangeWindow.length !== n) {
        this.rdRangeWindow = makeWindow(p, n);
        let s = 0;
        for (let i = 0; i < n; i++) s += this.rdRangeWindow[i];
        this.rdRangeScale = 2 / s;
      }
      const br = new Float64Array(nfft), bi = new Float64Array(nfft), w = this.rdRangeWindow;
      for (let k = 0; k < n; k++) { br[k] = re[k] * w[k]; bi[k] = im ? im[k] * w[k] : 0; }
      fft(br, bi, d.log2n);
      const g = im == null ? this.rdRangeScale : this.rdRangeScale / 2;
      this.rdNewest = (this.rdNewest + 1) % RD_CAP;
      const base = this.rdNewest * nb;
      for (let k = 0; k < nb; k++) { this.rdRe[base + k] = br[k] * g; this.rdIm[base + k] = bi[k] * g; }
      const fb = this.rdNewest * n;
      for (let t = 0; t < n; t++) { this.rdFastRe[fb + t] = re[t]; this.rdFastIm[fb + t] = im ? im[t] : 0; }
      this.rdCount = Math.min(this.rdCount + 1, RD_CAP);
      this.rdDirty = true;
    }

    rdSize() {
      const log2m = Math.max(3, Math.min(Math.floor(Math.log2(Math.max(8, this.params.rdPulses))), Math.log2(RD_CAP)));
      return { log2m, m: 1 << log2m };
    }

    /** A new map's input if one is due (at most 10 a second, and never more often than 2x the last build time). */
    dueRangeDoppler(now) {
      const p = this.params;
      const { m, log2m } = this.rdSize();
      const interval = Math.max(100, 2 * this.rdLastMs);
      if (!p.rdEnabled || !this.rdDirty || this.rdBusy || now - this.rdLastBuild < interval || this.rdCount < m || !this.rdBins || this.rdFastN !== this.d.n) return null;
      this.rdDirty = false;
      this.rdLastBuild = now;
      return this.makeRangeDopplerInput(m, log2m);
    }

    makeRangeDopplerInput(m, log2m) {
      const p = this.params, d = this.d;
      if (this.rdCount < m || !this.rdBins || this.rdFastN !== d.n) return null;
      const nr = Math.min(d.nBins, this.rdBins), n = d.n;
      const bre = new Float64Array(m * nr), bim = new Float64Array(m * nr);
      const needFast = p.rdSuperRes === 'Matrix pencil in range' || p.rdSuperRes === 'Matrix pencil in range and Doppler';
      const fre = needFast ? new Float64Array(m * n) : null, fim = needFast ? new Float64Array(m * n) : null;
      for (let j = 0; j < m; j++) {
        const slot = ((this.rdNewest - (m - 1) + j) % RD_CAP + RD_CAP) % RD_CAP;
        const src = slot * this.rdBins;
        for (let kb = 0; kb < nr; kb++) { bre[kb * m + j] = this.rdRe[src + kb]; bim[kb * m + j] = this.rdIm[src + kb]; }
        if (needFast) for (let t = 0; t < n; t++) { fre[j * n + t] = this.rdFastRe[slot * n + t]; fim[j * n + t] = this.rdFastIm[slot * n + t]; }
      }
      return { m, log2m, nr, n, nfft: d.nfft, metersPerBin: d.metersPerBin, params: p, analytic: this.rdAnalytic,
        generation: this.generation, bre, bim, fre, fim };
    }

    // ---------- trace / rows ----------
    accumulate(pow) {
      const nb = pow.length, p = this.params;
      if (!this.avgPow || this.avgPow.length !== nb) {
        this.avgPow = Float64Array.from(pow); this.holdPow = Float64Array.from(pow);
      } else {
        const a = 1 / Math.max(1, p.traceAveraging);
        for (let k = 0; k < nb; k++) {
          this.avgPow[k] += a * (pow[k] - this.avgPow[k]);
          if (this.avgPow[k] > this.holdPow[k]) this.holdPow[k] = this.avgPow[k];
        }
      }
      const row = new Float32Array(nb);
      for (let k = 0; k < nb; k++) row[k] = 10 * Math.log10(pow[k] + 1e-20);
      this.pendingRows.push(row);
      if (this.pendingRows.length > 256) this.pendingRows.splice(0, this.pendingRows.length - 256);
      this.pulseCount += 1;
    }

    takeSnapshot() {
      const p = this.params, d = this.d;
      const s = { derived: d, generation: this.generation, pulseCount: this.pulseCount };
      if (this.avgPow) {
        s.traceDB = Float32Array.from(this.avgPow, v => 10 * Math.log10(v + 1e-20));
        if (p.peakHold) s.holdDB = Float32Array.from(this.holdPow, v => 10 * Math.log10(v + 1e-20));
      }
      s.newRows = this.pendingRows;
      this.pendingRows = [];
      if (this.edgeIsNew && this.lastEdge) {
        this.edgeIsNew = false;
        s.scope = this.makeScope(this.lastEdge.i);
        s.edge = this.makeEdge(this.lastEdge.i, this.lastEdge.t);
      }
      const eh = this.edgeHistory;
      if (eh.length > 4) {
        const di = [], dt = [];
        for (let k = 1; k < eh.length; k++) { di.push(eh[k].i - eh[k - 1].i); dt.push(eh[k].t - eh[k - 1].t); }
        const mean = dt.reduce((a, b) => a + b, 0) / dt.length;
        s.pulseRateHz = this.fs / mean;
        s.periodMs = mean / this.fs * 1e3;
        s.jitterIntegerUs = stdDev(di) / this.fs * 1e6;
        s.jitterInterpUs = stdDev(dt) / this.fs * 1e6;
      }
      [s.peakL, s.peakR] = p.syncOnRight ? [this.peakR, this.peakL] : [this.peakL, this.peakR];
      this.peakL = 0; this.peakR = 0;
      if (this.squareness) { s.squarenessTrigger = this.squareness[0]; s.squarenessIF = this.squareness[1]; }
      if (p.rangeMethod === 'Matrix pencil') { s.pencilTargets = this.pencilTargets; s.pencilOrder = this.pencilOrder; s.pencilMs = this.pencilMs; }
      if (p.rdEnabled) s.rdCollected = this.rdCount;
      s.slips = this.slips;
      if ((p.pgaEnabled || (p.rdEnabled && p.rdRangePGA)) && this.pga) {
        const g = this.pga;
        s.pgaPhase = g.phase ? Float32Array.from(g.phase) : null;
        s.pgaUpdates = g.updates; s.pgaAccepted = g.accepted;
        s.pgaAgreement = g.updates > 0 ? g.lastAgreement : null;
      }
      return s;
    }

    makeScope(i) {
      const sg = this.params.invert ? -1 : 1;
      const pre = Math.floor(this.d.n * 0.15);
      const a = Math.max(0, i - pre), b = Math.min(this.w, i + this.d.n + KH);
      if (b <= a) return null;
      const left = new Float32Array(b - a), right = new Float32Array(b - a);
      for (let k = a; k < b; k++) { left[k - a] = sg * this.bufL[k]; right[k - a] = sg * this.bufR[k]; }
      return { left, right, pre: i - a, fs: this.fs, n: this.d.n };
    }

    makeEdge(i, t) {
      const span = 4;
      if (i - span - KH < 0 || i + span + KH >= this.w) return null;
      const sg = this.params.invert ? -1 : 1;
      const u = Math.max(10, this.params.interpolation);
      const samples = [], fine = [];
      for (let k = -span; k <= span; k++) samples.push(sg * this.bufL[i + k]);
      for (let j = 0; j <= 2 * span * u; j++) fine.push(sg * interpolate(this.bufL, (i - span) + j / u));
      return { samples, fine, upsample: u, edgeOffset: t - i, threshold: this.params.threshold, span };
    }
  }

  /**
   * Synthetic sync + IF for trying the app without the radar (SyncIFSimulator in the Mac app):
   * an AC-coupled square sync whose period isn't a whole number of samples, targets at 8 m (fixed),
   * 13-37 m (walking) and 60 m.
   */
  class Simulator {
    constructor() { this.fs = 48000; this.hp = 0; this.hpPrev = 0; }
    generate(start, count, p) {
      const fs = this.fs, tp = p.tpMs * 1e-3, bw = Math.max(1, (p.fStopMHz - p.fStartMHz) * 1e6);
      const period = 2 * tp * fs * 1.000371, aHP = Math.exp(-2 * Math.PI * 5 / fs);
      const left = new Float32Array(count), right = new Float32Array(count);
      for (let k = 0; k < count; k++) {
        const s = start + k;
        const sq = Math.tanh(100 * Math.sin(2 * Math.PI * s / period));
        this.hp = aHP * (this.hp + sq - this.hpPrev);
        this.hpPrev = sq;
        left[k] = -0.45 * this.hp;
        const ph = (s % period) / period, up = ph < 0.5;
        const tr = (up ? ph : ph - 0.5) * period / fs;
        const fb = r => 2 * r * bw / (speedOfLight * tp) * (up ? 1 : 0.92);
        const r2 = 25 + 12 * Math.sin(2 * Math.PI * 0.015 * s / fs);
        const carrier = 4 * Math.PI * p.fStartMHz * 1e6 * r2 / speedOfLight;
        const v = 0.08 * Math.sin(2 * Math.PI * fb(8) * tr + 0.3)
          + 0.03 * Math.sin(2 * Math.PI * fb(r2) * tr + 1.1 + carrier)
          + 0.01 * Math.sin(2 * Math.PI * fb(60) * tr)
          + 0.15 * (up ? tr / tp : 1 - tr / tp)
          + 0.002 * (Math.random() - 0.5);
        right[k] = -v;
      }
      return p.syncOnRight ? [right, left] : [left, right];
    }
  }

  Object.assign(C, { RadarProcessor, Simulator, sincKernel, interpolate, KH });
})(globalThis.CCR = globalThis.CCR || {});
