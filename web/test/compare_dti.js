// Runs a recording through the web app's Doppler-vs-time engine and compares it with the Mac app's
// `--doppler-dump` output (float32 rows of dB re the strongest cell). Run from web/:
//   jsc test/compare_dti.js -- <file.wav> <mac.f32> '<params JSON>'   (see test/run_compare_dti.sh)
load('src/dsp-core.js');
load('src/pencil.js');
load('src/rangedoppler.js');
load('src/processor.js');
load('src/doppler.js');

const [wavPath, macPath, paramsJSON] = arguments;
const C = globalThis.CCR;

function readWav(path) {
  const b = read(path, 'binary');
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let off = 12, fmt = null, data = null;
  while (off + 8 <= b.length) {
    const id = String.fromCharCode(b[off], b[off + 1], b[off + 2], b[off + 3]);
    const size = dv.getUint32(off + 4, true);
    if (id === 'fmt ') fmt = { channels: dv.getUint16(off + 10, true), fs: dv.getUint32(off + 12, true), bits: dv.getUint16(off + 22, true), format: dv.getUint16(off + 8, true) };
    if (id === 'data') data = { off: off + 8, size };
    off += 8 + size + (size & 1);
  }
  const ch = fmt.channels, bytes = fmt.bits / 8, frames = Math.floor(data.size / (ch * bytes));
  const left = new Float32Array(frames), right = new Float32Array(frames);
  for (let i = 0; i < frames; i++) {
    const p = data.off + i * ch * bytes;
    if (fmt.bits === 16) { left[i] = dv.getInt16(p, true) / 32768; right[i] = dv.getInt16(p + 2, true) / 32768; }
    else if (fmt.bits === 32 && fmt.format === 3) { left[i] = dv.getFloat32(p, true); right[i] = dv.getFloat32(p + 4, true); }
    else if (fmt.bits === 24) {
      const g = q => { let v = b[q] | (b[q + 1] << 8) | (b[q + 2] << 16); if (v & 0x800000) v -= 0x1000000; return v / 8388608; };
      left[i] = g(p); right[i] = g(p + 3);
    } else throw new Error('unsupported wav format');
  }
  return { fs: fmt.fs, left, right };
}

function readF32(path) {
  try { const b = read(path, 'binary'); return new Float32Array(b.buffer, b.byteOffset, b.byteLength / 4); } catch (e) { return null; }
}


const p = Object.assign(C.defaultParams(), JSON.parse(paramsJSON || '{}'));
const wav = readWav(wavPath);
const eng = new C.DopplerTimeEngine();
let snap = null;
eng.onSnapshot = s => { snap = s; };
eng.setParams(p);
const t0 = Date.now();
eng.loadFile('rec', wav.left, wav.right, wav.fs);
const secs = (Date.now() - t0) / 1000;
print(`web: ${snap.nRows} dwells x ${snap.cols} bins, ${snap.mpsPerCol.toFixed(5)} m/s per bin, ${secs.toFixed(2)} s (${(secs / (wav.left.length / wav.fs) * 100).toFixed(1)}% of real time), order ${snap.medianOrder ?? '-'}, PGA ${snap.pgaApplied}/${snap.pgaTried}`);
const mac = readF32(macPath);
if (mac) {
  const n = Math.min(mac.length, snap.rows.length);
  let maxIn = 0, maxAll = 0, big = 0, worst = null;
  for (let i = 0; i < n; i++) {
    const w = snap.rows[i] - snap.maxDB, m = mac[i], diff = Math.abs(w - m);
    if (diff > maxAll) maxAll = diff;
    if (m > -p.dtDbRange) { if (diff > maxIn) { maxIn = diff; worst = [Math.floor(i / snap.cols), i % snap.cols, w, m]; } if (diff > 0.1) big++; }
  }
  print(`mac: ${mac.length / snap.cols} dwells. max |diff| ${maxIn.toExponential(2)} dB within the ${p.dtDbRange} dB colour range (${big} cells > 0.1 dB), ${maxAll.toExponential(2)} dB overall` +
    (worst && maxIn > 0.01 ? ` (worst dwell ${worst[0]} bin ${worst[1]}: web ${worst[2].toFixed(2)} mac ${worst[3].toFixed(2)})` : ''));
}
