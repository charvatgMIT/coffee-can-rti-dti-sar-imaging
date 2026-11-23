// Coffee Can Radar web app: canvas plotting (axes, colour bar, waterfall buffer). Plots.swift in the Mac app.
(function (C) {
  'use strict';

  function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

  /** Sizes a canvas to its box at device resolution; returns {ctx, w, h, dpr} in CSS pixels. */
  function setup(canvas) {
    const dpr = window.devicePixelRatio || 1;
    const r = canvas.getBoundingClientRect();
    const w = Math.max(10, Math.floor(r.width)), h = Math.max(10, Math.floor(r.height));
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);
    return { ctx, w, h, dpr };
  }

  function niceStep(span, count) {
    const raw = span / Math.max(1, count);
    const p = Math.pow(10, Math.floor(Math.log10(raw)));
    const m = raw / p;
    return (m < 1.5 ? 1 : m < 3.5 ? 2 : m < 7.5 ? 5 : 10) * p;
  }

  function tickLabel(v, step) {
    const dec = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3;
    return (Math.abs(v) < step * 1e-6 ? 0 : v).toFixed(dec);
  }

  /** Background, grid, ticks and labels in a w×h box (CSS px); returns the data-to-pixel mapping. */
  function axes(ctx, w, h, o) {
    const rect = { x: 52, y: 6, w: Math.max(10, w - 62), h: Math.max(10, h - 40) };
    const x0 = o.x[0], x1 = o.x[1] > o.x[0] ? o.x[1] : o.x[0] + 1;
    const y0 = o.y[0], y1 = o.y[1] > o.y[0] ? o.y[1] : o.y[0] + 1;
    const ax = {
      rect, x0, x1, y0, y1,
      px: v => rect.x + (v - x0) / (x1 - x0) * rect.w,
      py: v => o.yDown ? rect.y + (v - y0) / (y1 - y0) * rect.h : rect.y + rect.h - (v - y0) / (y1 - y0) * rect.h,
    };
    ctx.fillStyle = css('--plot-bg');
    ctx.fillRect(rect.x, rect.y, rect.w, rect.h);
    ctx.strokeStyle = css('--grid'); ctx.lineWidth = 0.5;
    ctx.fillStyle = css('--text2'); ctx.font = '10px -apple-system, "Segoe UI", sans-serif';
    const sx = niceStep(x1 - x0, rect.w / 80);
    ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    for (let v = Math.ceil(x0 / sx) * sx; v <= x1 + sx * 1e-6; v += sx) {
      const px = ax.px(v);
      ctx.beginPath(); ctx.moveTo(px, rect.y); ctx.lineTo(px, rect.y + rect.h); ctx.stroke();
      ctx.fillText(tickLabel(v, sx), px, rect.y + rect.h + 3);
    }
    const sy = niceStep(y1 - y0, rect.h / 36);
    ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    for (let v = Math.ceil(y0 / sy) * sy; v <= y1 + sy * 1e-6; v += sy) {
      const py = ax.py(v);
      ctx.beginPath(); ctx.moveTo(rect.x, py); ctx.lineTo(rect.x + rect.w, py); ctx.stroke();
      ctx.fillText(tickLabel(v, sy), rect.x - 4, py);
    }
    ctx.font = '11px -apple-system, "Segoe UI", sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'bottom';
    ctx.fillText(o.xLabel || '', rect.x + rect.w / 2, h - 2);
    ctx.save(); ctx.translate(11, rect.y + rect.h / 2); ctx.rotate(-Math.PI / 2);
    ctx.textBaseline = 'middle'; ctx.fillText(o.yLabel || '', 0, 0); ctx.restore();
    return ax;
  }

  function border(ctx, ax) {
    ctx.strokeStyle = css('--border'); ctx.lineWidth = 1;
    ctx.strokeRect(ax.rect.x + 0.5, ax.rect.y + 0.5, ax.rect.w - 1, ax.rect.h - 1);
  }

  function clip(ctx, ax) { ctx.save(); ctx.beginPath(); ctx.rect(ax.rect.x, ax.rect.y, ax.rect.w, ax.rect.h); ctx.clip(); }

  function centerText(ctx, ax, text) {
    ctx.fillStyle = css('--text2'); ctx.font = '12px -apple-system, "Segoe UI", sans-serif';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(text, ax.rect.x + ax.rect.w / 2, ax.rect.y + ax.rect.h / 2);
  }

  /** Vertical jet colour bar: `top` dB at the top, `top - range` at the bottom. */
  function colorBar(ctx, r, top, range) {
    const steps = 128, h = r.h / steps;
    for (let s = 0; s < steps; s++) {
      const i = Math.round((steps - 1 - s) / (steps - 1) * 255) * 3;
      ctx.fillStyle = `rgb(${C.JET[i]},${C.JET[i + 1]},${C.JET[i + 2]})`;
      ctx.fillRect(r.x, r.y + s * h, r.w, h + 0.5);
    }
    ctx.strokeStyle = css('--border'); ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
    const lo = top - range, step = niceStep(range, r.h / 36);
    ctx.fillStyle = css('--text2'); ctx.font = '10px -apple-system, "Segoe UI", sans-serif';
    ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    for (let v = Math.ceil(lo / step) * step; v <= top + step * 1e-6; v += step) {
      const y = r.y + r.h - (v - lo) / range * r.h;
      ctx.strokeStyle = css('--text2'); ctx.beginPath(); ctx.moveTo(r.x + r.w, y); ctx.lineTo(r.x + r.w + 3, y); ctx.stroke();
      ctx.fillText(v.toFixed(0), r.x + r.w + 5, y);
    }
    ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    ctx.fillText('dB', r.x + r.w / 2, r.y + r.h + 4);
  }

  /**
   * Rolling range-time-intensity image, newest row first, jet-coloured (RTIBuffer in the Mac app).
   * At most `maxRows` rows (the plot's height in device pixels) so drawing never drops rows: long
   * histories combine several pulses per row, keeping the strongest value in each range bin.
   */
  class RTIBuffer {
    constructor() {
      this.maxRows = 400; this.height = 400; this.pulsesPerRow = 1; this.width = 0; this.rows = 0;
      this.raw = null; this.rawCap = 0; this.rawNewest = 0; this.rawCount = 0;
      this.db = null; this.rgba = null; this.newest = 0; this.pending = null; this.pendingCount = 0;
      this.canvas = document.createElement('canvas');
      this.ctx = this.canvas.getContext('2d');
      this.dirtyAll = true; this.dirtyRows = new Set();
    }
    reset(width, pulses, viewPulses, top, range) {
      this.width = width;
      this.rawCap = Math.max(10, pulses);
      this.raw = new Float32Array(width * this.rawCap).fill(-400);
      this.rawNewest = 0; this.rawCount = 0;
      this.configureView(viewPulses);
      this.recolor(top, range);
    }
    setView(pulses, top, range) {
      this.configureView(pulses);
      const ppr = this.pulsesPerRow, w = this.width;
      for (let r = 0; r < this.height; r++) {
        const first = r * ppr;
        if (first >= this.rawCount) break;
        const base = r * w;
        for (let i = first; i < Math.min(first + ppr, this.rawCount); i++) {
          const src = ((this.rawNewest + i) % this.rawCap) * w;
          for (let k = 0; k < w; k++) if (this.raw[src + k] > this.db[base + k]) this.db[base + k] = this.raw[src + k];
        }
        this.rows = r + 1;
      }
      this.recolor(top, range);
    }
    configureView(pulses) {
      const total = Math.max(10, Math.min(pulses, this.rawCap));
      this.pulsesPerRow = Math.max(1, Math.ceil(total / this.maxRows));
      this.height = Math.max(10, Math.floor(total / this.pulsesPerRow));
      this.rows = 0; this.newest = 0; this.pending = null; this.pendingCount = 0;
      this.db = new Float32Array(this.width * this.height).fill(-400);
      this.rgba = new Uint8ClampedArray(this.width * this.height * 4);
      this.canvas.width = Math.max(1, this.width); this.canvas.height = this.height;
      this.dirtyAll = true;
    }
    append(row, top, range) {
      const w = this.width;
      if (row.length !== w || !w) return false;
      this.rawNewest = (this.rawNewest - 1 + this.rawCap) % this.rawCap;
      this.raw.set(row, this.rawNewest * w);
      this.rawCount = Math.min(this.rawCount + 1, this.rawCap);
      if (this.pendingCount === 0) this.pending = Float32Array.from(row);
      else for (let k = 0; k < w; k++) if (row[k] > this.pending[k]) this.pending[k] = row[k];
      this.pendingCount += 1;
      if (this.pendingCount < this.pulsesPerRow) return false;
      this.pendingCount = 0;
      this.newest = (this.newest - 1 + this.height) % this.height;
      this.db.set(this.pending, this.newest * w);
      this.colorRow(this.newest, top, range);
      this.rows = Math.min(this.rows + 1, this.height);
      return true;
    }
    recolor(top, range) { for (let r = 0; r < this.height; r++) this.colorRow(r, top, range, true); this.dirtyAll = true; }
    colorRow(r, top, range, bulk) {
      const lo = top - range, scale = 255 / Math.max(1, range), w = this.width, base = r * w;
      for (let k = 0; k < w; k++) {
        const i = Math.max(0, Math.min(255, Math.round((this.db[base + k] - lo) * scale))) * 3, p = (base + k) * 4;
        this.rgba[p] = C.JET[i]; this.rgba[p + 1] = C.JET[i + 1]; this.rgba[p + 2] = C.JET[i + 2]; this.rgba[p + 3] = 255;
      }
      if (!bulk) this.dirtyRows.add(r);
    }
    /** Copies changed rows into the backing canvas. */
    flush() {
      if (!this.width) return;
      if (this.dirtyAll) {
        this.ctx.putImageData(new ImageData(this.rgba, this.width, this.height), 0, 0);
      } else {
        for (const r of this.dirtyRows) {
          const img = new ImageData(this.rgba.slice(r * this.width * 4, (r + 1) * this.width * 4), this.width, 1);
          this.ctx.putImageData(img, 0, r);
        }
      }
      this.dirtyAll = false; this.dirtyRows.clear();
    }
    /** Draws columns 0..cols-1, newest row at the top, into dx, dy (CSS px), dw wide and 1 row per device pixel. */
    draw(ctx, cols, dx, dy, dw, dpr) {
      this.flush();
      const h = this.height, top = h - this.newest, sw = Math.min(cols, this.width);
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(this.canvas, 0, this.newest, sw, top, dx, dy, dw, top / dpr);
      if (this.newest > 0) ctx.drawImage(this.canvas, 0, 0, sw, this.newest, dx, dy + top / dpr, dw, this.newest / dpr);
    }
  }

  C.Plot = { css, setup, axes, border, clip, centerText, colorBar, niceStep, RTIBuffer };
})(globalThis.CCR = globalThis.CCR || {});
