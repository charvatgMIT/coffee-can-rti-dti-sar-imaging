load('src/dsp-core.js'); load('src/pencil.js'); load('src/rangedoppler.js'); load('src/processor.js'); load('src/sar.js');
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


async function bench(wav, log) {
  const S = CCR.SAR, p = Object.assign(S.sarDefaults(), { superRes: 'Matrix pencil in crossrange' });
  let t = Date.now();
  const d = S.parseSAR(wav, p); log('parse ' + (Date.now() - t) + ' ms'); t = Date.now();
  const f = S.autofocus(d, p); log('autofocus ' + (Date.now() - t) + ' ms'); t = Date.now();
  const M = f.positions, K = f.cols;
  const bp = new S.BPProfiles(f.re, f.im, M, K, p, true);
  const cols = 1601, rows = 1397, FT = S.FT_PER_M;
  const xs = new Float64Array(cols).map((_, i) => (-200 + 400 * i / (cols - 1)) / FT), ys = new Float64Array(rows).map((_, i) => (1 + 349 * i / (rows - 1)) / FT);
  const r0 = 600, r1 = 620;
  const out = S.backprojectRows(bp, xs, ys, cols, r0, r1, false, 0); log('backprojection 20 rows ' + (Date.now() - t) + ' ms'); t = Date.now();
  const re = new Float32Array(20 * cols), im = new Float32Array(20 * cols);
  for (let r = 0; r < 20; r++) { re.set(out.subarray(r * cols * 2, r * cols * 2 + cols), r * cols); im.set(out.subarray(r * cols * 2 + cols, (r + 1) * cols * 2), r * cols); }
  const [fit] = S.crossPencilRows(bp, xs, ys, re, im, cols, r0, r1, M, p, 0, r0);
  const ms = Date.now() - t;
  log(`crossrange pencil 20 rows: ${fit} pixels in ${ms} ms = ${(ms * 1000 / fit).toFixed(1)} µs per pixel`);
}

bench(readWav(arguments[0]), print);
