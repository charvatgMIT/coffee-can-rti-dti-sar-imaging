// Coffee Can Radar web app: builds range-Doppler maps off the main DSP worker (RangeDoppler.swift).
/* global importScripts */
if (!self.CCR || !self.CCR.computeRangeDoppler) importScripts('dsp-core.js', 'pencil.js', 'rangedoppler.js');
self.onmessage = (e) => {
  const inp = e.data.inp;
  let map = null;
  try { map = self.CCR.computeRangeDoppler(inp); } catch (err) { map = null; }
  if (map) {
    map.generation = inp.generation;
    const tr = [map.db.buffer, map.rgba.buffer];
    if (map.slowPhase) tr.push(map.slowPhase.buffer);
    self.postMessage({ map }, tr);
  } else {
    self.postMessage({ map: null, generation: inp.generation });
  }
};
