// Coffee Can Radar web app: page logic (settings, audio input, workers, plots).
// The RTI tab of "Coffee Can RTI DTI SAR Imaging" (RadarModel.swift, ContentView.swift, Plots.swift).
(function () {
  'use strict';
  const C = window.CCR, P = C.Plot;
  const $ = id => document.getElementById(id);
  const APP_NAME = 'Coffee Can Radar RTI · DTI · SAR (web)';
  const CREDIT = 'Vibe coded by Gregory L. Charvat & Jared Smith based on original Matlab scripts from MIT OCW';
  const BP_CREDIT = 'SAR backprojection: bpBasic.m by LeRoy Gorham, Air Force Research Laboratory (AFRL); Gorham &amp; Moore, "SAR image formation toolbox for MATLAB", SPIE 2010';
  const BP_URL = 'https://github.com/bambang/osubp/blob/master/bpBasic.m';
  const OCW = 'https://ocw.mit.edu/courses/res-ll-003-build-a-small-radar-system-capable-of-sensing-range-doppler-and-synthetic-aperture-radar-imaging-january-iap-2011/resources/doppler-radar-using-the-coffee-can-radar/';
  const BUILD_DATE = (window.CCR_BUNDLE && window.CCR_BUNDLE.date) || document.lastModified.split(' ')[0];

  // ---------------- settings ----------------
  const STORE = 'ccr.rti.params';
  function loadParams() {
    try { return Object.assign(C.defaultParams(), JSON.parse(localStorage.getItem(STORE) || '{}')); } catch (e) { return C.defaultParams(); }
  }
  let params = loadParams();
  let fs = 48000;
  let d = C.derived(params, fs);
  const unit = () => params.rangeUnit === 'Feet'
    ? { per: 1 / 0.3048, ab: 'ft', finePer: 1 / 0.0254, fineAb: 'in' } : { per: 1, ab: 'm', finePer: 100, fineAb: 'cm' };

  function setParams(changes) {
    const old = params;
    params = Object.assign({}, params, changes);
    if (params.band !== old.band && C.BANDS[params.band]) [params.fStartMHz, params.fStopMHz] = C.BANDS[params.band];
    else if (params.band !== 'Custom' && !C.bandMatches(params.band, params)) params.band = 'Custom';
    try { localStorage.setItem(STORE, JSON.stringify(params)); } catch (e) { /* private window */ }
    if (params.syncOnRight !== old.syncOnRight || params.tpMs !== old.tpMs) { stats = {}; suggestion = null; showSuggestion(); }
    d = C.derived(params, fs);
    worker.postMessage({ type: 'params', params });
    if (params.rtiSeconds !== old.rtiSeconds) resetRTI(rti.width);
    else if (params.rtiViewSeconds !== old.rtiViewSeconds) rti.setView(viewPulses(), params.dbTop, params.rtiDbRange);
    else if (params.dbTop !== old.dbTop || params.rtiDbRange !== old.rtiDbRange) rti.recolor(params.dbTop, params.rtiDbRange);
    if (params.dtDbRange !== old.dtDbRange) buildDTImage();
    refreshSidebar();
    syncControls();
    if (activeTab === 'how') renderHow();
    requestDraw();
  }

  // ---------------- workers ----------------
  function makeWorker(name) {
    const b = window.CCR_BUNDLE;
    if (b) return new Worker(URL.createObjectURL(new Blob([b.dsp + '\n' + b[name]], { type: 'text/javascript' })));
    return new Worker('src/' + name + '.js');
  }
  const worker = makeWorker('worker');
  const rdWorker = makeWorker('rdworker');
  worker.postMessage({ type: 'params', params });

  let source = null;          // 'live' | 'sim' | 'file' | null
  let paused = false;
  let generation = -1;
  let rangeDoppler = null, rdImage = null;
  let trace = null, hold = null, scope = null, edge = null;
  let pgaPhase = null, pgaUpdates = 0, pgaAccepted = 0, pgaAgreement = null;
  let pencilTargets = [], pencilOrder = null, pencilMs = null;
  let pulseCount = 0, rdCollected = 0, droppedSeconds = 0, inputChannels = null;
  let stats = {};
  // Doppler vs. time
  let procMode = 'rti';        // which chain gets the live audio: 'rti' (Radar, Diagnostics) or 'dti' (Doppler vs. time)
  let dt = null, dtSel = null, dtBusy = false, dtImage = null;
  let suggestion = null;
  let levelHistory = [], lastTopChange = 0;
  const rti = new P.RTIBuffer();

  worker.onmessage = (e) => {
    const m = e.data;
    if (m.type === 'snapshot') apply(m.s);
    else if (m.type === 'rdInput') {
      const inp = m.inp, tr = [inp.bre.buffer, inp.bim.buffer];
      if (inp.fre) tr.push(inp.fre.buffer, inp.fim.buffer);
      rdWorker.postMessage({ inp }, tr);
    } else if (m.type === 'dt') {
      dt = m.snap;
      if (dtSel != null && dtSel >= dt.nRows) dtSel = null;
      dtBusy = false;
      buildDTImage();
      requestDraw();
    } else if (m.type === 'fs') {
      fs = m.fs; d = C.derived(params, fs);
    } else if (m.type === 'fileDone') {
      setStatus(`Finished playing ${fileName}.`);
    }
  };
  rdWorker.onmessage = (e) => {
    const map = e.data.map;
    worker.postMessage({ type: 'rdDone', ms: map ? map.ms : 0 });
    if (!map || map.generation !== generation) return;
    rangeDoppler = map;
    const cv = document.createElement('canvas');
    cv.width = map.nr; cv.height = map.rows;
    cv.getContext('2d').putImageData(new ImageData(map.rgba, map.nr, map.rows), 0, 0);
    rdImage = cv;
    requestDraw();
  };
  // the RTI displays only change while the RTI chain runs (as in the Mac app)
  setInterval(() => { if (!document.hidden && procMode === 'rti') worker.postMessage({ type: 'poll' }); }, 33);

  // ---------------- snapshots ----------------
  const rtiPulses = () => Math.round(params.rtiSeconds * 1000 / (2 * params.tpMs));
  const viewSecondsShown = () => params.rtiViewSeconds > 0 ? Math.min(params.rtiViewSeconds, params.rtiSeconds) : params.rtiSeconds;
  const viewPulses = () => Math.round(viewSecondsShown() * 1000 / (2 * params.tpMs));
  function resetRTI(width) { rti.reset(width, rtiPulses(), viewPulses(), params.dbTop, params.rtiDbRange); }

  function apply(s) {
    if (s.droppedFrames > 0 && source === 'live') {
      droppedSeconds += s.droppedFrames / fs;
      setStatus(`Processing can't keep up with real time: ${droppedSeconds.toFixed(1)} s of audio skipped so far. Try fewer options (matrix pencil, SVA, PGA).`, true);
    }
    if (s.generation !== generation) {
      generation = s.generation;
      resetRTI(s.derived.nfft / 2);
      levelHistory = [];
      rangeDoppler = null; rdImage = null;
    }
    updateAutoTop(s.newRows);
    for (const row of s.newRows) rti.append(row, params.dbTop, params.rtiDbRange);
    if (!source && !s.newRows.length && !s.scope) return;
    trace = s.traceDB || null;
    hold = s.holdDB || null;
    if (s.scope) scope = s.scope;
    if (s.edge) edge = s.edge;
    pgaPhase = s.pgaPhase || null; pgaUpdates = s.pgaUpdates || 0; pgaAccepted = s.pgaAccepted || 0; pgaAgreement = s.pgaAgreement;
    pencilTargets = s.pencilTargets || []; pencilOrder = s.pencilOrder; pencilMs = s.pencilMs;
    pulseCount = s.pulseCount; rdCollected = s.rdCollected || 0;
    slips = s.slips || 0;
    if (s.inputChannels) inputChannels = s.inputChannels;
    const st = stats;
    if (s.pulseRateHz != null) { st.pulseRateHz = s.pulseRateHz; st.periodMs = s.periodMs; st.jitterIntegerUs = s.jitterIntegerUs; st.jitterInterpUs = s.jitterInterpUs; }
    st.levelL = Math.max(s.peakL || 0, (st.levelL || 0) * 0.85);
    st.levelR = Math.max(s.peakR || 0, (st.levelR || 0) * 0.85);
    if (trace) { const r = strongestReturn(trace); st.peakRange = r[0]; st.peakDB = r[1]; }
    updateSuggestion(s);
    renderStats();
    requestDraw();
  }

  /** Moves the top dB to follow the 90th percentile of the per-pulse peak over the last 10 s (5 dB steps, at most every 5 s). */
  function updateAutoTop(rows) {
    const now = performance.now() / 1000;
    const hi = Math.min(d.nBins, rows.length ? rows[0].length : 0);
    if (hi > 2) for (const row of rows) { let m = -200; for (let k = 1; k < hi; k++) if (row[k] > m) m = row[k]; levelHistory.push([now, m]); }
    levelHistory = levelHistory.filter(x => now - x[0] <= 10);
    if (!params.autoTop || levelHistory.length < 25 || now - lastTopChange < 5) return;
    const sorted = levelHistory.map(x => x[1]).sort((a, b) => a - b);
    const level = sorted[Math.floor((sorted.length - 1) * 0.9)];
    const target = Math.ceil((level + 3) / 5) * 5;
    if (target > params.dbTop || target < params.dbTop - 10) { lastTopChange = now; setParams({ dbTop: target }); }
  }

  function strongestReturn(db) {
    const first = Math.max(1, Math.ceil(0.5 / d.metersPerBin)), nb = Math.min(db.length, d.nBins);
    if (first >= nb - 1) return [null, null];
    let kb = first;
    for (let k = first; k < nb; k++) if (db[k] > db[kb]) kb = k;
    let kf = kb;
    if (kb > 0 && kb + 1 < nb) {
      const a = db[kb - 1], b = db[kb], c = db[kb + 1], den = a - 2 * b + c;
      if (den < 0) kf += 0.5 * (a - c) / den;
    }
    return [kf * d.metersPerBin, db[kb]];
  }

  function updateSuggestion(s) {
    if (source !== 'live' || s.squarenessTrigger == null) return;
    const sqT = s.squarenessTrigger, sqI = s.squarenessIF;
    let next = null;
    if (sqT < 0.5 && sqI > 0.65) next = { kind: 'swap', toRight: !params.syncOnRight };
    else if (sqT > 0.65 && stats.periodMs && stats.pulseRateHz > 1) {
      const tp = Math.round(stats.periodMs / 2 * 100) / 100;
      if (Math.abs(tp - params.tpMs) / params.tpMs > 0.05) next = { kind: 'tp', tp };
    }
    if (JSON.stringify(next) !== JSON.stringify(suggestion)) { suggestion = next; showSuggestion(); }
  }

  function showSuggestion() {
    const el = $('suggestion');
    if (!suggestion) { el.hidden = true; return; }
    let msg, action;
    if (suggestion.kind === 'swap') {
      msg = suggestion.toRight ? 'The sync square wave appears to be on the RIGHT input and the IF on the LEFT.' : 'The sync square wave appears to be on the LEFT input and the IF on the RIGHT.';
      action = suggestion.toRight ? 'Use right input for sync' : 'Use left input for sync';
    } else {
      msg = `The sync period is ${(2 * suggestion.tp).toFixed(2)} ms, so each up-chirp (sync high) lasts about ${suggestion.tp.toFixed(2)} ms.`;
      action = `Set Tp to ${suggestion.tp.toFixed(2)} ms`;
    }
    el.innerHTML = '';
    el.append('⚠️ ', document.createTextNode(msg));
    const b = document.createElement('button');
    b.className = 'primary small'; b.textContent = action;
    b.onclick = () => {
      const sg = suggestion; suggestion = null; showSuggestion(); stats = {};
      if (sg.kind === 'swap') setParams({ syncOnRight: sg.toRight }); else setParams({ tpMs: sg.tp });
    };
    el.append(b);
    el.hidden = false;
  }

  // ---------------- status and stats ----------------
  function setStatus(text, error) { const el = $('status'); el.textContent = text; el.classList.toggle('error', !!error); }

  function renderStats() {
    const u = unit(), s = stats;
    const clip = (s.levelL || 0) > 0.99 || (s.levelR || 0) > 0.99;
    const dbfs = v => v > 0 ? (20 * Math.log10(v)).toFixed(1) : '−∞';
    const tiles = [
      ['Sample rate / N', `${(d.fs / 1000).toFixed(1)} kHz / ${d.n}`],
      ['Range res. / max range', `${(d.rangeRes * u.finePer).toFixed(1)} ${u.fineAb} / ${(d.maxRange * u.per).toFixed(1)} ${u.ab}`],
      ['Pulse rate', s.pulseRateHz != null ? `${s.pulseRateHz.toFixed(2)} Hz (${s.periodMs.toFixed(3)} ms)` : '–'],
      ['Period jitter σ: integer → interp.', s.jitterIntegerUs != null ? `${s.jitterIntegerUs.toFixed(2)} → ${s.jitterInterpUs.toFixed(2)} µs` : '–'],
      ['Audio glitches skipped', source ? `${slips} pulse${slips === 1 ? '' : 's'}${captureMode ? (captureMode === 'direct' ? ' · direct' : ' · audio engine') : ''}` : '–'],
      ['Peak level L / R', `${dbfs(s.levelL)} / ${dbfs(s.levelR)} dBFS${clip ? '  CLIP' : ''}`, clip],
      ['Strongest return', s.peakRange != null ? `${(s.peakRange * u.per).toFixed(2)} ${u.ab} @ ${s.peakDB.toFixed(1)} dB` : '–'],
    ];
    $('stats').innerHTML = tiles.map(t => `<div class="tile${t[2] ? ' warn' : ''}"><div class="t">${t[0]}</div><div class="v">${t[1]}</div></div>`).join('');
  }

  // ---------------- audio sources ----------------
  let audioCtx = null, stream = null, devices = [], userPickedDevice = localStorage.getItem('ccr.device') || '';
  let fileName = '';
  let captureMode = null;   // 'direct' (MediaStreamTrackProcessor) or 'worklet' (AudioWorklet)
  let slips = 0;
  const looksLikeUCA = dv => /USB Audio CODEC|UCA ?2[02]2|Behringer/i.test(dv.label);
  const WORKLET = `class CCRCapture extends AudioWorkletProcessor {
  constructor() { super(); this.out = null; this.N = 2048; this.l = new Float32Array(this.N); this.r = new Float32Array(this.N); this.n = 0; this.frame = 0;
    this.port.onmessage = e => { if (e.data && e.data.port) this.out = e.data.port; }; }
  process(inputs) {
    const inp = inputs[0], len = inp && inp[0] ? inp[0].length : 128;
    if (inp && inp.length) {
      const a = inp[0], b = inp.length > 1 ? inp[1] : inp[0];
      for (let i = 0; i < a.length; i++) {
        this.l[this.n] = a[i]; this.r[this.n] = b[i]; this.n++;
        if (this.n === this.N) {
          if (this.out) this.out.postMessage({ l: this.l, r: this.r, frame: this.frame + i + 1 - this.N, ch: inp.length }, [this.l.buffer, this.r.buffer]);
          this.l = new Float32Array(this.N); this.r = new Float32Array(this.N); this.n = 0;
        }
      }
    }
    this.frame += len;
    return true;
  }
}
registerProcessor('ccr-capture', CCRCapture);`;

  async function refreshDevices() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
    devices = (await navigator.mediaDevices.enumerateDevices()).filter(x => x.kind === 'audioinput');
    const sel = $('device');
    const prev = sel.value || userPickedDevice;
    sel.innerHTML = '';
    if (!devices.length) sel.append(new Option('No audio inputs', ''));
    devices.forEach((dv, i) => sel.append(new Option(dv.label || (i === 0 ? 'Default input (press Start to see names)' : `Input ${i + 1}`), dv.deviceId)));
    const uca = devices.find(looksLikeUCA);
    if (prev && devices.some(x => x.deviceId === prev)) sel.value = prev;
    else if (uca) sel.value = uca.deviceId;
  }

  function stopAll() {
    worker.postMessage({ type: 'stop' });
    if (stream) { stream.getTracks().forEach(t => t.stop()); stream = null; }
    if (audioCtx) { audioCtx.close(); audioCtx = null; }
    if (source) setStatus('Stopped.');
    source = null; paused = false;
    updateToolbar();
  }

  function beginSource(kind, newFs) {
    captureMode = null; slips = 0;
    fs = newFs;
    d = C.derived(params, fs);
    source = kind; paused = false; stats = {}; suggestion = null; showSuggestion(); droppedSeconds = 0; inputChannels = null;
    updateToolbar();
  }

  async function openStream(deviceId) {
    return navigator.mediaDevices.getUserMedia({ audio: {
      deviceId: deviceId ? { exact: deviceId } : undefined, channelCount: { ideal: 2 },
      echoCancellation: false, noiseSuppression: false, autoGainControl: false, sampleRate: { ideal: 48000 },
    } });
  }

  async function startLive() {
    stopAll();
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setStatus('This browser can\'t read audio inputs here. Open the page over https (or from localhost), in Chrome, Edge, Firefox or Safari.', true);
      return;
    }
    try {
      setStatus('Asking for access to the audio input…');
      let chosen = $('device').value;
      stream = await openStream(chosen);
      await refreshDevices();
      // after access is granted the names are known: prefer the UCA222 unless the user chose another input
      const uca = devices.find(looksLikeUCA);
      const trackId = stream.getAudioTracks()[0].getSettings().deviceId;
      if (!userPickedDevice && uca && trackId !== uca.deviceId) {
        stream.getTracks().forEach(t => t.stop());
        stream = await openStream(uca.deviceId);
        $('device').value = uca.deviceId;
      }
      const track = stream.getAudioTracks()[0], st = track.getSettings();
      const name = track.label || 'audio input';
      const chans = st.channelCount;
      const chText = chans === 1 ? '' : `${chans ? `, ${chans} ch` : ''}`;
      if (window.MediaStreamTrackProcessor && !/[?&]capture=worklet/.test(location.search)) {
        // Chrome, Edge: read the interface directly in the DSP thread (no audio engine, no clock drift)
        const mstp = new MediaStreamTrackProcessor({ track });
        beginSource('live', st.sampleRate || 48000);
        worker.postMessage({ type: 'liveDirect', readable: mstp.readable, fs: st.sampleRate || 48000, params }, [mstp.readable]);
        captureMode = 'direct';
        if (chans === 1) setStatus(`${name} is delivering only 1 channel. Trigger and IF need stereo: choose the interface's stereo input.`, true);
        else setStatus(`Live: ${name}, ${st.sampleRate || 48000} Hz${chText}, read directly.`);
        return;
      }
      captureMode = 'worklet';
      audioCtx = new AudioContext(st.sampleRate ? { sampleRate: st.sampleRate, latencyHint: 'interactive' } : { latencyHint: 'interactive' });
      const url = URL.createObjectURL(new Blob([WORKLET], { type: 'text/javascript' }));
      await audioCtx.audioWorklet.addModule(url);
      const src = audioCtx.createMediaStreamSource(stream);
      const node = new AudioWorkletNode(audioCtx, 'ccr-capture', { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1],
        channelCount: 2, channelCountMode: 'explicit', channelInterpretation: 'discrete' });
      const mute = audioCtx.createGain();
      mute.gain.value = 0;
      src.connect(node); node.connect(mute); mute.connect(audioCtx.destination);
      if (audioCtx.state === 'suspended') await audioCtx.resume();
      const ch = new MessageChannel();
      node.port.postMessage({ port: ch.port1 }, [ch.port1]);
      beginSource('live', audioCtx.sampleRate);
      worker.postMessage({ type: 'live', port: ch.port2, fs: audioCtx.sampleRate, params }, [ch.port2]);
      if (chans === 1) setStatus(`${name} is delivering only 1 channel. Trigger and IF need stereo: choose the interface's stereo input.`, true);
      else setStatus(`Live: ${name}, ${audioCtx.sampleRate} Hz${chText}, through the browser's audio engine.`);
    } catch (err) {
      stopAll();
      const denied = err && (err.name === 'NotAllowedError' || err.name === 'SecurityError');
      setStatus(denied ? 'Microphone access was refused. Allow this page to use the microphone (the address bar\'s site settings), then press Start.'
        : `Audio start failed: ${err && err.message ? err.message : err}`, true);
    }
  }

  function startSim() {
    stopAll();
    beginSource('sim', 48000);
    worker.postMessage({ type: 'sim', params });
    setStatus('Simulation. Radar tab: FMCW targets at 8 m (fixed), 13–37 m (moving) and 60 m, the sync period not a whole number of samples. Doppler tab: unmodulated CW, a car passing at 28 m/s and slowing to 8 m/s every 25 s, and a person walking at 1.4 m/s.');
  }

  /** Reads a PCM (16/24-bit) or float (32-bit) stereo .wav. */
  function parseWav(buf) {
    const b = new Uint8Array(buf), dv = new DataView(buf);
    const tag = o => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);
    if (tag(0) !== 'RIFF' || tag(8) !== 'WAVE') return null;
    let off = 12, fmt = null, data = null;
    while (off + 8 <= b.length) {
      const id = tag(off), size = dv.getUint32(off + 4, true);
      if (id === 'fmt ') fmt = { format: dv.getUint16(off + 8, true), channels: dv.getUint16(off + 10, true), fs: dv.getUint32(off + 12, true), bits: dv.getUint16(off + 22, true) };
      if (id === 'data') { data = { off: off + 8, size: Math.min(size, b.length - off - 8) }; break; }
      off += 8 + size + (size & 1);
    }
    if (!fmt || !data) return null;
    if (fmt.format === 0xFFFE) fmt.format = fmt.bits === 32 ? 3 : 1;   // WAVE_FORMAT_EXTENSIBLE (assume PCM / float)
    const ch = fmt.channels, bytes = fmt.bits / 8, frames = Math.floor(data.size / (ch * bytes));
    const left = new Float32Array(frames), right = new Float32Array(frames);
    const rd = (p) => {
      if (fmt.format === 3 && fmt.bits === 32) return dv.getFloat32(p, true);
      if (fmt.bits === 16) return dv.getInt16(p, true) / 32768;
      if (fmt.bits === 24) { let v = b[p] | (b[p + 1] << 8) | (b[p + 2] << 16); if (v & 0x800000) v -= 0x1000000; return v / 8388608; }
      if (fmt.bits === 32) return dv.getInt32(p, true) / 2147483648;
      throw new Error('unsupported .wav sample format');
    };
    for (let i = 0; i < frames; i++) {
      const p = data.off + i * ch * bytes;
      left[i] = rd(p); right[i] = ch > 1 ? rd(p + bytes) : left[i];
    }
    return { fs: fmt.fs, channels: ch, left, right };
  }

  async function openFile(file) {
    stopAll();
    fileName = file.name;
    setStatus(`Reading ${file.name}…`);
    try {
      const buf = await file.arrayBuffer();
      let w = parseWav(buf);
      if (!w) {
        const ctx = new AudioContext();
        const ab = await ctx.decodeAudioData(buf.slice(0));
        w = { fs: ab.sampleRate, channels: ab.numberOfChannels, left: ab.getChannelData(0), right: ab.getChannelData(Math.min(1, ab.numberOfChannels - 1)) };
        ctx.close();
      }
      if (w.channels < 2) { setStatus(`${file.name} has one channel: the trigger and IF need a stereo recording.`, true); return; }
      beginSource('file', w.fs);
      const secs = w.left.length / w.fs;
      worker.postMessage({ type: 'file', left: w.left, right: w.right, fs: w.fs, params, speed: 1 }, [w.left.buffer, w.right.buffer]);
      setStatus(`Playing ${file.name} in real time: ${secs.toFixed(1)} s at ${w.fs} Hz.`);
    } catch (err) {
      setStatus(`Couldn't read ${file.name}: ${err && err.message ? err.message : err}`, true);
    }
  }

  function updateToolbar() {
    const sar = typeof activeTab !== 'undefined' && activeTab === 'sar';
    $('sar-open-tb').hidden = !sar; $('sar-process-tb').hidden = !sar;
    $('device').hidden = sar; $('refresh').hidden = sar;
    if (sar) { for (const id of ['start', 'simulate', 'openfile', 'pause', 'stop']) $(id).hidden = true; return; }
    const running = !!source;
    $('start').hidden = running; $('simulate').hidden = running; $('openfile').hidden = running;
    $('pause').hidden = !running; $('stop').hidden = !running;
    $('pause').textContent = paused ? 'Resume' : 'Pause';
  }

  $('start').onclick = startLive;
  $('simulate').onclick = startSim;
  $('openfile').onclick = () => $('fileinput').click();
  $('fileinput').onchange = (e) => { const f = e.target.files[0]; e.target.value = ''; if (f) (activeTab === 'doppler' ? openDopplerFile : openFile)(f); };
  $('stop').onclick = stopAll;
  $('pause').onclick = () => { paused = !paused; worker.postMessage({ type: 'pause', paused }); updateToolbar(); };
  $('refresh').onclick = refreshDevices;
  $('device').onchange = () => {
    userPickedDevice = $('device').value;
    try { localStorage.setItem('ccr.device', userPickedDevice); } catch (e) { /* ignore */ }
    if (source === 'live') startLive();
  };
  if (navigator.mediaDevices && navigator.mediaDevices.addEventListener) navigator.mediaDevices.addEventListener('devicechange', refreshDevices);
  refreshDevices();

  // ---------------- tabs and sliders ----------------
  let activeTab = 'radar';
  const TABS = ['radar', 'doppler', 'sar', 'diag', 'how'];
  function showTab(tab) {
    activeTab = TABS.includes(tab) ? tab : 'radar';
    try { localStorage.setItem('ccr.tab', activeTab); } catch (e) { /* ignore */ }
    document.querySelectorAll('#tabs button').forEach(x => x.classList.toggle('active', x.dataset.tab === activeTab));
    for (const t of TABS) $('tab-' + t).hidden = t !== activeTab;
    // only the selected tab's chain runs; How it works leaves it as it was
    const m = activeTab === 'doppler' ? 'dti' : activeTab === 'sar' ? 'sar' : activeTab === 'how' ? procMode : 'rti';
    if (m !== procMode) { procMode = m; worker.postMessage({ type: 'mode', mode: m }); }
    $('stats').hidden = !(activeTab === 'radar' || activeTab === 'diag' || (activeTab === 'how' && procMode === 'rti'));
    $('status').hidden = activeTab === 'sar';   // the SAR tab has its own status line
    $('suggestion').hidden = activeTab === 'sar' || !suggestion;
    if (activeTab === 'how') renderHow();
    updateToolbar();
    refreshSidebar();
    requestDraw();
  }
  document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => showTab(b.dataset.tab));

  let showDopplerPGA = false;
  document.querySelectorAll('#pga-switch button').forEach(b => b.onclick = () => {
    showDopplerPGA = b.dataset.v === 'doppler';
    document.querySelectorAll('#pga-switch button').forEach(x => x.classList.toggle('active', x === b));
    requestDraw();
  });

  function syncControls() {
    const u = unit();
    const lower = Math.min(d.maxRange, Math.max(1, 8 * d.metersPerBin));
    const mr = $('maxrange');
    mr.min = lower; mr.max = Math.max(lower + 1, d.maxRange); mr.step = (d.maxRange - lower) / 1000;
    const shown = params.maxRangeShown > 0 ? Math.min(params.maxRangeShown, d.maxRange) : d.maxRange;
    if (document.activeElement !== mr) mr.value = shown;
    $('maxrange-val').textContent = `${(shown * u.per).toFixed(1)} ${u.ab}`;
    $('maxrange-full').disabled = params.maxRangeShown === 0;
    $('rti-range').value = params.rtiDbRange; $('rti-range-val').textContent = `${params.rtiDbRange} dB`;
    const span = $('rti-span');
    span.min = Math.log10(0.5); span.max = Math.log10(params.rtiSeconds); span.step = 0.001;
    if (document.activeElement !== span) span.value = Math.log10(viewSecondsShown());
    const vs = viewSecondsShown();
    $('rti-span-val').textContent = vs < 10 ? `${vs.toFixed(1)} s` : `${vs.toFixed(0)} s`;
    $('rd-range').value = params.rdDbRange; $('rd-range-val').textContent = `${params.rdDbRange} dB`;
    $('rd-card').hidden = !params.rdEnabled;
  }
  $('maxrange').oninput = (e) => { const v = +e.target.value; setParams({ maxRangeShown: v >= d.maxRange * 0.999 ? 0 : Math.round(v * 10) / 10 }); };
  $('maxrange-full').onclick = () => setParams({ maxRangeShown: 0 });
  $('rti-range').oninput = (e) => setParams({ rtiDbRange: Math.round(+e.target.value) });
  $('rti-span').oninput = (e) => {
    const s = Math.pow(10, +e.target.value), r = s < 10 ? Math.round(s * 10) / 10 : Math.round(s);
    setParams({ rtiViewSeconds: r >= params.rtiSeconds ? 0 : r });
  };
  $('rd-range').oninput = (e) => setParams({ rdDbRange: Math.round(+e.target.value) });

  // ---------------- sidebar ----------------
  const isPencil = () => params.rangeMethod === 'Matrix pencil';
  const ORDER_RULES = ['ESTER (adaptive)', 'Largest singular-value gap (adaptive)', 'Singular-value threshold'];
  const ORDER_RULES_DT = ORDER_RULES;
  function vcoSummary() {
    const bw = `BW ${(params.fStopMHz - params.fStartMHz).toFixed(1)} MHz`;
    const v0 = C.VCO.volts(params.fStartMHz), v1 = C.VCO.volts(params.fStopMHz);
    if (v0 == null || v1 == null) return `${bw}. Outside the ${C.VCO.name} range (${C.VCO.minMHz.toFixed(1)}–${C.VCO.maxMHz.toFixed(1)} MHz for 0–5 V).`;
    return `${bw}. ${C.VCO.name} tuning ≈ ${v0.toFixed(2)}–${v1.toFixed(2)} V (typ. +25 °C curve).`;
  }
  function rdSummary() {
    const pri = 2 * params.tpMs / 1000, lam = C.wavelength(params);
    const vMax = lam / (4 * pri), dv = lam / 2 / (params.rdPulses * pri);
    return `One pulse every ${(pri * 1000).toFixed(0)} ms (${(1 / pri).toFixed(0)} Hz), λ = ${(lam * 100).toFixed(1)} cm: velocities up to ±${vMax.toFixed(2)} m/s are unambiguous, resolution ${dv.toFixed(3)} m/s. Each range bin of the newest pulses gets a slow-time FFT; + is approaching. The background setting in Processing applies first.`;
  }
  const isDT = () => activeTab === 'doppler';
  const isSAR = () => activeTab === 'sar';
  const notSAR = () => activeTab !== 'sar';
  const dtPencil = () => params.dtMethod === 'Matrix pencil';
  const MPH = 2.236936;
  function dtVCOText() {
    const lam = C.speedOfLight / (Math.max(100, params.dtCarrierMHz) * 1e6);
    const v = C.VCO.volts(params.dtCarrierMHz);
    return (v != null ? `Vtune ≈ ${v.toFixed(2)} V on the ${C.VCO.name} typical curve. ` : 'Outside the VCO\'s 0–5 V range. ') + `λ = ${(lam * 100).toFixed(2)} cm.`;
  }
  function dtSummary() {
    const lam = C.speedOfLight / (Math.max(100, params.dtCarrierMHz) * 1e6), tp = Math.max(0.02, params.dtDwellMs / 1000);
    return `Doppler resolution 1/Tp = ${(1 / tp).toFixed(1)} Hz = ${(lam / (2 * tp)).toFixed(3)} m/s (${(lam / (2 * tp) * MPH).toFixed(2)} mph). ${params.dtMaxVelocity} m/s is a ${(2 * params.dtMaxVelocity / lam).toFixed(0)} Hz Doppler. The colour scale is relative to the strongest cell shown, as in MIT's plot (−35…0 dB).`;
  }
  const SECTIONS = [
    { title: () => 'Doppler vs. time (CW)', when: isDT, items: [
      { type: 'help', text: () => `Run the radar unmodulated: hold the VCO's Vtune at a fixed voltage instead of the ramp. Only the IF (${params.syncOnRight ? 'left' : 'right'} input) is used, cut into dwells of Tp as in MIT's read_data_doppler.m. The IF is real, so approaching and receding targets both show as positive speed.` },
      { k: 'syncOnRight', label: 'IF input', type: 'sel', opts: [[false, 'Right (as MIT\'s recordings)'], [true, 'Left']] },
      { k: 'dtCarrierMHz', label: 'Carrier fc (MHz)', type: 'num' },
      { type: 'buttons', buttons: [['+5 V: 2590 MHz', () => setParams({ dtCarrierMHz: 2590 })], ['+3.2 V (ISM): 2495 MHz', () => setParams({ dtCarrierMHz: 2495 })]] },
      { type: 'help', text: dtVCOText },
      { k: 'dtDwellMs', label: 'Dwell Tp (ms)', type: 'num' },
      { k: 'dtOverlap', label: 'Overlap', type: 'sel', opts: [[0, 'None (MIT)'], [0.5, '50%'], [0.75, '75%'], [0.875, '87.5%']] },
      { type: 'help', text: () => `A new row every ${(params.dtDwellMs * (1 - params.dtOverlap)).toFixed(0)} ms. Overlapping dwells (a sliding window) make the plot smoother in time and use the samples a tapering window or SVA would otherwise weight down at the dwell edges; each row still spans Tp, so the velocity resolution is unchanged. Costs ${(1 / Math.max(0.0625, 1 - params.dtOverlap)).toFixed(0)}× the processing.` },
      { k: 'dtMaxVelocity', label: 'Max velocity shown (m/s)', type: 'num' },
      { k: 'dtMethod', label: 'Spectrum', type: 'sel', opts: ['FFT', 'Matrix pencil'] },
      { k: 'dtOrderRule', label: 'Model order', type: 'sel', opts: ORDER_RULES_DT, when: dtPencil },
      { k: 'dtMaxTargets', label: 'Max targets (cap)', type: 'int', when: dtPencil },
      { k: 'dtPencilDisplay', label: 'Display', type: 'sel', opts: ['Pseudospectrum', 'Amplitude-weighted lines'], when: dtPencil },
      { type: 'help', when: dtPencil, text: () => 'Each dwell\'s analytic IF is band-limited to 0 … max velocity and decimated (in the frequency domain) to a few hundred samples, then fitted as a sum of complex exponentials (TLS matrix pencil, one pole per mover). ▼ marks the poles on the spectrum. ESTER threshold, forward–backward averaging, the singular-value threshold and the peak half-width come from Range estimator (Radar tab). Window and SVA don\'t apply.' },
      { k: 'dtSVA', label: 'SVA (spatially variant apodization)', type: 'bool', when: () => !dtPencil() },
      { k: 'dtWindow', label: 'Window', type: 'sel', opts: ['Rectangular', 'Hann', 'Blackman', 'Taylor'], when: () => !dtPencil(), disabled: () => params.dtSVA },
      { type: 'help', when: () => !dtPencil() && params.dtSVA, text: () => 'SVA picks a weighting per velocity bin between rectangular and Hann: rectangular-window resolution with Hann-level sidelobes, so a loud car doesn\'t hide a quieter one beside it.' },
      { k: 'dtZeroPad', label: 'Zero-pad (× N)', type: 'sel', opts: [1, 2, 4, 8].map(v => [v, String(v)]) },
      { k: 'dtPGA', label: 'PGA on the strongest mover', type: 'bool' },
      { k: 'dtPGAMinVelocity', label: 'Ignore slower than (m/s)', type: 'num', when: () => params.dtPGA },
      { type: 'help', when: () => params.dtPGA, text: () => 'Prominent-point phase gradient autofocus in each dwell: the strongest line above this speed (if it stands 20 dB above the median) is shifted to zero Doppler, windowed and its phase wander (acceleration, oscillator drift, vibration) estimated and removed, keeping its mean velocity. A dwell\'s correction is kept only if its spectrum gets sharper. It focuses that mover; others in the same dwell get the same correction.' },
      { k: 'dtSubtractMean', label: 'Subtract mean (DC)', type: 'bool' },
      { k: 'dtHistorySeconds', label: 'Live history kept', type: 'sel', opts: [30, 60, 120, 300].map(v => [v, `${v} s`]) },
      { type: 'help', text: dtSummary },
    ] },
    { title: () => 'SAR recording', when: isSAR, items: [
      { type: 'html', html: () => sarFile ? `<b>${escapeHTML(sarFile.name)}</b><br>${sarFile.seconds.toFixed(1)} s, ${sarFile.fs} Hz, 2 channels` : 'No recording open. MIT\'s example data set (Experiment 3, towardswarehouse.wav) is on the MIT OCW course page.' },
      { type: 'buttons', buttons: [['Open…', () => $('sar-fileinput').click()], ['Process', () => sarProcess()]] },
    ] },
    { title: () => 'Parsing (SBAND_RMA_opendata.m)', when: isSAR, items: [
      { sar: true, k: 'syncOnRight', label: 'Sync input', type: 'sel', opts: [[false, 'Left (IF on right)'], [true, 'Right (IF on left)']] },
      { sar: true, k: 'invert', label: 'Invert inputs', type: 'bool' },
      { sar: true, k: 'tpMs', label: 'Up-chirp time Tp (ms)', type: 'num' },
      { sar: true, k: 'trpSeconds', label: 'Min. time per position Trp (s)', type: 'num' },
      { sar: true, k: 'syncThreshold', label: 'Sync threshold', type: 'num' },
      { sar: true, k: 'chirpsPerPosition', label: 'Up-chirps per position (0 = MIT)', type: 'int' },
      { sar: true, k: 'alignment', label: 'Pulse alignment', type: 'sel', opts: ['Sub-sample edge (RTI interpolation)', 'Integer sample (MIT script)'] },
      { sar: true, k: 'interpolation', label: 'Edge interpolation', type: 'sel', opts: [10, 16, 32, 64, 128].map(v => [v, v + '×']), when: () => sarParams.alignment !== S.MIT_ALIGN },
      { sar: true, k: 'holdoff', label: 'Samples low before edge', type: 'int', when: () => sarParams.alignment !== S.MIT_ALIGN },
      { type: 'help', text: () => 'Every position averages exactly this many up-chirps (the first complete ones), so all positions have the same integration and noise level; uneven averaging across the aperture shows up as azimuth clutter. If a position has fewer, every position uses that smaller number. 0 reproduces MIT\'s script: all chirps in the first Trp, which varies by position.' },
      { type: 'help', text: () => sarParams.alignment !== S.MIT_ALIGN
        ? 'A new aperture position starts where the sync channel comes back after at least Trp of silence. In each position, every rising sync edge is found as in the RTI tab: upsampled with a windowed-sinc interpolator, refined linearly to the threshold crossing, and each up-chirp is resampled to start exactly at that sub-sample time. The chirps are averaged, then Hilbert-transformed to N/2 complex samples.'
        : 'A new aperture position starts where the sync channel comes back after at least Trp of silence. In each position, every up-chirp is cut at the integer sample where the sync peaks after a rising edge (as SBAND_RMA_opendata.m does), averaged, then Hilbert-transformed to N/2 complex samples.' },
    ] },
    { title: () => 'Radar (SAR)', when: isSAR, items: [
      { sar: true, k: 'fStartMHz', label: 'f start (MHz)', type: 'num' },
      { sar: true, k: 'fStopMHz', label: 'f stop (MHz)', type: 'num' },
      { sar: true, k: 'fullFOV', label: '1-inch spacing: full ±90° field of view', type: 'bool',
        onSet: on => setSarParams({ fullFOV: on, spacingInches: on ? 1 : 2, crossRangeFt: on ? sarParams.downStopFt : 200 }) },
      { sar: true, k: 'spacingInches', label: 'Antenna spacing (in)', type: 'num' },
      { type: 'help', when: () => sarParams.fullFOV, text: () => '⚠️ Only for recordings made with 1-inch steps along the rail. MIT\'s example (towardswarehouse.wav) used 2-inch steps, so this setting puts its positions in the wrong places.' + (sarParams.algorithm === S.RMA ? ` Range migration can only show ±${(sarParams.zpad * S.deltaX(sarParams) * S.FT_PER_M / 2).toFixed(0)} ft with this zero pad; backprojection shows the full field.` : '') },
      { type: 'help', when: () => !sarParams.fullFOV && sarParams.spacingInches > lambdaQuarterIn(), text: () => `💡 Suggestion: move the radar 1 inch between positions when recording. ${sarParams.spacingInches}-inch steps are wider than λ/4 (${lambdaQuarterIn().toFixed(2)} in at ${sarParams.fStopMHz} MHz), so the aperture aliases beyond ±${(S.gratingLobeFreeAngle(sarParams) * 180 / Math.PI).toFixed(0)}° and the image is blanked there. With 1-inch steps there are no grating lobes and the image covers the full ±90°; turn on "1-inch spacing" above for those recordings.` },
    ] },
    { title: () => 'Image formation', when: isSAR, items: [
      { sar: true, k: 'algorithm', label: 'Algorithm', type: 'sel', opts: ['Backprojection (AFRL bpBasic.m)', 'Range migration (MIT SBAND_RMA_IFP.m)'] },
      { sar: true, k: 'subtractMean', label: 'Subtract mean over the aperture', type: 'bool' },
      { sar: true, k: 'mitMean', label: 'Use MIT\'s running mean', type: 'bool', when: () => sarParams.subtractMean },
      { sar: true, k: 'rangePGA', label: 'Range PGA (fast time)', type: 'bool' },
      { sar: true, k: 'crossPGA', label: 'Crossrange autofocus (per position)', type: 'bool' },
      { sar: true, k: 'pgaIterations', label: 'Autofocus iterations', type: 'int', when: () => sarParams.rangePGA || sarParams.crossPGA },
      { type: 'help', when: () => sarParams.rangePGA || sarParams.crossPGA, text: () => 'Both run before image formation, so they apply to either algorithm, and before SVA. Range PGA: each position\'s strongest return is centred and windowed, and the phase gradient over frequency is summed over positions. Crossrange: the strongest scatterers in a quick image are picked, and each position\'s phase is set to add coherently to them with the others. Linear trends are removed, so the image doesn\'t shift. The estimates are plotted under Autofocus.' },
      { sar: true, k: 'sva', label: 'SVA (spatially variant apodization)', type: 'bool' },
      { sar: true, k: 'svaMode', label: 'SVA type', type: 'sel', opts: ['Joint I/Q', 'I and Q separately (Stankwitz)', 'Dual apodization (rect/Hann minimum)'], when: () => sarParams.sva },
      { sar: true, k: 'svaHannCap', label: 'Limit by the Hann image', type: 'bool', when: () => sarParams.sva && sarParams.svaMode !== 'Dual apodization (rect/Hann minimum)' },
      { type: 'help', when: () => sarParams.sva, text: () => 'SVA replaces the Hann windows (the data are processed unweighted). It runs on the complex image: for every pixel it looks one null away, c/2B along the line of sight from the aperture and λR/(2L·cos θ) across it, and picks the raised-cosine weight between rectangular and Hann that gives the smallest output (Stankwitz, Dallaire & Fienup 1995). Joint I/Q picks one weight per complex pixel; separate I/Q (the original SVA) one each for I and Q; dual apodization keeps the smaller of the unweighted and Hann images. Limiting by the Hann image stops slowly decaying unweighted range sidelobes showing as radial streaks at far range.' },
      { sar: true, k: 'bpHann', label: 'Hann window over frequency', type: 'bool', when: () => sarParams.algorithm !== S.RMA, disabled: () => sarParams.sva },
      { sar: true, k: 'bpNfft', label: 'Range FFT size (Nfft)', type: 'sel', opts: [2048, 4096, 8192, 16384, 32768].map(v => [v, String(v)]), when: () => sarParams.algorithm !== S.RMA },
      { sar: true, k: 'bpPixelFt', label: 'Pixel size (ft)', type: 'num', when: () => sarParams.algorithm !== S.RMA },
      { sar: true, k: 'bpR0Ft', label: 'Reference range R0 (ft, 0 = middle)', type: 'num', when: () => sarParams.algorithm !== S.RMA },
      { type: 'help', when: () => sarParams.algorithm !== S.RMA, text: () => 'Backprojection (LeRoy Gorham, AFRL, bpBasic.m): for every aperture position, the zero-padded range profile fftshift(ifft(phase history, Nfft)) is linearly interpolated at each pixel\'s range from that antenna position, phase-corrected by exp(j4π·fmin·ΔR/c) and summed. Each position\'s averaged chirp is its phase history, conjugated to AFRL\'s sign convention and referenced to R0.' },
      { sar: true, k: 'rsFeet', label: 'Scene centre Rs (ft, matched filter)', type: 'num', when: () => sarParams.algorithm === S.RMA },
      { sar: true, k: 'zpad', label: 'Cross-range zero pad', type: 'sel', opts: [1024, 2048, 4096].map(v => [v, String(v)]), when: () => sarParams.algorithm === S.RMA },
      { sar: true, k: 'kStart', label: 'Ky start (rad/m)', type: 'num', when: () => sarParams.algorithm === S.RMA },
      { sar: true, k: 'kStop', label: 'Ky stop (rad/m)', type: 'num', when: () => sarParams.algorithm === S.RMA },
      { sar: true, k: 'hannAfterStolt', label: 'Hann window after Stolt', type: 'bool', when: () => sarParams.algorithm === S.RMA },
      { type: 'help', when: () => sarParams.algorithm === S.RMA, text: () => 'Range migration algorithm (Carrara, Goodman & Majewski ch. 10): Hann window in fast time, symmetric zero pad and FFT along the aperture, matched filter exp(j·Rs·√(Kr²−Kx²)), Stolt interpolation to an even Ky grid, then a 4× zero-padded 2-D inverse FFT.' },
    ] },
    { title: () => 'Super-resolution (matrix pencil)', when: isSAR, items: [
      { sar: true, k: 'superRes', label: 'Matrix pencil', type: 'sel', opts: ['Off', 'Matrix pencil in range', 'Matrix pencil in crossrange', 'Matrix pencil in range and crossrange'] },
      { sar: true, k: 'pencilRule', label: 'Model order', type: 'sel', opts: ORDER_RULES, when: () => sarParams.superRes !== 'Off' },
      { sar: true, k: 'pencilMaxTargets', label: 'Max scatterers per fit', type: 'int', when: () => sarParams.superRes !== 'Off' },
      { sar: true, k: 'pencilFB', label: 'Forward–backward averaging', type: 'bool', when: () => sarParams.superRes !== 'Off' },
      { sar: true, k: 'bweFactor', label: 'Range: extrapolate band to', type: 'sel', when: () => S.inRange(sarParams),
        opts: () => [2, 3, 4].map(v => [v, `${v}× (${(v * (sarParams.fStopMHz - sarParams.fStartMHz)).toFixed(0)} MHz)`]) },
      { sar: true, k: 'crossPeakWidth', label: 'Crossrange width kept (cells)', type: 'num', when: () => S.inCross(sarParams) },
      { type: 'help', when: () => sarParams.superRes !== 'Off', text: () => 'Range: at each position the frequency samples are a sum of complex exponentials (one per scatterer); the pencil\'s poles and least-squares amplitudes extend the band on both sides, so image formation sees a wider band: finer range, phases intact. Crossrange (backprojection only): once focused on a pixel, the positions\' contributions are close to a sum of exponentials over the aperture; the pixel keeps only the fitted power within the kept width of zero frequency. The crossrange pencil fits every pixel, so in a browser it takes about a minute at 0.25-ft pixels (about 15 s at 0.5 ft; the Mac app takes about 10 s); the gap rule is about 3× faster than ESTER, and it replaces SVA.' },
    ] },
    { title: () => 'SAR display', when: isSAR, items: [
      { sar: true, k: 'crossRangeFt', label: 'Crossrange ± (ft)', type: 'num' },
      { sar: true, k: 'downStartFt', label: 'Downrange from (ft)', type: 'num' },
      { sar: true, k: 'downStopFt', label: 'Downrange to (ft)', type: 'num' },
      { sar: true, k: 'blankGratingLobes', label: 'Blank grating-lobe angles', type: 'bool' },
      { type: 'help', when: () => sarParams.blankGratingLobes, text: () => `Beyond ±${(S.gratingLobeFreeAngle(sarParams) * 180 / Math.PI).toFixed(1)}° from broadside (blanked, drawn dark blue), aliases of scatterers inside can appear: with ${sarParams.spacingInches}-inch spacing, a scatterer at θ also shows at sin θ ± λ/(2·dx). Inside ±θmax, with sin θmax = λ/(4·dx) at f stop, no scatterer inside aliases. 1-inch spacing would allow about ±90°.` },
      { sar: true, k: 'rangeScaling', label: 'Scale by range^(3/2)', type: 'bool' },
      { sar: true, k: 'scaleBySlantRange', label: 'Use true range (MIT uses downrange)', type: 'bool', when: () => sarParams.rangeScaling },
      { sar: true, k: 'dbRange', label: 'Dynamic range (dB)', type: 'num' },
      { type: 'buttons', buttons: [['Process', () => sarProcess()], ['Restore default SAR settings', () => { try { localStorage.removeItem(SAR_STORE_KEY); } catch (e) { /* ignore */ } setSarParams(S.sarDefaults()); }]] },
      { type: 'help', text: () => 'Settings are remembered. Press Process after changing them: a parsing setting re-parses the recording; others only re-form the image. The dynamic range applies at once.' },
    ] },
    { title: () => 'Radar', when: notSAR, items: [
      { k: 'tpMs', label: 'Up-ramp time Tp (ms)', type: 'num' },
      { k: 'band', label: 'Band', type: 'sel', opts: Object.keys(C.BANDS) },
      { k: 'fStartMHz', label: 'f start (MHz)', type: 'num' },
      { k: 'fStopMHz', label: 'f stop (MHz)', type: 'num' },
      { type: 'help', text: vcoSummary },
    ] },
    { title: () => `Trigger (${params.syncOnRight ? 'right' : 'left'} channel)`, when: notSAR, items: [
      { k: 'syncOnRight', label: 'Sync input', type: 'sel', opts: [[false, 'Left (IF on right)'], [true, 'Right (IF on left)']] },
      { k: 'invert', label: 'Invert inputs (trig = −sync, s = −IF)', type: 'bool' },
      { k: 'threshold', label: 'Threshold', type: 'num' },
      { k: 'holdoff', label: 'Samples low before edge', type: 'int' },
      { k: 'interpolation', label: 'Edge interpolation', type: 'sel', opts: [10, 16, 32, 64, 128].map(v => [v, v + '×']) },
      { k: 'align', label: 'Align IF to the sub-sample edge', type: 'bool' },
      { k: 'rejectGlitches', label: 'Skip pulses hit by audio glitches', type: 'bool' },
      { type: 'help', text: () => 'The rising edge is upsampled with a windowed-sinc interpolator, then refined linearly between the upsampled points. With alignment on, each IF pulse is resampled to start exactly at the interpolated edge. A browser can drop or repeat a block of samples (128 or more), which puts a bright line across the waterfall; with "Skip pulses" on, a pulse is used only if the sync period it starts is within 16 samples of the usual one, so those pulses are left out (counted in the header). Chrome and Edge read the interface directly, which avoids most glitches.' },
    ] },
    { title: () => 'Range estimator', when: notSAR, items: [
      { k: 'rangeMethod', label: 'Method', type: 'sel', opts: ['FFT', 'Matrix pencil'] },
      { k: 'pencilDisplay', label: 'Display', type: 'sel', opts: ['Pseudospectrum', 'Amplitude-weighted lines'], when: isPencil },
      { k: 'pencilOrderRule', label: 'Model order', type: 'sel', opts: ORDER_RULES, when: isPencil },
      { k: 'pencilForwardBackward', label: 'Forward–backward averaging', type: 'bool', when: isPencil },
      { k: 'pencilMaxTargets', label: () => params.pencilOrderRule === 'Singular-value threshold' ? 'Max targets' : 'Max targets (cap)', type: 'int', when: isPencil },
      { k: 'esterThreshold', label: 'ESTER threshold (0–1, higher = fewer)', type: 'num', when: () => isPencil() && params.pencilOrderRule === ORDER_RULES[0] },
      { k: 'pencilThresholdDB', label: 'Signal threshold (dB below largest σ)', type: 'num', when: () => isPencil() && params.pencilOrderRule === ORDER_RULES[2] },
      { k: 'pencilL', label: 'Pencil parameter L (0 = N/3)', type: 'int', when: isPencil },
      { k: 'pencilPeakWidth', label: 'Peak half-width (FFT bins)', type: 'num', when: isPencil },
      { type: 'help', when: isPencil, text: () => 'Fits each pulse as a sum of complex exponentials (Hua & Sarkar TLS matrix pencil), two per target for the real IF (one with PGA on). The model order is chosen every pulse: ESTER keeps the largest order whose signal subspace is still shift-invariant; the gap rule cuts at the biggest drop in singular values; the threshold rule counts singular values within a fixed dB of the largest. Forward–backward averaging decorrelates coherent returns such as multipath. ▼ marks each estimated target. The window and SVA settings don\'t apply.' },
    ] },
    { title: () => 'Processing', when: notSAR, items: [
      { k: 'background', label: 'Background', type: 'sel', opts: ['Subtract mean pulse', 'None', '2-pulse canceller'] },
      { k: 'meanLength', label: 'Mean length (pulses)', type: 'int' },
      { k: 'svaEnabled', label: 'SVA (spatially variant apodization)', type: 'bool' },
      { k: 'window', label: 'Window', type: 'sel', opts: ['Rectangular', 'Hann', 'Blackman', 'Taylor'], disabled: () => params.svaEnabled },
      { type: 'help', when: () => params.svaEnabled, text: () => 'SVA replaces the window: each range bin gets its own weighting between rectangular and Hann.' },
      { k: 'taylorNbar', label: 'Taylor n̄', type: 'int', when: () => !params.svaEnabled && params.window === 'Taylor' },
      { k: 'taylorSidelobeDB', label: 'Taylor sidelobes (dB below peak)', type: 'num', when: () => !params.svaEnabled && params.window === 'Taylor' },
      { k: 'zeroPad', label: 'Zero-pad (× N)', type: 'sel', opts: [1, 2, 4, 8].map(v => [v, String(v)]) },
      { k: 'traceAveraging', label: 'Trace averaging (pulses)', type: 'int' },
      { k: 'peakHold', label: 'Peak hold', type: 'bool' },
    ] },
    { title: () => 'Range autofocus (PGA)', when: notSAR, items: [
      { k: 'pgaEnabled', label: 'Phase gradient autofocus', type: 'bool' },
      { k: 'pgaPulses', label: 'Pulses per estimate', type: 'sel', opts: [16, 32, 64, 128, 256].map(v => [v, String(v)]), when: () => params.pgaEnabled },
      { k: 'pgaIterations', label: 'Iterations', type: 'int', when: () => params.pgaEnabled },
      { k: 'pgaMinRange', label: () => `Ignore returns closer than (${unit().ab})`, type: 'num', units: true, when: () => params.pgaEnabled },
      { k: 'pgaMinAgreement', label: 'Min. half-block agreement', type: 'num', when: () => params.pgaEnabled },
      { type: 'buttons', when: () => params.pgaEnabled, buttons: [['Reset PGA estimate', () => worker.postMessage({ type: 'resetPGA' })]] },
      { type: 'help', text: () => 'Estimates the phase error every sweep shares (mostly VCO tuning nonlinearity) from the strongest return in each pulse, and removes it before the FFT. An estimate is kept only if both halves of the block agree and the profiles get sharper. Works best with one strong target (e.g. a corner reflector) in view.' },
    ] },
    { title: () => 'Range-Doppler', when: notSAR, items: [
      { k: 'rdEnabled', label: 'Show range-Doppler map', type: 'bool' },
      { k: 'rdPulses', label: 'Pulses per Doppler FFT', type: 'sel', when: () => params.rdEnabled,
        opts: () => [16, 32, 64, 128, 256].map(v => [v, `${v} (${(v * 2 * params.tpMs / 1000).toFixed(2)} s)`]) },
      { k: 'rdWindow', label: 'Doppler window', type: 'sel', opts: ['Rectangular', 'Hann', 'Blackman', 'Taylor'], when: () => params.rdEnabled },
      { k: 'rdSuperRes', label: 'Super-resolution', type: 'sel', opts: ['FFT', 'Matrix pencil in Doppler', 'Matrix pencil in range', 'Matrix pencil in range and Doppler'], when: () => params.rdEnabled },
      { k: 'rdOrderRule', label: 'Model order', type: 'sel', opts: ORDER_RULES, when: () => params.rdEnabled && params.rdSuperRes !== 'FFT' },
      { k: 'rdShowScatterers', label: 'Mark scatterers with ×', type: 'bool', when: () => params.rdEnabled && params.rdSuperRes !== 'FFT' },
      { type: 'help', when: () => params.rdEnabled && params.rdSuperRes !== 'FFT', text: () => 'Every fit (each range bin\'s pulses, each Doppler row\'s samples) estimates its own model order with this rule; the header shows the median orders and the number of scatterers. In Doppler it fits each range bin\'s pulses and draws the pseudospectrum 4× finer than the FFT cells; in range it fits the Doppler-filtered samples of each pulse; with both, a cell is bright only where the two agree. Max targets, ESTER threshold, forward–backward and peak half-width come from Range estimator.' },
      { k: 'rdRangePGA', label: 'Range PGA (fast time)', type: 'bool', when: () => params.rdEnabled },
      { k: 'rdDopplerPGA', label: 'Doppler PGA (slow time)', type: 'bool', when: () => params.rdEnabled },
      { type: 'help', text: rdSummary },
    ] },
    { title: () => 'Display', when: notSAR, items: [
      { k: 'rangeUnit', label: 'Range units', type: 'sel', opts: [['Feet', 'Feet'], ['Metres', 'Metres']] },
      { k: 'maxRangeShown', label: () => `Max range shown (${unit().ab}, 0 = all)`, type: 'num', units: true },
      { k: 'dbTop', label: 'Top (dB)', type: 'num' },
      { k: 'autoTop', label: 'Track top automatically', type: 'bool' },
      { k: 'dbRange', label: 'Range-profile dynamic range (dB)', type: 'num' },
      { k: 'rtiDbRange', label: 'Waterfall dynamic range (dB)', type: 'num' },
      { k: 'rtiSeconds', label: 'RTI history kept', type: 'sel', opts: [10, 30, 60, 120, 300].map(v => [v, `${v} s`]) },
      { type: 'buttons', buttons: [['Auto scale', autoScale], ['Clear RTI / hold', () => worker.postMessage({ type: 'clearHold' })]] },
    ] },
    { title: () => '', when: notSAR, items: [
      { type: 'buttons', buttons: [['Restore default settings', () => { localStorage.removeItem(STORE); setParams(C.defaultParams()); }]] },
      { type: 'help', text: () => 'Settings are remembered in this browser.' },
    ] },
    { title: () => 'About', items: [
      { type: 'html', html: () => `<b>${APP_NAME}</b><br>Build ${BUILD_DATE}<br>${CREDIT}<br><a href="${OCW}" target="_blank" rel="noopener">${OCW}</a><br><br>${BP_CREDIT}<br><a href="${BP_URL}" target="_blank" rel="noopener">${BP_URL}</a>` },
    ] },
  ];

  const controls = [];
  const MAIN_STORE = { get: k => params[k], set: o => setParams(o) };
  const SAR_STORE = { get: k => sarParams[k], set: o => setSarParams(o) };
  function buildSidebar() {
    const side = $('sidebar');
    side.innerHTML = '';
    for (const sec of SECTIONS) {
      const box = document.createElement('div');
      box.className = 'sec';
      const h = document.createElement('h3');
      box.append(h);
      controls.push({ el: h, update: () => { h.textContent = sec.title(); h.hidden = !sec.title(); box.hidden = !!(sec.when && !sec.when()); } });
      for (const it of sec.items) box.append(makeControl(it));
      side.append(box);
    }
    refreshSidebar();
  }

  function optionList(it) { const o = typeof it.opts === 'function' ? it.opts() : it.opts; return o.map(x => Array.isArray(x) ? x : [x, x]); }

  function makeControl(it) {
    const row = document.createElement('div');
    const st = it.sar ? SAR_STORE : MAIN_STORE;
    const setVal = v => it.onSet ? it.onSet(v) : st.set({ [it.k]: v });
    const show = () => !it.when || it.when();
    if (it.type === 'help' || it.type === 'html') {
      row.className = 'help';
      controls.push({ el: row, update: () => { row.hidden = !show(); if (it.type === 'help') row.textContent = it.text(); else row.innerHTML = it.html(); } });
      return row;
    }
    if (it.type === 'buttons') {
      row.className = 'ctl buttons';
      for (const [label, fn] of it.buttons) { const b = document.createElement('button'); b.className = 'small'; b.textContent = label; b.onclick = fn; row.append(b); }
      controls.push({ el: row, update: () => { row.hidden = !show(); } });
      return row;
    }
    row.className = 'ctl';
    const lab = document.createElement('label');
    row.append(lab);
    const per = () => it.units ? unit().per : 1;
    let input;
    if (it.type === 'bool') {
      const sw = document.createElement('label');
      sw.className = 'switch';
      input = document.createElement('input'); input.type = 'checkbox';
      sw.append(input, document.createElement('span'));
      row.append(sw);
      input.onchange = () => setVal(input.checked);
    } else if (it.type === 'sel') {
      input = document.createElement('select');
      row.append(input);
      input.onchange = () => { const o = optionList(it)[input.selectedIndex]; if (o) setVal(o[0]); };
    } else {
      input = document.createElement('input'); input.type = 'number'; input.step = 'any';
      row.append(input);
      input.onchange = () => {
        const v = parseFloat(input.value);
        if (!isFinite(v)) { input.value = fmt(st.get(it.k) * per()); return; }
        setVal(it.type === 'int' ? Math.round(v) : v / per());
      };
    }
    const fmt = v => String(Math.round(v * 1e6) / 1e6);
    controls.push({ el: row, update: () => {
      row.hidden = !show();
      lab.textContent = typeof it.label === 'function' ? it.label() : it.label;
      input.disabled = !!(it.disabled && it.disabled());
      if (it.type === 'bool') input.checked = !!st.get(it.k);
      else if (it.type === 'sel') {
        const opts = optionList(it);
        const sig = opts.map(o => o[1]).join('|');
        if (input.dataset.sig !== sig) { input.innerHTML = ''; for (const o of opts) input.append(new Option(o[1])); input.dataset.sig = sig; }
        const i = opts.findIndex(o => o[0] === st.get(it.k));
        input.selectedIndex = i;
      } else if (document.activeElement !== input) input.value = fmt(st.get(it.k) * per());
    } });
    return row;
  }

  function refreshSidebar() { for (const c of controls) c.update(); }

  function autoScale() {
    if (!trace || trace.length < 2) return;
    let mx = -60;
    for (let k = 1; k < Math.min(trace.length, d.nBins); k++) if (trace[k] > mx) mx = trace[k];
    setParams({ dbTop: Math.ceil((mx + 3) / 5) * 5 });
  }

  // ---------------- how it works ----------------
  function block(title, detail, active = true, kind = 'process') { return { title, detail, active, kind }; }
  function diagram(rows) {
    const tint = b => !b.active ? 'gray' : b.kind === 'input' ? 'var(--purple)' : b.kind === 'output' ? 'var(--green)' : 'var(--accent)';
    return '<div class="diagram">' + rows.map((r, i) => (i ? '<div class="arrow">↓</div>' : '') + '<div class="brow">' + r.map(b =>
      `<div class="block${b.active ? '' : ' off'}" style="border-color:${tint(b)};background:color-mix(in srgb, ${tint(b)} ${b.active ? 12 : 5}%, transparent)"><b>${b.title}</b>${b.active ? '' : '<span class="tag">off</span>'}<div>${b.detail}</div></div>`).join('') + '</div>').join('') + '</div>';
  }
  function renderHow() {
    const p = params, sync = p.syncOnRight ? 'right' : 'left', ifc = p.syncOnRight ? 'left' : 'right', pencil = isPencil();
    const win = p.svaEnabled ? 'SVA (per-bin weighting, rectangular to Hann)' : p.window === 'Taylor' ? `Taylor window (n̄ = ${p.taylorNbar}, ${p.taylorSidelobeDB} dB)` : `${p.window} window`;
    const main = [
      [block('Audio input', `the USB audio interface (e.g. Behringer UCA222), ${Math.round(d.fs)} Hz stereo: sync on the ${sync} input, IF on the ${ifc}${p.invert ? ', both inverted' : ''}; echo cancellation, noise suppression and gain control off`, source !== 'sim' && source !== 'file', 'input'),
        block('Simulator / recording', 'synthetic sync and IF (fixed and walking targets), or a stereo .wav played in real time', source === 'sim' || source === 'file', 'input')],
      [block('Real-time guard', 'at most 0.5 s of audio may wait for processing (in a background thread); beyond that blocks are skipped and the status line says so')],
      [block('Sync trigger', `rising edge after ≥ ${p.holdoff} samples below the threshold; the edge is upsampled ${p.interpolation}× with a windowed sinc and refined linearly to the crossing`)],
      [block('Pulse extraction', p.align ? `N = Tp·fs = ${d.n} samples (Tp = ${p.tpMs} ms up-chirp), resampled to start exactly at the sub-sample edge` : `N = ${d.n} samples from the integer trigger sample`)],
      [block('Background removal', p.background === 'Subtract mean pulse' ? `subtract the running mean pulse (${p.meanLength} pulses)` : p.background === '2-pulse canceller' ? '2-pulse canceller (this pulse minus the last)' : 'none', p.background !== 'None')],
      [block('Range PGA', `analytic signal; phase error every sweep shares (VCO nonlinearity) estimated from the strongest return over ${p.pgaPulses} pulses and removed`, p.pgaEnabled)],
      [block('FFT range profile', `${win}, zero pad ${p.zeroPad}×, ${d.nfft}-point FFT`, !pencil),
        block('Matrix pencil range profile', `TLS pencil (Hua & Sarkar), model order: ${p.pencilOrderRule}${p.pencilForwardBackward ? ', forward–backward' : ''}; ${p.pencilDisplay.toLowerCase()}`, pencil)],
      [block('Range profile', `trace (${p.traceAveraging}-pulse average)${p.peakHold ? ', peak hold' : ''}${pencil ? ', ▼ estimated targets' : ''}`, true, 'output'),
        block('RTI waterfall', `every pulse kept for ${p.rtiSeconds} s; dynamic range and time-span sliders`, true, 'output')],
    ];
    const rd = [
      [block('Complex range profiles', 'each pulse after background removal, windowed FFT; the last 256 kept', p.rdEnabled)],
      [block('Range PGA (map)', 'fast-time phase error removed for the map only', p.rdEnabled && p.rdRangePGA),
        block('Doppler PGA', 'pulse-to-pulse phase error shared by all range bins, re-estimated for every map', p.rdEnabled && p.rdDopplerPGA)],
      [block('Slow-time FFT', `${p.rdPulses} pulses, ${p.rdWindow} window`, p.rdEnabled && p.rdSuperRes === 'FFT'),
        block('Matrix pencil', `${p.rdSuperRes === 'FFT' ? 'range, Doppler or both' : p.rdSuperRes.replace('Matrix pencil in ', '')}; model order ${p.rdOrderRule}`, p.rdEnabled && p.rdSuperRes !== 'FFT')],
      [block('Range-Doppler map', 'velocity in m/s (+ = approaching), strongest mover, model orders and scatterer count; built in its own thread', p.rdEnabled, 'output')],
    ];
    const dtp = p.dtMethod === 'Matrix pencil', dfile = dt && dt.fileName != null;
    const dtRows = [
      [block('Audio input (CW)', `the radar run unmodulated (Vtune fixed, fc = ${p.dtCarrierMHz} MHz): only the IF on the ${ifc} input; no sync needed`, !dfile && source !== 'sim', 'input'),
        block('Recording / simulator', dfile ? `${dt.fileName}, IF channel ${ifc}` : 'a .wav (e.g. MIT\'s "Off of Newton Exit 17.wav"), or the CW simulator', dfile || source === 'sim', 'input')],
      [block('Dwells', `N = Tp·fs = ${Math.round(p.dtDwellMs / 1000 * d.fs)} samples per Doppler spectrum (Tp = ${p.dtDwellMs} ms)${p.dtOverlap > 0 ? `, ${(p.dtOverlap * 100).toFixed(0)}% overlapped: a new row every ${(p.dtDwellMs * (1 - p.dtOverlap)).toFixed(0)} ms` : ''}${p.dtSubtractMean ? '; mean subtracted (the whole recording\'s, as MIT\'s script)' : ''}`)],
      [block('PGA (strongest mover)', 'per dwell: the dominant line\'s phase wander removed, keeping its mean velocity; kept only if sharper', p.dtPGA)],
      [block('FFT', `${p.dtWindow} window, zero pad ${p.dtZeroPad}×`, !dtp && !p.dtSVA),
        block('SVA', 'per-bin weighting between rectangular and Hann', !dtp && p.dtSVA),
        block('Matrix pencil', `band 0–${p.dtMaxVelocity} m/s decimated, TLS pencil, model order ${p.dtOrderRule}`, dtp)],
      [block('Doppler vs. time', `v = f·λ/2 (speed: the real IF can't tell approaching from receding), 0–${p.dtMaxVelocity} m/s, ${p.dtDbRange} dB below the strongest`, true, 'output'),
        block('Doppler spectrum', 'one dwell (newest, or the time clicked), strongest mover in m/s and mph', true, 'output')],
    ];
    const q = sarParams, bpOn = q.algorithm !== S.RMA, crossPencil = S.inCross(q) && bpOn, theta = S.gratingLobeFreeAngle(q) * 180 / Math.PI;
    const svaKind = q.svaMode === 'Dual apodization (rect/Hann minimum)' ? 'dual apodization (smaller of unweighted and Hann)'
      : `${q.svaMode === 'Joint I/Q' ? 'joint I/Q' : 'I and Q separately'}${q.svaHannCap ? ', limited by the Hann image' : ''}`;
    const sarRows = [
      [block('Recording (.wav)', `Coffee Can Radar on a rail: sync on the ${q.syncOnRight ? 'right' : 'left'} channel, IF on the ${q.syncOnRight ? 'left' : 'right'}${q.invert ? ', both inverted' : ''}; the radar is moved ${q.spacingInches} in between bursts`, true, 'input')],
      [block('Find aperture positions', `a position starts where the sync returns after ≥ ${q.trpSeconds} s of silence (MIT SBAND_RMA_opendata.m): ${sarResult ? sarResult.positions + ' positions' : 'one per burst'}`)],
      [block('Sync edges', q.alignment !== S.MIT_ALIGN ? `rising edge after ≥ ${q.holdoff} low samples, upsampled ${q.interpolation}× with a windowed sinc and refined linearly (as in the RTI tab); each up-chirp resampled to start there` : 'MIT rule: the integer sample where the sync peaks after a rising edge')],
      [block('Average up-chirps', q.chirpsPerPosition > 0 ? `the first ${q.chirpsPerPosition} complete up-chirps at every position, the same number everywhere` : 'MIT: every chirp in the first Trp (varies by position)'),
        block('Hilbert transform', `ifft, keep one half, fft: N/2 complex samples per position, the phase history over ${q.fStartMHz}–${q.fStopMHz} MHz`)],
      [block('Aperture mean subtraction', q.mitMean ? 'MIT\'s running mean (leaves about 37% of the antenna leakage)' : 'exact mean over the aperture: removes the antenna leakage', q.subtractMean)],
      [block('Range PGA', 'one phase per frequency sample, shared by every sweep (VCO nonlinearity)', q.rangePGA),
        block('Crossrange autofocus', 'one phase per position, so each adds coherently to the strongest scatterers', q.crossPGA)],
      [block('Range super-resolution', `matrix pencil per position extends the band ${q.bweFactor}×, measured samples kept in the middle`, S.inRange(q))],
      [block('Backprojection', 'AFRL bpBasic.m (Gorham & Moore): per position, the zero-padded range profile is interpolated at each pixel\'s range, phase-corrected and summed (spread over the processor cores)', bpOn),
        block('Range migration', 'MIT SBAND_RMA_IFP.m: Hann window, along-track FFT, matched filter, Stolt interpolation, 2-D inverse FFT', !bpOn)],
      [block('Crossrange super-resolution', 'per-pixel matrix pencil over the positions\' focused contributions; keeps the power near zero frequency (backprojection only)', crossPencil),
        block('SVA', svaKind + '; local carrier removed first', q.sva && !crossPencil)],
      [block('Range scaling', `× range^(3/2) by ${q.scaleBySlantRange ? 'true range from the aperture centre' : 'downrange (MIT)'}`, q.rangeScaling),
        block('Grating-lobe blanking', theta >= 89.9 ? 'no grating lobes at this spacing: full ±90°' : `beyond ±${theta.toFixed(1)}° (aliases from the ${q.spacingInches}-inch spacing)`, q.blankGratingLobes && theta < 89.9)],
      [block('SAR image', `crossrange vs downrange in ft, equal scale, ${q.dbRange} dB colour range`, true, 'output'),
        block('Range profiles', 'every position\'s range profile', true, 'output'),
        block('K-space', 'after Stolt interpolation (range migration)', !bpOn, 'output'),
        block('Autofocus', 'estimated phase errors', q.rangePGA || q.crossPGA, 'output')],
    ];
    const diag = [[block('Diagnostics tab', 'last triggered pulse (sync and IF, full scale), rising-edge zoom with the interpolation, PGA phase estimates', true, 'output')]];
    $('tab-how').innerHTML = `<h2>How Coffee Can Radar works</h2>
      <div class="status">The blocks follow your current settings: coloured blocks are in use, grey dashed ones are switched off. This web version runs the same processing as the Mac app (Coffee Can RTI DTI SAR Imaging), checked against it pulse by pulse.</div>
      <div class="legend"><span><i style="background:color-mix(in srgb, var(--purple) 25%, transparent);border:1px solid var(--purple)"></i>Input</span><span><i style="background:color-mix(in srgb, var(--accent) 25%, transparent);border:1px solid var(--accent)"></i>Processing</span><span><i style="background:color-mix(in srgb, var(--green) 25%, transparent);border:1px solid var(--green)"></i>Output</span><span><i style="border:1px dashed gray"></i>Off in the current settings</span></div>
      <div class="cols"><div><h3>Range processing (every pulse)</h3>${diagram(main)}</div>
      <div><h3>Range-Doppler branch (from background removal)</h3>${diagram(rd)}<h3>Diagnostics</h3>${diagram(diag)}</div></div>
      <h3>Doppler vs. time tab (CW, after MIT's read_data_doppler.m)</h3>${diagram(dtRows)}
      <h3>SAR imaging tab (after MIT's Experiment 3 scripts and AFRL's bpBasic.m)</h3>${diagram(sarRows)}
      <div class="about"><b>About</b><br>${APP_NAME}, build ${BUILD_DATE}<br>${CREDIT}<br><a href="${OCW}" target="_blank" rel="noopener">${OCW}</a><br><br>${BP_CREDIT}<br><a href="${BP_URL}" target="_blank" rel="noopener">${BP_URL}</a></div>`;
  }

  // ---------------- drawing ----------------
  let drawQueued = false;
  function requestDraw() { if (!drawQueued) { drawQueued = true; requestAnimationFrame(draw); } }
  new ResizeObserver(requestDraw).observe($('main'));
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', requestDraw);

  function draw() {
    drawQueued = false;
    updateHeaders();
    if (activeTab === 'radar') { drawRTI(); if (params.rdEnabled) drawRD(); drawProfile(); }
    else if (activeTab === 'diag') { drawScope(); drawPGA(); drawEdge(); }
    else if (activeTab === 'doppler') { updateDTHeaders(); drawDTI(); drawDTSpectrum(); }
    else if (activeTab === 'sar') drawSAR();
  }

  function updateHeaders() {
    const u = unit(), p = params;
    $('rti-detail').textContent = `${pulseCount} pulses · colour ${Math.round(p.dbTop - p.rtiDbRange)}…${Math.round(p.dbTop)} dB`;
    const pga = p.pgaEnabled ? ' · PGA on' : '';
    if (isPencil()) {
      $('profile-title').textContent = `Range profile: matrix pencil ${p.pencilDisplay.toLowerCase()} (dB vs. range)${pga} · ▼ = estimated targets`;
      $('profile-detail').textContent = `N=${d.n}, model order ${pencilOrder ?? '–'}, ${pencilTargets.length} targets, ${(pencilMs || 0).toFixed(1)} ms/pulse`;
    } else {
      $('profile-title').textContent = `Range profile: FFT of IF channel (dBFS vs. range)${pga}`;
      $('profile-detail').textContent = `N=${d.n}, FFT ${d.nfft}, ${(d.metersPerBin * u.per).toFixed(3)} ${u.ab}/bin`;
    }
    const rdm = rangeDoppler, sr = p.rdSuperRes;
    const pgaTag = [p.rdRangePGA ? 'range' : null, p.rdDopplerPGA ? 'Doppler' : null].filter(Boolean).join(' + ');
    const orders = [rdm && rdm.dopplerOrder != null ? `Doppler order ${rdm.dopplerOrder}` : null, rdm && rdm.rangeOrder != null ? `range order ${rdm.rangeOrder}` : null,
      rdm && rdm.scatterers.length ? `${rdm.scatterers.length} scatterers${p.rdShowScatterers ? ' ×' : ''}` : null].filter(Boolean);
    $('rd-title').textContent = `Range-Doppler, + = approaching (${p.rdPulses} pulses, ${(p.rdPulses * 2 * p.tpMs / 1000).toFixed(2)} s)${sr === 'FFT' ? '' : ' · ' + sr.toLowerCase()}${pgaTag ? ' · PGA: ' + pgaTag : ''}${orders.length && sr !== 'FFT' ? ' · ' + orders.join(', ') : ''}`;
    $('rd-detail').textContent = (rdm && rdm.peak ? `○ ${(rdm.peak.range * u.per).toFixed(1)} ${u.ab}, ${rdm.peak.velocity >= 0 ? '+' : ''}${rdm.peak.velocity.toFixed(2)} m/s @ ${rdm.peak.db.toFixed(0)} dB` : '') + (rdm ? ` · ${rdm.ms.toFixed(0)} ms` : '');
    const rangeOn = p.pgaEnabled || (p.rdEnabled && p.rdRangePGA), dopplerOn = p.rdEnabled && p.rdDopplerPGA;
    $('pga-card').hidden = !(rangeOn || dopplerOn);
    $('pga-switch').hidden = !(rangeOn && dopplerOn);
    const doppler = dopplerOn && (showDopplerPGA || !rangeOn);
    $('pga-title').textContent = doppler ? 'Doppler PGA phase error' : 'Range PGA phase error';
    $('pga-detail').textContent = doppler ? (rdm && rdm.slowPhase ? `${C.rms(rdm.slowPhase).toFixed(2)} rad rms` : '')
      : (pgaAgreement != null ? `accepted ${pgaAccepted} of ${pgaUpdates} · halves agree ${pgaAgreement.toFixed(2)}` : '');
    $('edge-detail').textContent = edge ? `${edge.upsample}× · edge at ${edge.edgeOffset >= 0 ? '+' : ''}${edge.edgeOffset.toFixed(3)} samples` : '';
  }

  function drawRTI() {
    const cv = $('rti');
    const { ctx, w, h, dpr } = P.setup(cv);
    const u = unit(), period = 2 * params.tpMs / 1000, top = params.dbTop, range = Math.max(10, params.rtiDbRange);
    const plotH = Math.max(10, h - 40);
    const px = Math.max(40, Math.min(2000, Math.floor(plotH * dpr)));
    if (px !== rti.maxRows) { rti.maxRows = px; if (rti.width) rti.setView(viewPulses(), top, params.rtiDbRange); }
    const ageMax = rti.height * rti.pulsesPerRow * period;
    const drawH = Math.min(plotH, rti.height / dpr);
    const ax = P.axes(ctx, Math.max(80, w - 64), h, { x: [0, d.rShow * u.per], y: [0, ageMax * plotH / Math.max(1, drawH)], xLabel: `range (${u.ab})`, yLabel: 'age (s)', yDown: true });
    if (rti.width) {
      const cols = Math.min(rti.width, d.nBins);
      const frac = Math.min(1, cols * d.metersPerBin / d.rShow);
      rti.draw(ctx, cols, ax.rect.x, ax.rect.y, ax.rect.w * frac, dpr);
    }
    P.border(ctx, ax);
    P.colorBar(ctx, { x: ax.rect.x + ax.rect.w + 14, y: ax.rect.y, w: 12, h: ax.rect.h }, top, range);
  }

  function drawRD() {
    const { ctx, w, h } = P.setup($('rd'));
    const u = unit(), rd = rangeDoppler, m = Math.max(8, params.rdPulses);
    const dv0 = C.wavelength(params) / 2 / (m * 2 * params.tpMs / 1000);
    const step = rd ? rd.velocityStep : dv0;
    const vTop = (rd ? rd.topVelocity : m / 2 * dv0) + step / 2;
    const vBottom = vTop - (rd ? rd.rows : m) * step;
    const ax = P.axes(ctx, Math.max(80, w - 64), h, { x: [0, d.rShow * u.per], y: [vBottom, vTop], xLabel: `range (${u.ab})`, yLabel: 'velocity (m/s)' });
    if (rd && rdImage) {
      const frac = Math.min(1, rd.nr * d.metersPerBin / d.rShow);
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(rdImage, ax.rect.x, ax.rect.y, ax.rect.w * frac, ax.rect.h);
      P.clip(ctx, ax);
      const y0 = ax.py(0);
      ctx.strokeStyle = 'rgba(255,255,255,0.6)'; ctx.setLineDash([4, 4]); ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(ax.rect.x, y0); ctx.lineTo(ax.rect.x + ax.rect.w, y0); ctx.stroke(); ctx.setLineDash([]);
      if (params.rdShowScatterers) {
        ctx.strokeStyle = '#fff';
        for (const s of rd.scatterers) {
          if (s.range > d.rShow) continue;
          const x = ax.px(s.range * u.per), y = ax.py(s.velocity);
          ctx.beginPath(); ctx.moveTo(x - 3, y - 3); ctx.lineTo(x + 3, y + 3); ctx.moveTo(x - 3, y + 3); ctx.lineTo(x + 3, y - 3); ctx.stroke();
        }
      }
      if (rd.peak && rd.peak.range <= d.rShow) {
        ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5;
        ctx.beginPath(); ctx.arc(ax.px(rd.peak.range * u.per), ax.py(rd.peak.velocity), 6, 0, 2 * Math.PI); ctx.stroke();
      }
      ctx.restore();
    } else {
      P.centerText(ctx, ax, source ? `Collecting pulses… ${Math.min(rdCollected, m)} of ${m}` : 'Start capture to build the range-Doppler map');
    }
    P.border(ctx, ax);
    P.colorBar(ctx, { x: ax.rect.x + ax.rect.w + 14, y: ax.rect.y, w: 12, h: ax.rect.h }, params.dbTop, Math.max(10, params.rdDbRange));
  }

  function drawProfile() {
    const { ctx, w, h } = P.setup($('profile'));
    const u = unit(), top = params.dbTop, bottom = params.dbTop - Math.max(10, params.dbRange);
    const ax = P.axes(ctx, w, h, { x: [0, d.rShow * u.per], y: [bottom, top], xLabel: `range (${u.ab})`, yLabel: 'dBFS' });
    P.clip(ctx, ax);
    const line = (db, color, width) => {
      ctx.strokeStyle = color; ctx.lineWidth = width; ctx.beginPath();
      for (let k = 0; k < Math.min(db.length, d.nBins); k++) {
        const x = ax.px(k * d.metersPerBin * u.per), y = ax.py(Math.min(top, Math.max(bottom, db[k])));
        k ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }
      ctx.stroke();
    };
    if (hold) line(hold, 'gray', 1);
    if (trace) line(trace, P.css('--accent'), 1.4);
    if (isPencil()) {
      ctx.fillStyle = P.css('--red');
      for (const t of pencilTargets) {
        if (t.range > d.rShow) continue;
        const x = ax.px(t.range * u.per), y = ax.py(Math.min(top, Math.max(bottom, t.db)));
        ctx.beginPath(); ctx.moveTo(x, y - 1); ctx.lineTo(x - 4, y - 8); ctx.lineTo(x + 4, y - 8); ctx.closePath(); ctx.fill();
      }
    }
    if (stats.peakRange != null) {
      ctx.fillStyle = P.css('--orange');
      ctx.beginPath(); ctx.arc(ax.px(stats.peakRange * u.per), ax.py(Math.min(top, Math.max(bottom, stats.peakDB))), 4, 0, 2 * Math.PI); ctx.fill();
    }
    ctx.restore();
    P.border(ctx, ax);
  }

  function drawScope() {
    const { ctx, w, h } = P.setup($('scope'));
    const s = scope;
    if (!s || s.left.length < 2) { const ax = P.axes(ctx, w, h, { x: [0, 20], y: [-1, 1], xLabel: 'time from trigger (ms)', yLabel: 'full scale' }); P.border(ctx, ax); return; }
    const n = s.left.length, tmin = -s.pre / s.fs * 1e3, tmax = (n - s.pre) / s.fs * 1e3;
    const ax = P.axes(ctx, w, h, { x: [tmin, tmax], y: [-1, 1], xLabel: 'time from trigger (ms)', yLabel: 'full scale' });
    P.clip(ctx, ax);
    const step = Math.max(1, Math.floor(n / Math.max(200, ax.rect.w * 2)));
    for (const [arr, color] of [[s.left, P.css('--accent')], [s.right, P.css('--orange')]]) {
      ctx.strokeStyle = color; ctx.lineWidth = 1.1; ctx.beginPath();
      for (let k = 0; k < n; k += step) { const x = ax.px(tmin + k / s.fs * 1e3), y = ax.py(arr[k]); k ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
      ctx.stroke();
    }
    ctx.strokeStyle = P.css('--text2'); ctx.setLineDash([4, 4]);
    for (const t of [0, s.n / s.fs * 1e3]) { ctx.beginPath(); ctx.moveTo(ax.px(t), ax.rect.y); ctx.lineTo(ax.px(t), ax.rect.y + ax.rect.h); ctx.stroke(); }
    ctx.setLineDash([]);
    ctx.restore();
    P.border(ctx, ax);
  }

  function drawEdge() {
    const { ctx, w, h } = P.setup($('edge'));
    const e = edge;
    if (!e) { const ax = P.axes(ctx, w, h, { x: [-4, 4], y: [-1, 1], xLabel: 'samples from integer trigger', yLabel: 'full scale' }); P.border(ctx, ax); return; }
    const span = e.span;
    const ax = P.axes(ctx, w, h, { x: [-span, span], y: [-1, 1], xLabel: 'samples from integer trigger (MATLAB ii)', yLabel: 'full scale' });
    P.clip(ctx, ax);
    ctx.strokeStyle = P.css('--text2'); ctx.setLineDash([3, 3]); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(ax.rect.x, ax.py(e.threshold)); ctx.lineTo(ax.rect.x + ax.rect.w, ax.py(e.threshold));
    ctx.moveTo(ax.px(0), ax.rect.y); ctx.lineTo(ax.px(0), ax.rect.y + ax.rect.h); ctx.stroke(); ctx.setLineDash([]);
    const acc = P.css('--accent');
    ctx.strokeStyle = acc; ctx.lineWidth = 1.2; ctx.beginPath();
    e.fine.forEach((v, j) => { const x = ax.px(-span + j / e.upsample), y = ax.py(v); j ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
    ctx.stroke();
    ctx.fillStyle = P.css('--text');
    e.samples.forEach((v, j) => { ctx.beginPath(); ctx.arc(ax.px(j - span), ax.py(v), 3.5, 0, 2 * Math.PI); ctx.fill(); });
    ctx.strokeStyle = P.css('--orange'); ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(ax.px(e.edgeOffset), ax.rect.y); ctx.lineTo(ax.px(e.edgeOffset), ax.rect.y + ax.rect.h); ctx.stroke();
    ctx.restore();
    P.border(ctx, ax);
  }

  function drawPGA() {
    if ($('pga-card').hidden) return;
    const { ctx, w, h } = P.setup($('pga'));
    const p = params, rangeOn = p.pgaEnabled || (p.rdEnabled && p.rdRangePGA), dopplerOn = p.rdEnabled && p.rdDopplerPGA;
    const doppler = dopplerOn && (showDopplerPGA || !rangeOn);
    let phi, xEnd, xLabel, dt;
    if (doppler) {
      phi = rangeDoppler && rangeDoppler.slowPhase; dt = 2 * p.tpMs / 1000;
      xEnd = (Math.max(2, phi ? phi.length : p.rdPulses) - 1) * dt; xLabel = 'time across map (s)';
    } else {
      phi = pgaPhase; dt = 1000 / d.fs; xEnd = d.n / d.fs * 1e3; xLabel = 'time in sweep (ms)';
    }
    if (!phi || phi.length < 2) {
      const ax = P.axes(ctx, w, h, { x: [0, xEnd], y: [-1, 1], xLabel, yLabel: 'rad' });
      P.centerText(ctx, ax, doppler ? 'Waiting for a range-Doppler map…' : pgaUpdates === 0 ? 'Collecting pulses…' : 'No estimate has passed the checks yet');
      P.border(ctx, ax); return;
    }
    let mx = 0;
    for (const v of phi) mx = Math.max(mx, Math.abs(v));
    mx = Math.max(0.2, mx * 1.1);
    const ax = P.axes(ctx, w, h, { x: [0, xEnd], y: [-mx, mx], xLabel, yLabel: 'rad' });
    P.clip(ctx, ax);
    ctx.strokeStyle = P.css('--purple'); ctx.lineWidth = 1.4; ctx.beginPath();
    for (let t = 0; t < phi.length; t++) { const x = ax.px(t * dt), y = ax.py(phi[t]); t ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
    ctx.stroke(); ctx.restore();
    P.border(ctx, ax);
  }

  // ---------------- Doppler vs. time ----------------
  async function openDopplerFile(file) {
    setStatus(`Reading ${file.name}…`);
    try {
      const buf = await file.arrayBuffer();
      let w = parseWav(buf);
      if (!w) {
        const ctx = new AudioContext();
        const ab = await ctx.decodeAudioData(buf.slice(0));
        w = { fs: ab.sampleRate, channels: ab.numberOfChannels, left: ab.getChannelData(0), right: ab.numberOfChannels > 1 ? ab.getChannelData(1) : null };
        ctx.close();
      }
      if (w.channels < 2) w.right = null;
      dtBusy = true; dtSel = null;
      const tr = [w.left.buffer];
      if (w.right && w.right !== w.left) tr.push(w.right.buffer); else w.right = null;
      const secs = w.left.length / w.fs;   // before the samples are handed to the worker
      worker.postMessage({ type: 'dtFile', name: file.name, left: w.left, right: w.right, fs: w.fs }, tr);
      setStatus(`Doppler vs. time: ${file.name}, ${secs.toFixed(1)} s at ${w.fs} Hz.`);
      requestDraw();
    } catch (err) {
      dtBusy = false;
      setStatus(`Couldn't read ${file.name}: ${err && err.message ? err.message : err}`, true);
    }
  }
  $('dt-open').onclick = () => $('fileinput').click();
  $('dt-live').onclick = () => { dtBusy = true; dtSel = null; worker.postMessage({ type: 'dtLive' }); requestDraw(); };
  $('dt-swap').onclick = () => setParams({ syncOnRight: !params.syncOnRight });
  document.querySelectorAll('#dt-if button').forEach(b => b.onclick = () => setParams({ syncOnRight: b.dataset.v === 'true' }));
  $('dt-range').oninput = (e) => setParams({ dtDbRange: Math.round(+e.target.value) });
  $('dt-vmax').oninput = (e) => setParams({ dtMaxVelocity: Math.round(+e.target.value) });

  /** Jet image of the Doppler rows: newest at the top when live, time running down for a recording (MIT's plot). */
  // Each image row combines perRow dwells (the strongest value per bin), so the image is no taller
  // than the plot: drawing a taller image drops a different set of rows each time it scrolls, which
  // flickers. Groups are fixed by the dwell's absolute index, so they don't shift as rows arrive.
  let dtImagePx = 400, dtSecPerPx = 0.25;
  function buildDTImage() {
    if (!dt || !dt.nRows) { dtImage = null; return; }
    const { nRows, cols, rows, maxDB } = dt, live = dt.fileName == null, first = dt.firstIndex || 0;
    const spanRows = live ? Math.max(nRows, Math.trunc(params.dtHistorySeconds / dt.hopSeconds)) : nRows;
    const perRow = Math.max(1, Math.ceil(spanRows / dtImagePx));
    // fewer rows than pixels: each row repeated a whole number of times (live is drawn one row per pixel)
    const rep = perRow === 1 ? Math.max(1, Math.floor(dtImagePx / Math.max(1, spanRows))) : 1;
    dtSecPerPx = perRow * dt.hopSeconds / rep;
    const g0 = Math.floor(first / perRow), h = Math.floor((first + nRows - 1) / perRow) - g0 + 1;
    const comb = new Float32Array(h * cols).fill(-Infinity);
    for (let i = 0; i < nRows; i++) {
      const gi = Math.floor((first + i) / perRow) - g0, o = gi * cols, src = i * cols;
      for (let k = 0; k < cols; k++) if (rows[src + k] > comb[o + k]) comb[o + k] = rows[src + k];
    }
    const range = Math.max(1, params.dtDbRange), lo = maxDB - range, cs = 255 / range;
    const hOut = h * rep, rgba = new Uint8ClampedArray(hOut * cols * 4);
    for (let r = 0; r < hOut; r++) {
      const gr = Math.floor(r / rep), src = (live ? h - 1 - gr : gr) * cols, dst = r * cols * 4;
      for (let k = 0; k < cols; k++) {
        const c = Math.max(0, Math.min(255, Math.round((comb[src + k] - lo) * cs))) * 3, o = dst + k * 4;
        rgba[o] = C.JET[c]; rgba[o + 1] = C.JET[c + 1]; rgba[o + 2] = C.JET[c + 2]; rgba[o + 3] = 255;
      }
    }
    const cv = document.createElement('canvas');
    cv.width = cols; cv.height = hOut;
    cv.getContext('2d').putImageData(new ImageData(rgba, cols, hOut), 0, 0);
    dtImage = cv;
  }

  /** Strongest bin at or above minVelocity, refined with a parabolic fit: {velocity, db}. */
  function dtPeak(row, mpsPerCol, minVelocity) {
    const first = Math.max(1, Math.ceil(minVelocity / Math.max(1e-9, mpsPerCol)));
    if (first >= row.length - 1) return null;
    let kb = first;
    for (let k = first; k < row.length; k++) if (row[k] > row[kb]) kb = k;
    let kf = kb;
    if (kb > 0 && kb + 1 < row.length) { const a = row[kb - 1], b = row[kb], c = row[kb + 1], den = a - 2 * b + c; if (den < 0) kf += 0.5 * (a - c) / den; }
    return { velocity: kf * mpsPerCol, db: row[kb] };
  }
  const dtRowIndex = () => dt && dt.nRows ? (dtSel != null ? dtSel : dt.nRows - 1) : null;
  const dtRow = i => dt.rows.subarray(i * dt.cols, (i + 1) * dt.cols);

  function updateDTHeaders() {
    const p = params, ifSide = p.syncOnRight ? 'left' : 'right', other = p.syncOnRight ? 'right' : 'left';
    document.querySelectorAll('#dt-if button').forEach(b => b.classList.toggle('active', (b.dataset.v === 'true') === p.syncOnRight));
    $('dt-live').disabled = !dt || dt.fileName == null;
    $('dt-busy').hidden = !dtBusy;
    let src;
    if (dt && dt.fileName != null) src = `Recording: ${dt.fileName}, ${(dt.nRows * dt.hopSeconds).toFixed(1)} s (${dt.nRows} dwells), IF from the ${ifSide} channel`;
    else if (source === 'live' && dt) src = `Live: IF on the ${ifSide} input · next row ${Math.round(100 * dt.waitingSamples / Math.max(1, dt.samplesPerDwell))}%`;
    else if (source === 'sim' && dt) src = `Simulated CW: IF on the ${ifSide} input`;
    else src = 'Live input idle: press Start for the audio interface, Simulate, or open a recording.';
    $('dt-source').textContent = src;
    const dbfs = v => v > 0 ? `${(20 * Math.log10(v)).toFixed(1)} dBFS` : '−∞ dBFS';
    $('dt-levels').textContent = dt && (dt.ifRMS > 0 || dt.otherRMS > 0) ? `level: IF (${ifSide}) ${dbfs(dt.ifRMS)}, other (${other}) ${dbfs(dt.otherRMS)}` : '';
    const warn = $('dt-warn');
    if (dt && dt.otherRMS > 1e-4 && dt.otherRMS > 4 * dt.ifRMS) {
      warn.innerHTML = '';
      warn.append('⚠️ ', `The ${other} input is ${Math.round(20 * Math.log10(dt.otherRMS / Math.max(dt.ifRMS, 1e-9)))} dB stronger than the ${ifSide} one: the IF is probably on the ${other}.`);
      const b = document.createElement('button'); b.className = 'primary small'; b.textContent = `Use the ${other} input for the IF`;
      b.onclick = () => setParams({ syncOnRight: !params.syncOnRight });
      warn.append(b); warn.hidden = false;
    } else warn.hidden = true;
    const method = p.dtMethod === 'Matrix pencil' ? 'matrix pencil' + (dt && dt.medianOrder != null ? ` (order ${dt.medianOrder})` : '') : p.dtSVA ? 'FFT + SVA' : `FFT, ${p.dtWindow.toLowerCase()} window`;
    const pga = p.dtPGA ? (dt ? ` · PGA on ${dt.pgaApplied} of ${dt.pgaTried} dwells` : ' · PGA') : '';
    $('dt-title').textContent = `Doppler vs. time (CW), speed toward or away: ${method}${pga}`;
    $('dt-detail').textContent = `Tp ${((dt ? dt.dwellSeconds : p.dtDwellMs / 1000) * 1000).toFixed(0)} ms · ${(dt ? dt.mpsPerCol : 0).toFixed(3)} m/s per bin · colour −${p.dtDbRange}…0 dB re strongest` + (dt && dt.msPerDwell != null ? ` · ${dt.msPerDwell.toFixed(1)} ms/dwell` : '');
    $('dt-range').value = p.dtDbRange; $('dt-range-val').textContent = `${p.dtDbRange} dB`;
    $('dt-vmax').value = p.dtMaxVelocity; $('dt-vmax-val').textContent = `${p.dtMaxVelocity} m/s`;
    const i = dtRowIndex(), minV = Math.max(0.5, p.dtPGAMinVelocity);
    const peak = i != null ? dtPeak(dtRow(i), dt.mpsPerCol, minV) : null;
    let when = '';
    if (i != null) when = dt.fileName != null ? ` at t = ${(i * dt.hopSeconds).toFixed(2)} s${dtSel == null ? ' (last; click the plot above to pick a time)' : ''}` : ' (newest dwell)';
    $('dt-spec-title').textContent = `Doppler spectrum${when}, dB re strongest`;
    $('dt-spec-detail').textContent = peak ? `strongest ≥ ${minV.toFixed(1)} m/s: ${peak.velocity.toFixed(2)} m/s (${(peak.velocity * MPH).toFixed(1)} mph) @ ${(peak.db - dt.maxDB).toFixed(1)} dB` : '';
  }

  function dtSpan() {
    // rows are one hop apart (= Tp without overlap)
    const dwell = dt ? dt.hopSeconds : params.dtDwellMs / 1000 * (1 - params.dtOverlap), rows = dt ? dt.nRows : 0;
    return { dwell, rows, live: !dt || dt.fileName == null, span: !dt || dt.fileName == null ? Math.max(params.dtHistorySeconds, dwell) : Math.max(dwell, rows * dwell) };
  }

  function drawDTI() {
    const { ctx, w, h, dpr } = P.setup($('dti'));
    const { dwell, rows, live, span } = dtSpan();
    const vmax = dt ? dt.cols * dt.mpsPerCol : params.dtMaxVelocity;
    const plotH = Math.max(10, h - 40);
    const px = Math.max(40, Math.floor(plotH * dpr));
    if (px !== dtImagePx) { dtImagePx = px; buildDTImage(); }
    // Live: the image is drawn one row per screen pixel, never stretched or squeezed (resampling rows
    // that scroll makes narrow tracks flicker); the age axis is scaled to match, as in the RTI plot.
    const ySpan = live && dtImage ? px * dtSecPerPx : span;
    const ax = P.axes(ctx, Math.max(80, w - 64), h, { x: [0, Math.max(1, vmax)], y: [0, ySpan], xLabel: 'velocity (m/s)', yLabel: live ? 'age (s)' : 'time (s)', yDown: true });
    if (dtImage && live) {
      const n = Math.min(dtImage.height, Math.floor(ax.rect.h * dpr));
      ctx.save(); ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.imageSmoothingEnabled = false;
      ctx.drawImage(dtImage, 0, 0, dtImage.width, n, Math.round(ax.rect.x * dpr), Math.round(ax.rect.y * dpr), Math.round(ax.rect.w * dpr), n);
      ctx.restore();
    } else if (dtImage) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(dtImage, ax.rect.x, ax.rect.y, ax.rect.w, ax.rect.h * Math.min(1, rows * dwell / span));
      if (!live && dtSel != null) {
        const y = ax.py((dtSel + 0.5) * dwell);
        ctx.strokeStyle = 'rgba(255,255,255,0.8)'; ctx.setLineDash([4, 3]); ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(ax.rect.x, y); ctx.lineTo(ax.rect.x + ax.rect.w, y); ctx.stroke(); ctx.setLineDash([]);
      }
    } else {
      P.centerText(ctx, ax, dtBusy ? 'Processing…' : source === 'live' || source === 'sim' ? 'Collecting the first dwell…' : 'Press Start (live CW input), Simulate, or open a recording');
    }
    P.border(ctx, ax);
    P.colorBar(ctx, { x: ax.rect.x + ax.rect.w + 14, y: ax.rect.y, w: 12, h: ax.rect.h }, 0, Math.max(10, params.dtDbRange));
  }

  // click or drag on a recording's plot picks the dwell shown in the spectrum
  function pickDwell(e) {
    const { rows, live, span, dwell } = dtSpan();
    if (live || !rows) return;
    const r = $('dti').getBoundingClientRect(), plotH = Math.max(10, r.height - 40);
    const t = (e.clientY - r.top - 6) / plotH * span;
    dtSel = Math.min(rows - 1, Math.max(0, Math.floor(t / dwell)));
    requestDraw();
  }
  $('dti').addEventListener('pointerdown', (e) => { $('dti').setPointerCapture(e.pointerId); pickDwell(e); });
  $('dti').addEventListener('pointermove', (e) => { if (e.buttons) pickDwell(e); });

  function drawDTSpectrum() {
    const { ctx, w, h } = P.setup($('dt-spec'));
    const top = dt ? dt.maxDB : 0, range = Math.max(10, params.dtDbRange) + 15;
    const vmax = dt ? dt.cols * dt.mpsPerCol : params.dtMaxVelocity;
    const ax = P.axes(ctx, w, h, { x: [0, Math.max(1, vmax)], y: [-range, 3], xLabel: 'velocity (m/s)', yLabel: 'dB' });
    const i = dtRowIndex();
    if (i != null) {
      const row = dtRow(i);
      P.clip(ctx, ax);
      ctx.strokeStyle = P.css('--accent'); ctx.lineWidth = 1.2; ctx.beginPath();
      for (let k = 0; k < row.length; k++) { const x = ax.px(k * dt.mpsPerCol), y = ax.py(Math.max(-range - 1, row[k] - top)); k ? ctx.lineTo(x, y) : ctx.moveTo(x, y); }
      ctx.stroke();
      ctx.fillStyle = P.css('--red');
      for (const l of dt.lines[i] || []) {
        const x = ax.px(l.velocity), y = ax.py(Math.min(3, Math.max(-range, l.db - top)));
        ctx.beginPath(); ctx.moveTo(x, y - 1); ctx.lineTo(x - 4, y - 8); ctx.lineTo(x + 4, y - 8); ctx.closePath(); ctx.fill();
      }
      const peak = dtPeak(row, dt.mpsPerCol, Math.max(0.5, params.dtPGAMinVelocity));
      if (peak) { ctx.fillStyle = P.css('--orange'); ctx.beginPath(); ctx.arc(ax.px(peak.velocity), ax.py(peak.db - top), 4, 0, 2 * Math.PI); ctx.fill(); }
      ctx.restore();
    }
    P.border(ctx, ax);
  }

  // ---------------- SAR imaging ----------------
  const S = C.SAR;
  const SAR_STORE_KEY = 'ccr.sar.params';
  let sarParams = (() => { try { return Object.assign(S.sarDefaults(), JSON.parse(localStorage.getItem(SAR_STORE_KEY) || '{}')); } catch (e) { return S.sarDefaults(); } })();
  let sarFile = null, sarResult = null, sarBusy = false, sarSub = 'image', sarImgs = {}, sarJob = 0;
  const escapeHTML = t => String(t).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const lambdaQuarterIn = () => C.speedOfLight / (sarParams.fStopMHz * 1e6) / 4 * S.FT_PER_M * 12;
  function setSarParams(changes) {
    const old = sarParams;
    sarParams = Object.assign({}, sarParams, changes);
    try { localStorage.setItem(SAR_STORE_KEY, JSON.stringify(sarParams)); } catch (e) { /* private window */ }
    if (sarParams.dbRange !== old.dbRange || sarParams.colorTopOffsetDB !== old.colorTopOffsetDB) renderSARImages();
    refreshSidebar();
    if (activeTab === 'how') renderHow();
    requestDraw();
  }
  const sarWorker = makeWorker('sarworker');
  sarWorker.postMessage({ type: 'init', helperSource: window.CCR_BUNDLE ? window.CCR_BUNDLE.dsp + '\n' + window.CCR_BUNDLE.sarworker : null });
  function setSARStatus(t, err) { const el = $('sar-status'); el.textContent = t; el.classList.toggle('error', !!err); }
  sarWorker.onmessage = (e) => {
    const m = e.data;
    if (m.type === 'opened') { sarFile = { name: m.name, seconds: m.seconds, fs: m.fs }; refreshSidebar(); sarProcess(); }
    else if (m.type === 'progress' && m.id === sarJob) setSARStatus(m.message);
    else if (m.type === 'error' && m.id === sarJob) { sarBusy = false; setSARStatus(m.message, true); requestDraw(); }
    else if (m.type === 'result' && m.id === sarJob) {
      sarBusy = false;
      sarResult = Object.assign({ params: m.params }, m.res);
      renderSARImages();
      setSARStatus(sarSummary(sarResult), sarResult.positions < 2 || (sarResult.requestedChirps > 0 && Math.min(...sarResult.pulsesPerPosition) < sarResult.requestedChirps));
      if (activeTab === 'how') renderHow();
      requestDraw();
    }
  };
  function sarSummary(r) {
    const p = r.params, pp = r.pulsesPerPosition.slice().sort((a, b) => a - b), lo = pp[0], hi = pp[pp.length - 1];
    let chirps = lo === hi ? `${lo} up-chirps averaged at every position` : `${lo}–${hi} up-chirps averaged per position`;
    if (r.requestedChirps > 0 && lo < r.requestedChirps) chirps += ` (${r.requestedChirps} requested, but one position only has ${r.availableChirpsMin} complete chirps)`;
    else if (r.availableChirpsMin != null) chirps += ` (the shortest position has ${r.availableChirpsMin} complete)`;
    const rr = a => Math.sqrt(a.reduce((s, v) => s + v * v, 0) / a.length);
    let extra = '';
    if (r.image.pencilNote) extra += ` Super-resolution: ${r.image.pencilNote}.`;
    if (r.rangePhase) extra += ` Range PGA ${rr(r.rangePhase).toFixed(2)} rad rms.`;
    if (r.crossPhase) extra += ` Crossrange autofocus ${rr(r.crossPhase).toFixed(2)} rad rms.`;
    if (r.jitterIntegerUs != null) extra += r.jitterInterpUs != null ? ` Sync period jitter σ: integer ${r.jitterIntegerUs.toFixed(2)} → interpolated ${r.jitterInterpUs.toFixed(2)} µs.` : ` Sync period jitter σ (integer edges): ${r.jitterIntegerUs.toFixed(2)} µs.`;
    return `${r.positions} aperture positions (${(r.positions * p.spacingInches / 12).toFixed(1)} ft of rail), ${chirps}. Parsing ${r.reused ? 'reused' : r.parseSeconds.toFixed(2) + ' s'}, ${p.algorithm === S.RMA ? 'range migration' : 'backprojection'} ${r.imageSeconds.toFixed(2)} s on ${r.threads} thread${r.threads === 1 ? '' : 's'}.${extra}`;
  }
  function sarProcess() {
    if (!sarFile) { $('sar-fileinput').click(); return; }
    sarBusy = true; sarJob += 1;
    setSARStatus('Processing…');
    sarWorker.postMessage({ type: 'process', params: sarParams, id: sarJob });
    requestDraw();
  }
  async function openSARFile(file) {
    setSARStatus(`Reading ${file.name}…`);
    try {
      const w = parseWav(await file.arrayBuffer());
      if (!w) throw new Error('not a PCM or float .wav file');
      if (w.channels < 2) throw new Error(`it has ${w.channels} channel; sync and IF need 2.`);
      sarResult = null; sarImgs = {}; sarBusy = true;
      sarWorker.postMessage({ type: 'open', name: file.name, left: w.left, right: w.right, fs: w.fs }, [w.left.buffer, w.right.buffer]);
      requestDraw();
    } catch (err) {
      setSARStatus(`Couldn't read the recording: ${err && err.message ? err.message : err}`, true);
    }
  }
  $('sar-fileinput').onchange = (e) => { const f = e.target.files[0]; e.target.value = ''; if (f) openSARFile(f); };
  $('sar-open-tb').onclick = () => $('sar-fileinput').click();
  $('sar-process-tb').onclick = () => sarProcess();
  $('sar-range').oninput = (e) => setSarParams({ dbRange: Math.round(+e.target.value) });
  $('sar-top').oninput = (e) => setSarParams({ colorTopOffsetDB: Math.round(+e.target.value) });
  $('sar-top-auto').onclick = () => setSarParams({ colorTopOffsetDB: 0 });
  document.querySelectorAll('#sar-sub button').forEach(b => b.onclick = () => {
    sarSub = b.dataset.v;
    document.querySelectorAll('#sar-sub button').forEach(x => x.classList.toggle('active', x === b));
    requestDraw();
  });

  /** Jet image of a dB array ([row][col]); flip puts row 0 at the bottom. -Infinity (blanked) is the bottom colour. */
  function dbCanvas(db, rows, cols, top, range, flip) {
    const lo = top - range, cs = 255 / Math.max(1, range), rgba = new Uint8ClampedArray(rows * cols * 4);
    for (let r = 0; r < rows; r++) {
      const dst = (flip ? rows - 1 - r : r) * cols;
      for (let c = 0; c < cols; c++) {
        const i = Math.max(0, Math.min(255, Math.round((db[r * cols + c] - lo) * cs))) * 3, o = (dst + c) * 4;
        rgba[o] = C.JET[i]; rgba[o + 1] = C.JET[i + 1]; rgba[o + 2] = C.JET[i + 2]; rgba[o + 3] = 255;
      }
    }
    const cv = document.createElement('canvas');
    cv.width = cols; cv.height = rows;
    cv.getContext('2d').putImageData(new ImageData(rgba, cols, rows), 0, 0);
    return cv;
  }
  function renderSARImages() {
    const r = sarResult;
    if (!r) { sarImgs = {}; return; }
    const range = sarParams.dbRange, off = sarParams.colorTopOffsetDB || 0;
    sarImgs = {
      image: dbCanvas(r.image.db, r.image.rows, r.image.cols, r.image.maxDB + off, range, true),
      profiles: dbCanvas(r.rangeProfiles.db, r.rangeProfiles.rows, r.rangeProfiles.cols, r.rangeProfiles.maxDB + off, range, false),
      kspace: r.kSpace ? dbCanvas(r.kSpace.db, r.kSpace.rows, r.kSpace.cols, r.kSpace.maxDB + off, range, false) : null,
    };
  }

  function drawSAR() {
    const r = sarResult, p = sarParams;
    $('sar-busy').hidden = !sarBusy;
    $('sar-file').textContent = sarFile ? sarFile.name : 'no recording';
    const af = sarSub === 'autofocus';
    $('sar-canvas').hidden = af; $('sar-af').hidden = !af; $('sar-sliders').hidden = af;
    const titles = {
      image: (r ? r.algorithm : p.algorithm) === S.RMA ? 'SAR image: range migration algorithm (MIT SBAND_RMA_IFP.m)' : 'SAR image: backprojection (AFRL bpBasic.m, Gorham & Moore 2010)',
      profiles: 'Range profile at each aperture position (after mean subtraction and Hann window)',
      kspace: 'Wavenumber domain after Stolt interpolation, |S(Kx, Ky)| (range migration only)',
      autofocus: 'Autofocus: estimated phase errors (removed before image formation)',
    };
    $('sar-title').textContent = titles[sarSub];
    const off = p.colorTopOffsetDB || 0;
    const peak = !r ? null : sarSub === 'image' ? r.image.maxDB : sarSub === 'profiles' ? r.rangeProfiles.maxDB : sarSub === 'kspace' && r.kSpace ? r.kSpace.maxDB : null;
    const top = peak != null ? peak + off : null;
    $('sar-detail').textContent = top != null ? `colour ${(top - p.dbRange).toFixed(0)}…${top.toFixed(0)} dB` : '';
    $('sar-range').value = p.dbRange; $('sar-range-val').textContent = `${p.dbRange} dB`;
    $('sar-top').value = off;
    $('sar-top-val').textContent = peak != null ? `${top.toFixed(0)} dB (${off === 0 ? 'strongest pixel' : `${off > 0 ? '+' : ''}${off} dB re strongest`})` : `${off > 0 ? '+' : ''}${off} dB re strongest`;
    $('sar-top-auto').disabled = off === 0;
    if (af) { drawPhase('sar-af1', r && r.rangePhase, p.fStartMHz, p.fStopMHz, 'transmit frequency (MHz)', 'Range PGA: phase error shared by every sweep (VCO nonlinearity)', p.rangePGA ? 'Process to estimate' : 'Range PGA is off', P.css('--purple'));
      drawPhase('sar-af2', r && r.crossPhase, 1, Math.max(2, r ? r.positions : 2), 'aperture position', 'Crossrange autofocus: phase error of each aperture position', p.crossPGA ? 'Process to estimate' : 'Crossrange autofocus is off', '#30b0c7');
      return; }
    const { ctx, w, h } = P.setup($('sar-canvas'));
    if (sarSub === 'image') {
      const cr = r ? r.image.crossRange : [-p.crossRangeFt, p.crossRangeFt], dr = r ? r.image.downRange : [p.downStartFt, p.downStopFt];
      // keep 1 ft = 1 ft: shrink the plot box to the scene's aspect ratio
      const sx = (w - 132) / (cr[1] - cr[0]), sy = (h - 40) / (dr[1] - dr[0]), k = Math.max(0.01, Math.min(sx, sy));
      const pw = (cr[1] - cr[0]) * k + 62, ph = (dr[1] - dr[0]) * k + 40;
      ctx.save(); ctx.translate(Math.max(0, (w - pw - 70) / 2), 0);
      const ax = P.axes(ctx, pw, ph, { x: cr, y: dr, xLabel: 'crossrange (ft)', yLabel: 'downrange (ft)' });
      if (sarImgs.image) { ctx.imageSmoothingEnabled = true; ctx.drawImage(sarImgs.image, ax.rect.x, ax.rect.y, ax.rect.w, ax.rect.h); }
      else P.centerText(ctx, ax, sarBusy ? 'Processing…' : sarFile ? 'Press Process' : 'Open a recording to form an image');
      P.border(ctx, ax);
      if (r) P.colorBar(ctx, { x: ax.rect.x + ax.rect.w + 14, y: ax.rect.y, w: 12, h: ax.rect.h }, r.image.maxDB + off, p.dbRange);
      ctx.restore();
    } else if (sarSub === 'profiles') {
      const ax = P.axes(ctx, Math.max(80, w - 70), h, { x: [0, r ? r.rangeProfileMaxFt : p.downStopFt], y: [0, r ? r.positions : 1], xLabel: 'range (ft)', yLabel: 'aperture position', yDown: true });
      if (sarImgs.profiles) { ctx.imageSmoothingEnabled = true; ctx.drawImage(sarImgs.profiles, ax.rect.x, ax.rect.y, ax.rect.w, ax.rect.h); }
      P.border(ctx, ax);
      if (r) P.colorBar(ctx, { x: ax.rect.x + ax.rect.w + 14, y: ax.rect.y, w: 12, h: ax.rect.h }, r.rangeProfiles.maxDB + off, p.dbRange);
    } else {
      const kx = Math.PI / S.deltaX(p);
      const ax = P.axes(ctx, Math.max(80, w - 70), h, { x: [p.kStart, p.kStop], y: [-kx, kx], xLabel: 'Ky (rad/m)', yLabel: 'Kx (rad/m)', yDown: true });
      if (sarImgs.kspace) { ctx.imageSmoothingEnabled = true; ctx.drawImage(sarImgs.kspace, ax.rect.x, ax.rect.y, ax.rect.w, ax.rect.h); }
      else if (r) P.centerText(ctx, ax, 'Backprojection doesn\'t use the wavenumber domain. Choose Range migration to see it.');
      P.border(ctx, ax);
      if (r && r.kSpace) P.colorBar(ctx, { x: ax.rect.x + ax.rect.w + 14, y: ax.rect.y, w: 12, h: ax.rect.h }, r.kSpace.maxDB + off, p.dbRange);
    }
  }

  function drawPhase(id, v, x0, x1, xLabel, title, empty, color) {
    $(id + '-title').textContent = title + (v ? ` · ${C.rms(v).toFixed(2)} rad rms` : '');
    const { ctx, w, h } = P.setup($(id));
    if (!v || v.length < 2) { const ax = P.axes(ctx, w, h, { x: [x0, x1], y: [-1, 1], xLabel, yLabel: 'rad' }); P.centerText(ctx, ax, empty); P.border(ctx, ax); return; }
    let mx = 0;
    for (const y of v) mx = Math.max(mx, Math.abs(y));
    mx = Math.max(0.2, mx * 1.1);
    const ax = P.axes(ctx, w, h, { x: [x0, x1], y: [-mx, mx], xLabel, yLabel: 'rad' });
    P.clip(ctx, ax);
    ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = 1.4; ctx.beginPath();
    v.forEach((y, i) => { const px = ax.px(x0 + (x1 - x0) * i / (v.length - 1)), py = ax.py(y); i ? ctx.lineTo(px, py) : ctx.moveTo(px, py); });
    ctx.stroke();
    if (v.length < 200) v.forEach((y, i) => { ctx.beginPath(); ctx.arc(ax.px(x0 + (x1 - x0) * i / (v.length - 1)), ax.py(y), 2, 0, 2 * Math.PI); ctx.fill(); });
    ctx.restore();
    P.border(ctx, ax);
  }

  // ---------------- start ----------------
  buildSidebar();
  try { showTab(localStorage.getItem('ccr.tab') || 'radar'); } catch (e) { showTab('radar'); }
  syncControls();
  renderStats();
  updateToolbar();
  setStatus(window.isSecureContext ? 'Idle. Press Start to read the radar through the USB audio interface, Simulate to try it without the radar, or open a recording.'
    : 'This page isn\'t a secure context (https or localhost), so the browser won\'t allow audio input. Simulate and Open recording still work.', !window.isSecureContext);
  requestDraw();
  window.CCR_APP = { get params() { return params; }, setParams, startSim, startLive, stopAll, openFile, openDopplerFile, showTab, get dt() { return dt; }, get source() { return source; }, get pulseCount() { return pulseCount; } };
})();
