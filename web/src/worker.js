// Coffee Can Radar web app: DSP worker. Receives audio (live, simulated or from a recording),
// runs the RTI processor, and answers polls with snapshots. Range-Doppler maps are built in a
// second worker (rdworker.js); this one hands it the input blocks through the page.
/* global importScripts */
if (!self.CCR || !self.CCR.RadarProcessor) importScripts('dsp-core.js', 'pencil.js', 'rangedoppler.js', 'processor.js', 'doppler.js');
(function () {
  'use strict';
  const C = self.CCR;
  const proc = new C.RadarProcessor();
  // Doppler vs. time; only the chain for the selected tab gets the audio (as in the Mac app)
  const dt = new C.DopplerTimeEngine();
  dt.onSnapshot = (snap) => self.postMessage({ type: 'dt', snap }, [snap.rows.buffer]);
  let mode = 'rti';                       // 'rti' | 'dti' | 'sar'
  let restartRTI = false, restartDTI = false;
  let pendingParams = null;
  /** Live, simulated or recorded audio to the chain that is on. */
  function route(l, r) {
    if (mode === 'rti') { if (restartRTI) { proc.restart(); restartRTI = false; } proc.push(l, r); }
    else if (mode === 'dti') { if (restartDTI) { dt.startLive(fs); restartDTI = false; } dt.push(l, r); }
  }
  let fs = 48000;
  let source = null;       // 'live' | 'sim' | 'file'
  let timer = null;
  let livePort = null;
  let liveReader = null;   // direct capture: a MediaStreamTrackProcessor's stream of AudioData
  // live backlog guard: at most 0.5 s of audio may wait; beyond that blocks are dropped
  let clockBase = null, dropped = 0, resync = false;
  let rdGeneration = -1;
  let inputChannels = null;

  function stopSource() {
    if (timer) { clearInterval(timer); timer = null; }
    if (livePort) { livePort.onmessage = null; livePort.close(); livePort = null; }
    if (liveReader) { const r = liveReader; liveReader = null; r.cancel().catch(() => {}); }
    source = null;
  }

  function begin(newFs, params) {
    fs = newFs;
    proc.update(params, fs);
    proc.restart();
    proc.rdBusy = false;
    dt.startLive(fs);
    restartRTI = false; restartDTI = false;
    clockBase = null; dropped = 0; resync = false;
  }

  function onLiveBlock(e) {
    const { l, r, frame, ch } = e.data;
    inputChannels = ch;
    liveBlock(l, r, frame / fs * 1000);
  }

  /** One block of live audio; `ms` is its time on the audio clock. Drops blocks more than 0.5 s late. */
  function liveBlock(l, r, ms) {
    const now = performance.now();
    if (!clockBase) clockBase = { now, ms };
    const expected = clockBase.now + (ms - clockBase.ms);
    const lag = now - expected;
    if (lag < -200) clockBase = { now, ms };             // clock drift or a pause: re-base
    if (lag > 500) { dropped += l.length; resync = true; return; }
    if (resync) { proc.discontinuity(); dt.discontinuity(); resync = false; }
    route(l, r);
  }

  /**
   * Direct capture (Chrome, Edge): the interface's samples at its own clock, with no audio
   * engine between them and so no blocks dropped or repeated to follow another device's clock.
   */
  async function readDirect(reader) {
    for (;;) {
      let res;
      try { res = await reader.read(); } catch (e) { break; }
      if (res.done || reader !== liveReader) break;
      const ad = res.value;
      try {
        if (ad.sampleRate !== fs) { begin(ad.sampleRate, proc.params); self.postMessage({ type: 'fs', fs: ad.sampleRate }); }
        const n = ad.numberOfFrames, ch = ad.numberOfChannels;
        const l = new Float32Array(n), r = new Float32Array(n);
        ad.copyTo(l, { planeIndex: 0, format: 'f32-planar' });
        ad.copyTo(r, { planeIndex: ch > 1 ? 1 : 0, format: 'f32-planar' });
        inputChannels = ch;
        liveBlock(l, r, ad.timestamp / 1000);
      } finally { ad.close(); }
    }
  }

  function startSim(params) {
    const sim = new C.Simulator(), cw = new C.CWSimulator();
    begin(sim.fs, params);
    source = 'sim';
    const t0 = performance.now();
    let sent = 0;
    timer = setInterval(() => {
      const due = Math.floor((performance.now() - t0) / 1000 * sim.fs);
      while (sent < due) {
        const n = Math.min(2048, due - sent);
        // FMCW (sync + IF) for the RTI tab, unmodulated CW for Doppler vs. time
        const [l, r] = mode === 'dti' ? cw.generate(sent, n, proc.params) : sim.generate(sent, n, proc.params);
        route(l, r);
        sent += n;
      }
    }, 10);
  }

  function startFile(left, right, fileFs, params, speed) {
    begin(fileFs, params);
    source = 'file';
    const t0 = performance.now();
    let sent = 0;
    timer = setInterval(() => {
      const due = Math.min(left.length, Math.floor((performance.now() - t0) / 1000 * fileFs * speed));
      while (sent < due) {
        const n = Math.min(4096, due - sent);
        route(left.subarray(sent, sent + n), right.subarray(sent, sent + n));
        sent += n;
      }
      if (sent >= left.length) {
        clearInterval(timer); timer = null;
        self.postMessage({ type: 'fileDone' });
      }
    }, 10);
  }

  self.onmessage = (e) => {
    const m = e.data;
    switch (m.type) {
      case 'params':
        proc.update(m.params, fs);
        // re-processing the Doppler history can take a while: apply only the newest settings
        if (!pendingParams) setTimeout(() => { const p = pendingParams; pendingParams = null; dt.setParams(p); }, 0);
        pendingParams = m.params;
        break;
      case 'mode':
        if (m.mode !== mode) {
          mode = m.mode;
          // a chain switched back on starts over: its history would jump across the time it was off
          restartRTI = true; restartDTI = true;
        }
        break;
      case 'dtFile': dt.loadFile(m.name, m.left, m.right, m.fs); break;
      case 'dtLive': dt.showLive(); break;
      case 'live':
        stopSource();
        begin(m.fs, m.params);
        source = 'live';
        livePort = m.port;
        livePort.onmessage = onLiveBlock;
        break;
      case 'liveDirect':
        stopSource();
        begin(m.fs, m.params);
        source = 'live';
        liveReader = m.readable.getReader();
        readDirect(liveReader);
        break;
      case 'sim': stopSource(); startSim(m.params); break;
      case 'file': stopSource(); startFile(m.left, m.right, m.fs, m.params, m.speed || 1); break;
      case 'stop': stopSource(); break;
      case 'pause': proc.paused = m.paused; if (!m.paused) proc.discontinuity(); break;
      case 'restart': proc.restart(); break;
      case 'resetPGA': proc.resetPGA(); break;
      case 'clearHold': proc.clearHold(); break;
      case 'rdDone': proc.rdBusy = false; proc.rdLastMs = m.ms; break;
      case 'poll': {
        const s = proc.takeSnapshot();
        s.droppedFrames = dropped; dropped = 0;
        s.source = source;
        s.inputChannels = inputChannels;
        const transfer = s.newRows.map(r => r.buffer);
        self.postMessage({ type: 'snapshot', s }, transfer);
        const inp = proc.dueRangeDoppler(performance.now());
        if (inp) {
          proc.rdBusy = true;
          rdGeneration = inp.generation;
          const tr = [inp.bre.buffer, inp.bim.buffer];
          if (inp.fre) tr.push(inp.fre.buffer, inp.fim.buffer);
          self.postMessage({ type: 'rdInput', inp }, tr);
        }
        break;
      }
    }
  };
})();
