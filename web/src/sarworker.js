// Coffee Can Radar web app: SAR worker. Holds the recording, parses it (re-using the parse when only
// image settings change, as the Mac app does) and forms the image. Backprojection rows and the
// crossrange pencil are shared out to helper workers (copies of this script in helper mode).
/* global importScripts */
if (!self.CCR || !self.CCR.SAR) importScripts('dsp-core.js', 'pencil.js', 'rangedoppler.js', 'processor.js', 'sar.js');
(function () {
  'use strict';
  const S = self.CCR.SAR;

  // ---------- helper mode: rows of a backprojection or crossrange-pencil job ----------
  let shared = null;
  function helperJob(m) {
    const sh = shared, bp = sh.bpObj || (sh.bpObj = S.BPProfiles.unpack(sh.bp));
    if (m.op === 'bp') {
      const out = S.backprojectRows(bp, sh.xs, sh.ys, sh.cols, m.r0, m.r1, sh.sva, sh.fMid);
      self.postMessage({ id: m.id, r0: m.r0, r1: m.r1, out }, [out.buffer]);
    } else if (m.op === 'xpencil') {
      const re = m.re, im = m.im;
      const [fitted, orderSum] = S.crossPencilRows(bp, sh.xs, sh.ys, re, im, sh.cols, m.r0, m.r1, bp.M, m.p, m.floorPow, m.r0);
      self.postMessage({ id: m.id, r0: m.r0, r1: m.r1, re, im, fitted, orderSum }, [re.buffer, im.buffer]);
    }
  }

  /** A pool of helper workers; run(task) resolves with the helper's reply. */
  class Pool {
    constructor(n, make) {
      this.workers = []; this.pending = new Map(); this.next = 0; this.id = 0;
      for (let i = 0; i < n; i++) {
        const w = make();
        w.onmessage = (e) => { const cb = this.pending.get(e.data.id); this.pending.delete(e.data.id); if (cb) cb(e.data); };
        w.postMessage({ type: 'helper' });
        this.workers.push(w);
      }
    }
    get size() { return this.workers.length; }
    setShared(obj) { for (const w of this.workers) w.postMessage({ type: 'shared', shared: obj }); }
    run(task) {
      const id = ++this.id, w = this.workers[this.next++ % this.workers.length];
      return new Promise((resolve) => { this.pending.set(id, resolve); w.postMessage(Object.assign({ type: 'job', id }, task)); });
    }
  }

  // ---------- main mode ----------
  let helper = false, pool = null, rec = null, recName = '', parsed = null, parsedFor = null;

  function makePool(helperSource) {
    const n = Math.min(8, Math.max(0, (self.navigator && navigator.hardwareConcurrency || 2) - 1));
    if (n < 2) return null;
    try {
      const url = helperSource ? URL.createObjectURL(new Blob([helperSource], { type: 'text/javascript' })) : null;
      return new Pool(n, () => url ? new Worker(url) : new Worker('sarworker.js'));
    } catch (e) { return null; }   // a browser without nested workers: everything runs in this thread
  }

  async function process(p, id) {
    if (!rec) { self.postMessage({ type: 'error', id, message: 'Open a recording first.' }); return; }
    try {
      const reuse = parsed && parsedFor && S.sameParsing(parsedFor, p) ? parsed : null;
      self.postMessage({ type: 'progress', id, message: reuse ? 'Forming the image…' : 'Finding aperture positions and averaging up-chirps…' });
      const r = await S.processSAR(rec, p, reuse, pool);
      parsed = r.data; parsedFor = p;
      const d = r.data, f = r.focused, img = r.image, k = r.kSpace, rp = r.rangeProfiles;
      const res = {
        positions: d.positions, pulsesPerPosition: d.pulsesPerPosition, requestedChirps: d.requestedChirps, availableChirpsMin: d.availableChirpsMin,
        jitterIntegerUs: d.jitterIntegerUs, jitterInterpUs: d.jitterInterpUs, rangePhase: f.rangePhase, crossPhase: f.crossPhase,
        image: { db: img.db, rows: img.rows, cols: img.cols, crossRange: img.crossRange, downRange: img.downRange, maxDB: img.maxDB, pencilNote: img.pencilNote },
        kSpace: k ? { db: k.db, rows: k.rows, cols: k.cols, maxDB: k.maxDB } : null,
        rangeProfiles: { db: rp.db, rows: rp.rows, cols: rp.cols, maxDB: rp.maxDB }, rangeProfileMaxFt: r.rangeProfileMaxFt,
        algorithm: r.algorithm, parseSeconds: r.parseSeconds, imageSeconds: r.imageSeconds, reused: !!reuse, threads: pool ? pool.size + 1 : 1,
      };
      const tr = [img.db.buffer, rp.db.buffer];
      if (k) tr.push(k.db.buffer);
      self.postMessage({ type: 'result', id, params: p, res }, tr);
    } catch (err) {
      self.postMessage({ type: 'error', id, message: err && err.message ? err.message : String(err) });
    }
  }

  self.onmessage = (e) => {
    const m = e.data;
    if (m.type === 'helper') { helper = true; return; }
    if (helper) {
      if (m.type === 'shared') shared = m.shared;
      else if (m.type === 'job') helperJob(m);
      return;
    }
    switch (m.type) {
      case 'init': pool = makePool(m.helperSource); break;
      case 'open':
        rec = { left: m.left, right: m.right, fs: m.fs }; recName = m.name; parsed = null; parsedFor = null;
        self.postMessage({ type: 'opened', name: recName, seconds: m.left.length / m.fs, fs: m.fs });
        break;
      case 'process': process(m.params, m.id); break;
    }
  };
})();
