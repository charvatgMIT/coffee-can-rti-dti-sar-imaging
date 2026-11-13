# Coffee Can Radar RTI

A native macOS app for the MIT Coffee Can Radar. It reads the sync and IF channels from a
USB audio interface (tested with a Behringer UCA222) in real time, triggers on the sync
square wave, and shows the range profile (FFT of the IF) and a range-time-intensity (RTI)
waterfall. The processing follows `read_data_RTI.m` from the MIT IAP radar course.

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
- Two tabs: Radar (RTI, range-Doppler map, range profile) and Diagnostics (last triggered
  pulse, PGA phase error, rising-edge zoom). The pulse and rising-edge plots use the ADC's
  fixed full-scale axis (−1 to +1).
- Waterfall dynamic-range and time-span sliders.
- Processing never falls behind real time: if it can't keep up, audio is skipped and the
  status line says so. `--live` starts capture at launch.
- A built-in simulator for trying the app without the radar.

## Requirements

- A Mac with macOS 14 or later, and Xcode to build.
- The radar's sync output and IF output connected to the two inputs of a stereo USB audio
  interface.

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
CoffeeCanRadarRTI.app/Contents/MacOS/CoffeeCanRadarRTI --selftest
```

Other options: `--list-devices` lists audio inputs, and `--simulate` starts with the built-in
simulator.
