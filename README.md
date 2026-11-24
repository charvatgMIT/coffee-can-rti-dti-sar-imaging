# Coffee Can RTI DTI SAR Imaging

A native macOS app for the MIT Coffee Can Radar, with three ways of running the radar:

- **Radar (RTI):** FMCW ranging. It reads the sync and IF channels from a USB audio interface
  (tested with a Behringer UCA222) in real time, triggers on the sync square wave, and shows the
  range profile (FFT of the IF), a range-time-intensity (RTI) waterfall and a range-Doppler map.
  The processing follows `read_data_RTI.m` from the MIT IAP radar course.
- **Doppler vs. time (DTI):** the radar run as an unmodulated CW radar, after `read_data_doppler.m`.
- **SAR imaging:** synthetic aperture radar images from rail recordings. Positions are parsed as in
  MIT's Experiment 3 scripts and images are formed with AFRL backprojection or MIT's range
  migration algorithm, with optional autofocus, SVA and matrix pencil super-resolution. It is
  checked against MIT's example data set; details are in [CoffeeCanSAR/README.md](CoffeeCanSAR/README.md).

**This app supersedes the earlier Coffee Can Radar RTI and stand-alone Coffee Can SAR apps;**
use it for all new work. It is built from `CoffeeCanRadar.xcodeproj` (the RTI app's project,
renamed). The SAR code now lives in `CoffeeCanRadar/SAR/`, and the SAR settings carry over the
first time the combined app runs. The old stand-alone SAR project in `CoffeeCanSAR/` is kept for
reference only and is no longer updated.

## Features

- Live capture from any Core Audio input; the UCA222 ("USB Audio CODEC") is selected automatically.
- Rising-edge trigger on the sync channel (the same rule as `read_data_RTI.m`), with the edge
  located to a fraction of a sample by windowed-sinc upsampling (10x to 128x). Each IF pulse is
  resampled to start exactly at that edge.
- Sync on either input, with a warning if the sync appears to be on the other input or Tp
  doesn't match the sync period.
- Background options: subtract the mean pulse, 2-pulse canceller, or none.
- Rectangular, Hann, Blackman or Taylor window before the FFT, or spatially variant
  apodization (SVA), which picks the weighting per range bin for rectangular-window
  resolution with low sidelobes.
- Matrix pencil super-resolution in range (TLS, Hua & Sarkar) as an alternative to the FFT:
  shows the pencil pseudospectrum or amplitude-weighted lines, with each estimated target
  marked. The model order (number of scattering centres) is chosen every pulse by ESTER, the
  largest singular-value gap, or a fixed threshold, with optional forward-backward averaging.
- Automatic display top that follows the strongest returns without flicker.
- Range phase gradient autofocus (PGA) to remove sweep nonlinearity, with a plot of the
  estimated phase error.
- VCO band presets from the Mini-Circuits ZX95-2536C+ datasheet (full 0–5 V range, ISM band,
  or custom), showing the tuning voltage for any frequency span.
- RTI history of 10 s to 5 min with a dB colour bar; range in feet or metres; adjustable
  max range for both plots.
- Range-Doppler map (slow-time FFT over 16–256 pulses, velocity with + = approaching), with
  optional range (fast-time) and Doppler (slow-time) PGA, and matrix pencil super-resolution
  in range, Doppler or both, with an adaptive model order (ESTER by default) and a scatterer
  count. Velocity is shown in m/s. Maps are built on their own thread.
