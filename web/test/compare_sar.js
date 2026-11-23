// Runs a SAR recording through the web app's SAR chain and compares the image with the Mac app's
// `--sar-dump` output. Run from web/:  jsc test/compare_sar.js -- <file.wav> <mac-prefix> '<params JSON>'
load('src/dsp-core.js');
load('src/pencil.js');
load('src/rangedoppler.js');
load('src/processor.js');
load('src/sar.js');

const [wavPath, prefix, paramsJSON] = arguments;
const C = globalThis.CCR, S = C.SAR;

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


const p = Object.assign(S.sarDefaults(), JSON.parse(paramsJSON || '{}'));
const wav = readWav(wavPath);
const t0 = Date.now();
S.processSAR(wav, p, null, null).then(r => {
  const secs = (Date.now() - t0) / 1000, img = r.image, d = r.data, f = r.focused;
  const rr = a => a ? Math.sqrt(a.reduce((s, v) => s + v * v, 0) / a.length).toFixed(4) : '-';
  print(`web: ${d.positions} positions, pulses ${Math.min(...d.pulsesPerPosition)}-${Math.max(...d.pulsesPerPosition)}; image ${img.rows} x ${img.cols}, cross ${img.crossRange[0].toFixed(2)}..${img.crossRange[1].toFixed(2)} ft, max ${img.maxDB.toFixed(3)} dB; range PGA ${rr(f.rangePhase)} rad rms, cross ${rr(f.crossPhase)} rad rms; ${secs.toFixed(2)} s${img.pencilNote ? '; ' + img.pencilNote : ''}`);
  const mac = readF32(prefix + '.img.f32');
  if (mac && mac.length === img.db.length) {
    let maxIn = 0, maxAll = 0, big = 0, n = 0, worst = null, blankMismatch = 0;
    for (let i = 0; i < mac.length; i++) {
      const a = img.db[i], b = mac[i];
      if (a === -Infinity || b === -Infinity) { if (a !== b) blankMismatch++; continue; }
      const diff = Math.abs((a - img.maxDB) - (b - img.maxDB));
      if (diff > maxAll) maxAll = diff;
      if (b > img.maxDB - p.dbRange) { n++; if (diff > maxIn) { maxIn = diff; worst = [Math.floor(i / img.cols), i % img.cols, a, b]; } if (diff > 0.1) big++; }
    }
    print(`mac: max |diff| ${maxIn.toExponential(2)} dB over ${n} pixels within the ${p.dbRange} dB colour range (${big} > 0.1 dB), ${maxAll.toExponential(2)} dB overall, ${blankMismatch} blanking mismatches` +
      (worst && maxIn > 0.01 ? ` (worst row ${worst[0]} col ${worst[1]}: web ${worst[2].toFixed(2)} mac ${worst[3].toFixed(2)})` : ''));
  } else print(`mac image: ${mac ? mac.length + ' pixels vs web ' + img.db.length : 'missing'}`);
  const macP = readF32(prefix + '.prof.f32');
  if (macP && macP.length === r.rangeProfiles.db.length) {
    let m = 0; for (let i = 0; i < macP.length; i++) m = Math.max(m, Math.abs(macP[i] - r.rangeProfiles.db[i]));
    print(`range profiles: max |diff| ${m.toExponential(2)} dB`);
  }
}).catch(e => print('ERROR ' + e + '\n' + e.stack));
