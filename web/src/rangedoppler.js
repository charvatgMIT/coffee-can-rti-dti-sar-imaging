// Coffee Can Radar web app: range-Doppler maps (FFT or matrix pencil, with Doppler PGA).
// Ported from RangeDoppler.swift.
(function (C) {
  'use strict';
  const { fft, makeWindow, wavelength, slowTimePGA, MatrixPencil } = C;

  /** Jet colour map, 256 entries of [r, g, b]. */
  const JET = new Uint8Array(256 * 3);
  for (let i = 0; i < 256; i++) {
    const v = i / 255;
    const c = x => Math.round(Math.min(1, Math.max(0, 1.5 - Math.abs(4 * v - x))) * 255);
    JET[i * 3] = c(3); JET[i * 3 + 1] = c(2); JET[i * 3 + 2] = c(1);
  }

  const DOPPLER_UPSAMPLE = 4;

  /**
   * inp: {m, log2m, nr, n, nfft, metersPerBin, params, analytic, bre, bim ([bin][pulse]), fre, fim ([pulse][sample])}
   * Returns {db (Float32Array rows*nr), rgba, rows, nr, velocityStep, topVelocity, peak, slowPhase, ms, dopplerOrder, rangeOrder, scatterers}.
   */
  function computeRangeDoppler(inp) {
    const t0 = Date.now();
    const p = inp.params, m = inp.m, nr = inp.nr, n = inp.n;
    if (nr <= 0) return null;
    const bre = Float64Array.from(inp.bre), bim = Float64Array.from(inp.bim);
    const fre = inp.fre ? Float64Array.from(inp.fre) : null, fim = inp.fim ? Float64Array.from(inp.fim) : null;

    let slowPhase = null;
    if (p.rdDopplerPGA) {
      const first = Math.min(nr, Math.max(1, Math.ceil(p.pgaMinRange / inp.metersPerBin)));
      const phi = slowTimePGA(bre, bim, m, inp.log2m, first, nr, Math.max(1, p.pgaIterations));
      slowPhase = phi;
      if (fre) {
        for (let j = 0; j < m; j++) {
          const c = Math.cos(phi[j]), s = -Math.sin(phi[j]);
          for (let t = 0; t < n; t++) {
            const i = j * n + t, a = fre[i], b = fim[i];
            fre[i] = a * c - b * s; fim[i] = a * s + b * c;
          }
        }
      }
    }

    const wd = makeWindow(p, m, p.rdWindow);
    let wsum = 0;
    for (let i = 0; i < m; i++) wsum += wd[i];
    const gd = 1 / wsum;
    const floorDB = p.dbTop - p.rdDbRange - 10;

    function fftMap() {
      const db = new Float32Array(m * nr).fill(-400);
      const re = new Float64Array(m), im = new Float64Array(m);
      for (let kb = 0; kb < nr; kb++) {
        for (let j = 0; j < m; j++) { re[j] = bre[kb * m + j] * wd[j] * gd; im[j] = bim[kb * m + j] * wd[j] * gd; }
        fft(re, im, inp.log2m);
        for (let r = 0; r < m; r++) {
          const q = (r - m / 2 + m) % m;
          db[r * nr + kb] = 10 * Math.log10(re[q] * re[q] + im[q] * im[q] + 1e-20);
        }
      }
      return db;
    }

    const dopplerOrders = [], rangeOrders = [], rangePoles = [];
    function dopplerPencil(u) {
      const rows = m * u;
      const db = new Float32Array(rows * nr).fill(-400);
      const mp = new MatrixPencil(m, Math.floor(m / 3));
      const omegas = new Float64Array(rows);
      for (let r = 0; r < rows; r++) omegas[r] = 2 * Math.PI * (r - rows / 2) / rows;
      const eps = 2 * Math.PI / rows * Math.max(0.1, p.pencilPeakWidth), eps2 = eps * eps;
      const re = new Float64Array(m), im = new Float64Array(m);
      for (let kb = 0; kb < nr; kb++) {
        let e = 0;
        for (let j = 0; j < m; j++) { const i = kb * m + j; re[j] = bre[i]; im[j] = bim[i]; e += re[j] * re[j] + im[j] * im[j]; }
        e /= m;
        if (!(10 * Math.log10(e + 1e-20) > floorDB)) continue;
        const r = mp.analyze(re, im, Math.max(1, p.pencilMaxTargets), p.pencilThresholdDB, p.rdOrderRule, false,
          p.esterThreshold, p.pencilForwardBackward);
        if (!r || r.order <= 0) continue;
        dopplerOrders.push(r.order);
        let top = 0;
        for (let k = 0; k < r.order; k++) if (r.power[k] > top) top = r.power[k];
        const s2 = MatrixPencil.sigmaMin2(r.schur, r.order, omegas);
        for (let row = 0; row < rows; row++) db[row * nr + kb] = 10 * Math.log10(top * eps2 / (s2[row] + eps2) + 1e-20);
      }
      return db;
    }

    function rangePencil() {
      const db = new Float32Array(m * nr).fill(-400);
      if (!fre || fre.length !== m * n) return db;
      const yre = new Float64Array(m * n), yim = new Float64Array(m * n);
      const re = new Float64Array(m), im = new Float64Array(m);
      for (let t = 0; t < n; t++) {
        for (let j = 0; j < m; j++) { re[j] = fre[j * n + t] * wd[j] * gd; im[j] = fim[j * n + t] * wd[j] * gd; }
        fft(re, im, inp.log2m);
        for (let q = 0; q < m; q++) { yre[q * n + t] = re[q]; yim[q * n + t] = im[q]; }
      }
      const mp = new MatrixPencil(n, Math.floor(n / 3));
      const cap = Math.max(1, p.pencilMaxTargets) * (inp.analytic ? 1 : 2);
      const scale = inp.analytic ? 1 : 4;
      const omegas = new Float64Array(nr);
      for (let k = 0; k < nr; k++) omegas[k] = 2 * Math.PI * k / inp.nfft;
      const eps = 2 * Math.PI / inp.nfft * Math.max(0.1, p.pencilPeakWidth), eps2 = eps * eps;
      for (let row = 0; row < m; row++) {
        const q = (row - m / 2 + m) % m;
        const rr = yre.subarray(q * n, q * n + n), ri = yim.subarray(q * n, q * n + n);
        let e = 0;
        for (let t = 0; t < n; t++) e += rr[t] * rr[t] + ri[t] * ri[t];
        e = e / n * scale;
        if (!(10 * Math.log10(e + 1e-20) > floorDB)) continue;
        const r = mp.analyze(rr, ri, cap, p.pencilThresholdDB, p.rdOrderRule, false, p.esterThreshold, p.pencilForwardBackward);
        if (!r || r.order <= 0) continue;
        let positive = 0, top = 0;
        for (let k = 0; k < r.order; k++) {
          const ang = Math.atan2(r.polesI[k], r.polesR[k]);
          if (ang > 0) {
            positive++;
            if (r.power[k] * scale > top) top = r.power[k] * scale;
            const range = ang / (2 * Math.PI) * inp.nfft * inp.metersPerBin;
            if (range < nr * inp.metersPerBin) rangePoles.push({ row, range, power: r.power[k] * scale });
          }
        }
        rangeOrders.push(inp.analytic ? r.order : positive);
        if (!(top > 0)) continue;
        const s2 = MatrixPencil.sigmaMin2(r.schur, r.order, omegas);
        for (let kb = 0; kb < nr; kb++) db[row * nr + kb] = 10 * Math.log10(top * eps2 / (s2[kb] + eps2) + 1e-20);
      }
      return db;
    }

    let db, u = 1;
    switch (p.rdSuperRes) {
      case 'Matrix pencil in Doppler': u = DOPPLER_UPSAMPLE; db = dopplerPencil(u); break;
      case 'Matrix pencil in range': db = rangePencil(); break;
      case 'Matrix pencil in range and Doppler': {
        u = DOPPLER_UPSAMPLE;
        db = dopplerPencil(u);
        const rg = rangePencil();
        for (let row = 0; row < m * u; row++) {
          const coarse = Math.min(m - 1, Math.max(0, swiftRound((row - m * u / 2) / u) + m / 2));
          for (let kb = 0; kb < nr; kb++) db[row * nr + kb] = Math.min(db[row * nr + kb], rg[coarse * nr + kb]);
        }
        break;
      }
      default: db = fftMap();
    }
    const rows = m * u;
    const pri = 2 * p.tpMs / 1000;
    const dv = wavelength(p) / 2 / (m * pri) / u;
    let peak = null;
    const firstBin = Math.max(1, Math.ceil(0.5 / inp.metersPerBin));
    let best = -400;
    for (let r = 0; r < rows; r++) {
      if (!(Math.abs(r - rows / 2) > u)) continue;
      for (let kb = firstBin; kb < Math.max(firstBin, nr); kb++) {
        if (db[r * nr + kb] > best) { best = db[r * nr + kb]; peak = { range: kb * inp.metersPerBin, velocity: (rows / 2 - r) * dv, db: best }; }
      }
    }
    const lo = p.dbTop - p.rdDbRange, cs = 255 / Math.max(1, p.rdDbRange);
    const rgba = new Uint8ClampedArray(rows * nr * 4);
    for (let i = 0; i < rows * nr; i++) {
      const c = Math.max(0, Math.min(255, Math.round((db[i] - lo) * cs))) * 3;
      rgba[i * 4] = JET[c]; rgba[i * 4 + 1] = JET[c + 1]; rgba[i * 4 + 2] = JET[c + 2]; rgba[i * 4 + 3] = 255;
    }
    const median = a => a.length ? a.slice().sort((x, y) => x - y)[Math.floor(a.length / 2)] : null;
    const out = {
      db, rgba, rows, nr, pulses: m, velocityStep: dv, topVelocity: rows / 2 * dv, peak, slowPhase,
      dopplerOrder: median(dopplerOrders), rangeOrder: median(rangeOrders), scatterers: [],
    };
    if (rangePoles.length) {
      const strongest = Math.max(...rangePoles.map(c => c.power));
      const res = inp.nfft / Math.max(1, n) * inp.metersPerBin;
      const kept = [];
      for (const c of rangePoles.slice().sort((a, b) => b.power - a.power)) {
        if (!(c.power >= strongest * 1e-3) || kept.length >= 20) continue;
        if (!kept.some(k => Math.abs(k.row - c.row) <= 2 && Math.abs(k.range - c.range) < res)) kept.push(c);
      }
      out.scatterers = kept.map(k => {
        let row = (k.row - m / 2) * u + rows / 2;
        if (u > 1) {
          const kb = Math.min(nr - 1, Math.max(0, Math.round(k.range / inp.metersPerBin)));
          const lo2 = Math.max(0, row - 2 * u), hi2 = Math.min(rows - 1, row + 2 * u);
          let bestRow = row, bv = -Infinity;
          for (let rr = lo2; rr <= hi2; rr++) if (db[rr * nr + kb] > bv) { bv = db[rr * nr + kb]; bestRow = rr; }
          row = bestRow;
        }
        return { range: k.range, velocity: (rows / 2 - row) * dv };
      });
    }
    out.ms = Date.now() - t0;
    return out;
  }

  /** Swift's .rounded() (to nearest, halves away from zero). */
  function swiftRound(x) { return x < 0 ? -Math.round(-x) : Math.round(x); }

  Object.assign(C, { JET, computeRangeDoppler, swiftRound });
})(globalThis.CCR = globalThis.CCR || {});
