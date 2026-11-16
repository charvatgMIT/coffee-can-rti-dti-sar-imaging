# Coffee Can SAR

A macOS test GUI that forms synthetic aperture radar (SAR) images from MIT Coffee Can Radar
recordings. Parsing is a direct port of MIT's Experiment 3 script `SBAND_RMA_opendata.m`
(Gregory L. Charvat). Images are formed by either of two algorithms:

- **Backprojection (default):** a port of AFRL's `bpBasic.m` (LeRoy Gorham; Gorham & Moore,
  "SAR image formation toolbox for MATLAB", SPIE 7669, 2010;
  https://github.com/bambang/osubp/blob/master/bpBasic.m). Each aperture position is one pulse
  whose averaged chirp is its frequency-domain phase history. The phase history is conjugated to
  AFRL's sign convention and referenced to R0 (by default the middle of the scene), because
  `bpBasic`'s ±c/(4Δf) swath (±100 m here) must cover the scene. For each pixel, the zero-padded
  range profile is interpolated at that pixel's range from the antenna, phase-corrected and summed.
  The crossrange orientation matches MIT's image.
- **Range migration:** a port of MIT's `SBAND_RMA_IFP.m`.

The steps are:

1. **Parsing:** the sync channel goes quiet while the radar is moved along the rail, so each burst
   after at least Trp (0.25 s) of silence is one aperture position. Each position's up-chirps
   are averaged, then Hilbert-transformed to N/2 complex samples. Up-chirps are aligned in one
   of two ways:
   - **Sub-sample edge (default):** the trigger interpolation from the Coffee Can Radar RTI app.
     The rising sync edge is upsampled with a windowed-sinc interpolator and refined linearly to
     the threshold crossing, then each chirp is resampled to start exactly there.
   - **Integer sample:** MIT's own rule, which reproduces the .mat files exactly.

   **Up-chirps per position (default 20):** every position averages exactly this many chirps,
   taken as the first complete ones, so the integration is the same across the whole aperture.
   Uneven averaging shows up as azimuth clutter. The whole time at each position is searched,
   not just the first Trp. If any position has fewer chirps, every position uses that smaller
   number and the status line says so. 0 reproduces MIT's script: every chirp in the first Trp,
   which varies from 2 to 5 per position on the warehouse recording. The sync is on for about
   2.3 s at each position (at least 57 complete chirps).
2. **Mean subtraction and autofocus**, before either algorithm:
   - **Exact mean subtraction (default):** removes the common component, mostly direct antenna
     leakage. MIT's script recomputes the mean after each row it changes, which leaves
     (1 − 1/M)^M ≈ 37% of it; without a window that shows as a stripe at zero crossrange. MIT's
     running mean is still available as an option.
   - **Range PGA (fast time):** one phase per frequency sample, shared by every sweep (VCO
     nonlinearity). Each position's strongest return is centred and windowed, and the phase
     gradient is summed over positions.
   - **Crossrange autofocus:** one phase per aperture position. Each position's phase is chosen so
     its backprojected contribution to the strongest scatterers adds coherently with the others.
   - **Checks:** both recover known synthetic errors (range: 0.16 of 3.0 rad rms; crossrange: 0.10
     of 0.4 rad rms), and the point targets come back to within 0.2 dB of their error-free peaks.
     On the warehouse recording they estimate 0.28 and 0.15 rad rms. Both estimates are plotted on
     the Autofocus tab.
