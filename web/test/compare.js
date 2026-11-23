// Runs a stereo .wav through the web app's RTI processor and compares it with the Mac app's
// `--rti-dump` output. Run with macOS's JavaScriptCore shell from the web/ folder:
//   jsc test/compare.js -- <file.wav> <mac-dump-prefix> '<params JSON>'
// (see test/run_compare.sh). Prints the largest differences in dB.
load('src/dsp-core.js');
load('src/pencil.js');
load('src/rangedoppler.js');
load('src/processor.js');

const [wavPath, prefix, paramsJSON] = arguments;
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
const proc = new C.RadarProcessor();
proc.update(p, wav.fs);
const rows = [];
const t0 = Date.now();
for (let start = 0; start < wav.left.length; start += 4096) {
  const n = Math.min(4096, wav.left.length - start);
  proc.push(wav.left.subarray(start, start + n), wav.right.subarray(start, start + n));
  for (const r of proc.takeSnapshot().newRows) rows.push(r);
}
const secs = (Date.now() - t0) / 1000;
const d = proc.d;
print(`web: ${rows.length} pulses (${proc.slips} skipped as glitches) x ${rows.length ? rows[0].length : 0} bins (N ${d.n}, nfft ${d.nfft}), ${secs.toFixed(2)} s (${(secs / (wav.left.length / wav.fs) * 100).toFixed(1)}% of real time)`);

const mac = readF32(prefix + '.rows.f32');
if (mac) {
  const nb = rows.length ? rows[0].length : 1, macRows = mac.length / nb;
  let maxAll = 0, maxStrong = 0, worst = null;
  const count = Math.min(rows.length, macRows);
  for (let r = 0; r < count; r++) {
    let top = -Infinity;
    for (let k = 1; k < nb; k++) if (mac[r * nb + k] > top) top = mac[r * nb + k];
    for (let k = 0; k < nb; k++) {
      const diff = Math.abs(rows[r][k] - mac[r * nb + k]);
      if (diff > maxAll) maxAll = diff;
      if (mac[r * nb + k] > top - 60 && diff > maxStrong) { maxStrong = diff; worst = [r, k, rows[r][k], mac[r * nb + k]]; }
    }
  }
  print(`mac: ${macRows} pulses. Range profiles: max |diff| ${maxStrong.toExponential(2)} dB within 60 dB of each pulse's peak, ${maxAll.toExponential(2)} dB over all cells` +
    (worst && maxStrong > 0.01 ? ` (worst pulse ${worst[0]} bin ${worst[1]}: web ${worst[2].toFixed(3)} mac ${worst[3].toFixed(3)})` : ''));
}

if (p.rdEnabled) {
  const { m, log2m } = proc.rdSize();
  const inp = proc.makeRangeDopplerInput(m, log2m);
  const macRD = readF32(prefix + '.rd.f32');
  if (inp) {
    const t1 = Date.now();
    const rd = C.computeRangeDoppler(inp);
    const ms = Date.now() - t1;
    let line = `range-Doppler: ${rd.rows} rows x ${rd.nr} bins in ${ms} ms, orders ${rd.dopplerOrder}/${rd.rangeOrder}, ${rd.scatterers.length} scatterers`;
    if (macRD && macRD.length === rd.db.length) {
      let top = -Infinity;
      for (const v of macRD) if (v > top) top = v;
      let maxIn = 0, maxAll = 0, nBig = 0;
      for (let i = 0; i < macRD.length; i++) {
        const diff = Math.abs(rd.db[i] - macRD[i]);
        if (diff > maxAll) maxAll = diff;
        if (macRD[i] > top - p.rdDbRange) { if (diff > maxIn) maxIn = diff; if (diff > 0.1) nBig++; }
      }
      line += `; vs mac: max |diff| ${maxIn.toExponential(2)} dB within the ${p.rdDbRange} dB colour range (${nBig} cells > 0.1 dB), ${maxAll.toExponential(2)} dB overall`;
    } else if (macRD) line += `; mac map has ${macRD.length} cells, web ${rd.db.length}`;
    print(line);
  }
}
