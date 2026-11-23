# Coffee Can Radar: web version

All three modes of Coffee Can RTI DTI SAR Imaging (RTI, Doppler vs. time and SAR imaging) as a web page, so it runs on Windows, Mac, Linux
and Chromebooks in Chrome, Edge, Firefox or Safari with nothing to install. It reads the radar's sync and IF through a USB audio interface (e.g. the
Behringer UCA222) and shows the RTI waterfall, the range-Doppler map and the range profile, with
the same options as the Mac app: sub-sample sync interpolation, windows, SVA, range PGA, matrix
pencil super-resolution (ESTER, gap or threshold model order), range-Doppler with range and
Doppler PGA and matrix pencil, and the Diagnostics and How it works tabs. It also has the built-in
simulator and can play a stereo .wav recording through the processing.

The **Doppler vs. time** tab is for the radar run as an unmodulated CW radar (Vtune held fixed),
after MIT's `read_data_doppler.m`: FFT, SVA, window, prominent-point PGA and matrix pencil, live or
from a recording (click the plot to see one dwell's spectrum), with the IF channel swap and a level
check. As in the Mac app, only the selected tab's processing runs. The simulator gives FMCW targets
on the Radar tab and a CW car and walker on the Doppler tab.

The **SAR imaging** tab forms images from rail recordings, as the Mac app's: MIT Experiment 3
parsing (sub-sample edges or MIT's integer rule, a fixed number of up-chirps per position), AFRL
backprojection or MIT's range migration, range PGA and crossrange autofocus, SVA (joint, separate,
dual, Hann cap), matrix pencil super-resolution in range and crossrange, grating-lobe blanking and
the 1-inch full field of view, with range profiles, K-space and autofocus plots. Its settings are
kept separately. Backprojection rows and the crossrange pencil are shared over helper threads; the
crossrange pencil is still slow in a browser (about a minute at 0.25-ft pixels in Chrome, against
about 10 s in the Mac app), everything else takes about a second.

## Using it

**`dist/coffee-can-radar.html`** is the whole app in one file. Either put it on a web server
(any https address works) or open it from disk in Chrome or Edge. Then:

1. Plug in the audio interface (sync and IF on its two inputs) and press **Start**.
2. Allow microphone access when the browser asks: the page uses it to read the audio interface.
   The UCA222 ("USB Audio CODEC") is picked automatically; another input can be chosen in the menu.

Browsers only allow audio input on secure pages (https, or a file opened from disk in Chrome
and Edge). **Simulate** and **Open recording…** work anywhere.

Settings are remembered in the browser.

## How it's built

- `src/dsp-core.js`, `pencil.js`, `rangedoppler.js`, `processor.js`: the signal processing, a
  line-by-line port of the Mac app's Swift (RadarProcessor, RangePGA, SVA, MatrixPencil,
  RangeDoppler). The matrix pencil's eigen and Schur decompositions, done by LAPACK on the Mac,
  are written out here (Householder tridiagonalization + implicit QL, shifted QR).
- `src/worker.js`: runs the processing in a background thread; audio arrives from an
  AudioWorklet with echo cancellation, noise suppression and gain control switched off.
  At most 0.5 s of audio may wait, as in the Mac app. `src/rdworker.js` builds the
  range-Doppler maps in a second thread.
- `src/app.js`, `plots.js`, `style.css`, `index.html`: the page.
- `src/doppler.js`: Doppler vs. time (DopplerTime.swift) and the CW simulator.
- `src/sar.js`, `src/sarworker.js`: SAR imaging (SARProcessing.swift) and its worker, which shares
  backprojection and the crossrange pencil out to helper copies of itself.
- `tools/build.py` makes the single-file `dist/coffee-can-radar.html`.

To develop, serve this folder over http (`python3 -m http.server --directory web`) and open
http://localhost:8000; rebuild the single file with `python3 tools/build.py`.

## Checked against the Mac app

`test/run_compare.sh` runs a recording through both this code (with macOS's JavaScriptCore shell)
and the Mac app (`--rti-dump`) and compares every pulse:

- MIT's `running_outside_20ms.wav` (1905 pulses): FFT with rectangular, Hann and Taylor windows,
  SVA, 2-pulse canceller, no alignment, PGA, and PGA + SVA all match to float precision (0 dB).
- Simulated Tp = 5 ms recording (`test/make_sim_wav.py`): matrix pencil (ESTER, gap, threshold,
  with and without forward-backward, lines display, with PGA) within 0.15 dB, except one pulse
  where the Mac app's fit fails (blank) and this one returns a profile. Range-Doppler maps:
  FFT, range pencil and range + Doppler pencil identical; Doppler pencil within 0.7 dB in 22 of
  131,000 cells.
- Doppler vs. time on MIT's "Off of Newton Exit 17.wav" (`test/run_compare_dti.sh`, against the
  Mac app's `--doppler-dump`, which matches MATLAB running MIT's script): FFT, SVA, PGA (253 of 282
  dwells focused in both), matrix pencil with and without PGA, gap rule and 8× zero-padding all
  identical within the colour range.
- SAR imaging on MIT's `towardswarehouse.wav` (`test/run_compare_sar.sh`, against the Mac app's
  `--sar-dump`): backprojection (default and MIT-exact parsing), range migration, SVA joint /
  separate / dual and with range migration, range and crossrange matrix pencil, the display options
  and the 1-inch full field of view all match within 0.0004 dB inside the colour range (most to
  0.00001 dB); range profiles and the autofocus estimates are identical.
- Audio glitches: through Chrome's audio engine the page saw 32 pulses hit by dropped or repeated
  sample blocks in 97 s (its clock follows the Mac's output device, not the interface); reading the
  interface directly (Chrome, Edge) brought that to 2, and the glitch guard skips those pulses.
- Live from the UCA222 in Chrome: keeps real time at 101.9 pulses/s, including matrix pencil +
  PGA on every pulse (1.8 ms per pulse).