- A Doppler vs. time tab for the radar run as an unmodulated CW radar (Vtune held fixed), after
  MIT's `read_data_doppler.m`: the IF is cut into Tp dwells (250 ms), the mean is subtracted and
  each dwell's zero-padded FFT is one row of speed (0–40 m/s, −35…0 dB re the strongest cell).
  Options: SVA, a window, prominent-point PGA on the strongest mover in each dwell, and a matrix
  pencil (ESTER, gap or threshold model order) on the band-limited, decimated analytic IF.
  Dwells can overlap (50, 75 or 87.5%, a sliding window) for a smoother plot: a new row every
  Tp·(1 − overlap), same velocity resolution.
  Works live from the UCA222 or on a recording (**Open recording…**, e.g. MIT's
  "Off of Newton Exit 17.wav"); click the plot to see one dwell's spectrum. On that recording the
  FFT output matches MATLAB running MIT's script to 1e-5 dB.
- Tabs: Radar (RTI, range-Doppler map, range profile), Doppler vs. time, SAR imaging (its own
  sidebar, Open/Process buttons and sub-tabs), and Diagnostics (last triggered
  pulse, PGA phase error, rising-edge zoom). The pulse and rising-edge plots use the ADC's
  fixed full-scale axis (−1 to +1).
- Waterfall dynamic-range and time-span sliders.
- A "How it works" tab with a block diagram of the processing chain, drawn from the current settings
  (blocks for features that are switched off are greyed out). About: vibe coded by Gregory L. Charvat & Jared Smith, based on the
  original MATLAB scripts from MIT OCW (RES.LL-003, IAP 2011).
- Processing never falls behind real time: if it can't keep up, audio is skipped and the
  status line says so. `--live` starts capture at launch.
- A built-in simulator for trying the app without the radar.

## Requirements

- A Mac with macOS 14 or later, and Xcode to build.
- The radar's sync output and IF output connected to the two inputs of a stereo USB audio
  interface.

## Web version (Windows, Mac, Linux)

A web version with all three modes (RTI, Doppler vs. time and SAR imaging) is in
[`web/`](web/README.md): one HTML file (`web/dist/coffee-can-radar.html`) that runs in Chrome, Edge,
Firefox or Safari and reads the UCA222 directly. It runs the same processing as this app, checked
against it pulse by pulse, dwell by dwell and pixel by pixel.

## Install on a Mac without Xcode

Download the disk image (`Coffee-Can-RTI-DTI-SAR-Imaging-<version>.dmg`), open it and drag the app
onto Applications. It runs on Apple Silicon and Intel Macs with macOS 14 or later.

The app isn't signed with an Apple Developer ID yet, so the first time it's opened macOS says it
can't verify it. Open System Settings → Privacy & Security, click **Open Anyway** next to the app
and confirm; then allow microphone access (the radar's sync and IF come in through the audio
interface). "How to open.txt" on the disk image has the same steps.

To make the disk image: `Tools/make_release.sh` (needs Xcode; writes `build/dist/`). With an Apple
Developer ID it can also sign and notarize the app so it opens without the warning; see the
comments at the top of the script.

## Build and run

1. Open `CoffeeCanRadar.xcodeproj` in Xcode.
2. Choose the **CoffeeCanRadar** scheme and **My Mac**, then press **⌘R**.
3. In the app, check the input menu shows your audio interface and click **Start**.
   Allow microphone access when macOS asks.

Set **Up-ramp time Tp** to your radar's up-chirp length. With the sync high during the
up-chirp and low during the down-chirp, Tp is half the sync period.

## Self-test

The app can check its own processing without the radar:

```bash
"Coffee Can RTI DTI SAR Imaging.app/Contents/MacOS/Coffee Can RTI DTI SAR Imaging" --selftest
```

Other options: `--list-devices` lists audio inputs, `--simulate` starts with the built-in
simulator, `--open-doppler <file.wav>` opens a CW recording in the Doppler vs. time tab, and
`--open-sar <file.wav>` opens a SAR recording, `--dump <file.wav> <dir>` writes the parsed SAR
data, and `--rti-dump` and `--sar-dump` write the RTI and SAR outputs for the web version's checks, and
`--doppler-dump <file.wav> <out.f32>` writes its Doppler vs. time rows (dB re the strongest
cell, float32) for comparison with MATLAB.