3. **SVA (optional):** spatially variant apodization on the complex image, applied along the line
   of sight (spacing c/2B) and across it (λR/(2L·cos θ)). The data are processed without the Hann
   windows. SVA needs each response at baseband, so the known carrier is removed first, then the
   local residual carrier (the real sweep differs from the nominal one) is estimated from the image
   and removed.
   - **Resolution:** stays unwindowed (1.3 ft in range, against 2.3 ft with Hann).
   - **SVA type** (default **joint I/Q**): joint I/Q picks one weight per complex pixel; separate
     I/Q (Stankwitz's original) picks one each for I and Q; dual apodization keeps the smaller of
     the unweighted and Hann images.
   - **Limit by the Hann image (default on):** each pixel is capped at the gain-matched Hann value.
     Unweighted range sidelobes fall off at only −6 dB/octave, so strong close-in returns leave
     radial tails to far range, where the range^(3/2) scaling brightens them. Hann's sidelobes fall
     off at −18 dB/octave.
   - **On the warehouse scene:** far-range clutter is −3.7 dB relative to the scene (Hann −5.4 dB,
     uncapped unweighted −0.3 dB), with no radial streaking.
   - **On synthetic point targets:** sidelobes are −35 to −46 dB with joint I/Q and −47 to −68 dB
     with separate I/Q.
4. **Range migration algorithm**, when selected (Carrara, Goodman & Majewski, ch. 10):
   - subtract the mean over the aperture;
   - Hann window in fast time;
   - symmetric zero pad and FFT along the aperture;
   - matched filter;
   - Stolt interpolation to an even Ky grid;
   - 4× zero-padded 2-D inverse FFT;
   - crop and range^(3/2) scaling.

**Matrix pencil super-resolution (optional),** using the RTI app's TLS matrix pencil with the gap rule by
default (or ESTER), up to 8 scatterers per fit, with forward–backward averaging:

- **Range (bandwidth extrapolation):** at each position the frequency samples are a sum of complex
  exponentials, one per scatterer. The poles, put on the unit circle, and least-squares amplitudes
  extend the band to 3× its width (about 1930–2920 MHz), with the measured samples kept in the middle.
  Image formation then sees a wider band, so range is about 3× finer and the phases are intact. The
  extended band is processed unwindowed (a window would taper away the extrapolated samples); SVA can
  be added on top. The grating-lobe limit follows the extended band's highest frequency.
- **Crossrange (per pixel, backprojection only):** once backprojection is focused on a pixel, the 55
  positions' contributions are close to a sum of exponentials: the scatterer at the pixel is at zero
  frequency and its neighbours are offset. A pencil on those 55 samples and amplitude-weighted lines
  keep only the power within a set fraction of a resolution cell (0.1) of zero frequency. Pixels below
  the colour scale and blanked angles are skipped. It takes about 10 s for the full warehouse image.
- **On synthetic point targets:** with ordinary processing, a pair 1.0 ft apart in range and a pair
  1.2 ft apart across range (at 100 ft) each look like one blob. With the pencil in range and
  crossrange they split, with dips of 14.6 dB and 5.4 dB.
- **On the warehouse scene,** mostly distributed clutter, the pencil gives sharper range and thinner
  scatterers but a busier, streakier image than Hann processing. Treat it as an experimental view.

**Range scaling:** the image is scaled by range^(3/2), the last step after autofocus, image formation
and SVA. By default it uses the true range from the aperture centre, √(x² + y²). MIT's script uses
downrange y, which under-scales wide crossranges, by 5 dB at (200, 100) ft; that's still available as
an option.

**Grating-lobe blanking (default on):** with positions dx apart, a scatterer at angle θ also appears at
sin θ ± λ/(2·dx). Angles beyond θmax, where sin θmax = λ/(4·dx) at f stop, are blanked to the colour scale's bottom (dark blue); inside
±θmax no scatterer that is also inside can alias. For 2-inch spacing at 2590 MHz, θmax is 34.8°.
1-inch spacing (λ/4) would allow about ±90°.

**Recording suggestion: 1-inch steps for the full field of view.** At 2590 MHz, λ/4 is 1.14 inches.
With 1-inch steps the aperture has no grating lobes at any angle, and the "1-inch spacing: full ±90°
field of view" option images the whole half-plane (crossrange out to the farthest downrange) with
nothing blanked. The same rail length takes twice as many positions.

In a simulation of a 9.2 ft rail with targets at broadside, 60° and 70°:

- **1-inch steps:** every target lands within 0.2 ft of its true position, and nothing else in the
  image comes within 13 dB of the peak (unweighted sidelobes only).
- **2-inch steps:** the 70° target also produces a false copy at (−45, 153) ft, only 11 dB down and
  *inside* the ±34.8° zone. Blanking can't remove an alias that lands there; only finer steps can.

Use this option only for recordings made with 1-inch steps: MIT's example uses 2-inch steps.

Tabs show the SAR image, the range profile at every position, and the wavenumber (K-space) data
after Stolt interpolation.

## Example data

The data aren't included in this repository. Download them from MIT OpenCourseWare:

MIT OCW RES.LL-003 (IAP 2011), Projects page, Experiment 3: `sar_files.zip`, containing
`towardswarehouse.wav` (44.1 kHz, 2 inches between positions, 2260–2590 MHz, Tp = 20 ms). The
default settings match this recording.

Checks against MIT's own files:

- **Parsed data (integer-sample alignment):** matches `routsidewarehouse2.mat` (55 × 441) to a relative error of about 1e-15.
- **Mean-subtracted data:** matches `sif.mat` to the same precision.
- **Image:** matches `final_image.jpg`, colour scale about −99 to −59 dB. To reproduce MIT exactly, use:
  integer-sample alignment, 0 up-chirps per position, MIT's running mean, autofocus off, and range
  migration.
- **Backprojection on synthetic point targets:** peaks land on the exact pixel, and the range
  migration image agrees to within 0.7 ft.
- **Backprojection on the warehouse data:** shows the same scatterers as MIT's image.

## Build and run

```
cd CoffeeCanSAR
xcodebuild -project CoffeeCanSAR.xcodeproj -target CoffeeCanSAR -configuration Release SYMROOT="$PWD/build" build
open build/Release/CoffeeCanSAR.app --args --open /path/to/towardswarehouse.wav
```

Command-line options:

- `--open <wav>` processes a file at launch.
- `--snapshot <png>` saves the window once processing finishes, then quits.
- `--dump <wav> <dir>` writes the parsed data as raw doubles, for comparison with MATLAB.
