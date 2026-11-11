import Accelerate
import AppKit
import SwiftUI

@main
struct CoffeeCanRadarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RadarModel()

    init() {
        CommandLineTools.handleArguments()
    }

    var body: some Scene {
        WindowGroup("Coffee Can Radar RTI") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1150, minHeight: 780)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless checks, run from Terminal:
///   CoffeeCanRadarRTI.app/Contents/MacOS/CoffeeCanRadarRTI --list-devices
///   CoffeeCanRadarRTI.app/Contents/MacOS/CoffeeCanRadarRTI --selftest
enum CommandLineTools {
    static func handleArguments() {
        let args = CommandLine.arguments
        if args.contains("--list-devices") {
            for d in AudioDevices.inputs() {
                print("\(d.id)\t\(d.name)\t\(d.inputChannels) ch\t\(d.sampleRate) Hz\(d.looksLikeUCA222 ? "\t<- UCA222" : "")")
            }
            exit(0)
        }
        if args.contains("--selftest") {
            exit(selfTest() ? 0 : 1)
        }
    }

    /// Runs the simulator through the processor and checks scaling, triggering and ranging.
    static func selfTest() -> Bool {
        var ok = true
        let fs = 48000.0

        // 1. Scaling: whole-sample square sync, sine of amplitude 0.5 centred on bin 400.
        do {
            var p = RadarParams()
            p.background = .none
            let proc = RadarProcessor()
            proc.update(params: p, fs: fs)
            let d = proc.d
            let f = 400 * fs / Double(d.nfft)
            let period = 2 * d.n
            var start = 0
            while start < Int(fs) * 2 {
                let n = 2048
                let l = (0..<n).map { k -> Float in (start + k) % period < d.n ? -0.5 : 0.5 }
                let r = (0..<n).map { k -> Float in
                    let ph = (start + k) % period
                    return -Float(0.5 * sin(2 * Double.pi * f * Double(ph) / fs))
                }
                proc.push(l, r)
                start += n
            }
            let s = proc.takeSnapshot()
            guard let t = s.traceDB else { print("FAIL scaling: no pulses"); return false }
            let kb = (1..<t.count).max { t[$0] < t[$1] }!
            let pass = kb == 400 && abs(Double(t[kb]) + 6.02) < 0.1
            ok = ok && pass
            print(String(format: "%@ scaling: peak bin %d (expect 400) at %.2f dBFS (expect -6.02), %d pulses",
                         pass ? "PASS" : "FAIL", kb, t[kb], s.pulseCount))
        }

        // 2. Simulator: triggering, interpolation and ranging.
        do {
            var p = RadarParams()
            p.background = .none
            p.traceAveraging = 1
            let proc = RadarProcessor()
            proc.update(params: p, fs: fs)
            var sim = SyncIFSimulator()
            var start = 0
            var last = ProcessorSnapshot(derived: proc.d, generation: 0, pulseCount: 0)
            while start < Int(fs) * 10 {
                let (l, r) = sim.generate(start: start, count: 2048, params: p)
                proc.push(l, r)
                start += 2048
                let s = proc.takeSnapshot()
                if s.pulseRateHz != nil { last = s }
            }
            let expectedRate = 1 / (2 * p.tpMs * 1e-3 * 1.000371)
            let rate = last.pulseRateHz ?? 0
            let ji = last.jitterIntegerUs ?? 0, jf = last.jitterInterpUs ?? 99
            let ratePass = abs(rate - expectedRate) < 0.01
            let jitterPass = jf < ji / 4 && jf < 1.0
            print(String(format: "%@ trigger: %d pulses, rate %.4f Hz (expect %.4f)", ratePass ? "PASS" : "FAIL",
                         last.pulseCount, rate, expectedRate))
            print(String(format: "%@ interpolation: period jitter %.2f µs integer -> %.3f µs interpolated (%d×)",
                         jitterPass ? "PASS" : "FAIL", ji, jf, p.interpolation))
            ok = ok && ratePass && jitterPass
            if let t = last.traceDB {
                let d = last.derived
                let k8 = Int((8 / d.metersPerBin).rounded())
                let kb = (Int(ceil(0.5 / d.metersPerBin))..<min(t.count, Int(15 / d.metersPerBin))).max { t[$0] < t[$1] }!
                let r = Double(kb) * d.metersPerBin
                let rangePass = abs(r - 8) < 0.3
                ok = ok && rangePass
                print(String(format: "%@ ranging: strongest return below 15 m at %.2f m (expect 8.00, bin %d) %.1f dB",
                             rangePass ? "PASS" : "FAIL", r, k8, t[kb]))
            }
        }

        // 3. Taylor window: peak sidelobe level should match the setting.
        do {
            let n = 960, log2m = 15, m = 1 << log2m
            let setup = vDSP_create_fftsetupD(vDSP_Length(log2m), FFTRadix(kFFTRadix2))!
            defer { vDSP_destroy_fftsetupD(setup) }
            for sll in [30.0, 40.0] {
                let w = taylorWindow(n: n, nbar: sll >= 40 ? 5 : 4, sidelobeDB: sll)
                var re = [Double](repeating: 0, count: m), im = re
                for k in 0..<n { re[k] = w[k] }
                fftInPlace(setup, &re, &im, log2n: log2m)
                let db = (0..<(m / 2)).map { 10 * log10(re[$0] * re[$0] + im[$0] * im[$0] + 1e-30) }
                var k = 1
                while k + 1 < db.count && db[k + 1] < db[k] { k += 1 }   // walk down the mainlobe to the first null
                let psl = (db[k...].max() ?? 0) - db[0]
                let pass = abs(psl + sll) < 0.7
                ok = ok && pass
                print(String(format: "%@ Taylor window: peak sidelobe %.2f dB (expect -%.0f)", pass ? "PASS" : "FAIL", psl, sll))
            }
        }

        // 3b. SVA: a strong and a 50 dB weaker tone. SVA should keep the rectangular mainlobe
        //     width, push sidelobes far down, and keep the weak tone at its true level.
        do {
            let n = 480, log2m = 11, m = 1 << log2m
            let ovs = Double(m) / Double(n)               // FFT bins per Nyquist bin
            let setup = vDSP_create_fftsetupD(vDSP_Length(log2m), FFTRadix(kFFTRadix2))!
            defer { vDSP_destroy_fftsetupD(setup) }
            let f1 = 60.3, f2 = 72.7, a2 = pow(10, -50.0 / 20)   // cycles per pulse
            func spectra(_ amp2: Double) -> (rect: [Double], sva: [Double]) {
                let x = (0..<n).map { t -> Double in
                    sin(2 * Double.pi * f1 * Double(t) / Double(n) + 0.4) + amp2 * sin(2 * Double.pi * f2 * Double(t) / Double(n) + 1.1)
                }
                var re = [Double](repeating: 0, count: m), im = re
                for t in 0..<n { re[t] = x[t] }
                fftInPlace(setup, &re, &im, log2n: log2m)
                let y = svaSpectrum(setup: setup, re: x, im: [Double](repeating: 0, count: n), n: n, log2n: log2m)
                let db = { (r: [Double], i: [Double]) in (0..<(m / 2)).map { 10 * log10(r[$0] * r[$0] + i[$0] * i[$0] + 1e-30) } }
                return (db(re, im), db(y.re, y.im))
            }
            func width3dB(_ db: [Double], _ k: Int) -> Double {
                var lo = k, hi = k
                while db[lo] > db[k] - 3 { lo -= 1 }
                while db[hi] > db[k] - 3 { hi += 1 }
                return Double(hi - lo) / ovs
            }
            let one = spectra(0)
            let k1 = Int((f1 * ovs).rounded())
            let pk = one.sva[(k1 - 3)...(k1 + 3)].max()!
            let far = (0..<(m / 2)).filter { abs(Double($0) - f1 * ovs) > 2.5 * ovs }
            let psl = far.map { one.sva[$0] }.max()! - pk
            let pslRect = far.map { one.rect[$0] }.max()! - one.rect[(k1 - 3)...(k1 + 3)].max()!
            let wRect = width3dB(one.rect, k1), wSVA = width3dB(one.sva, k1)
            let two = spectra(a2)
            let k2 = Int((f2 * ovs).rounded())
            let weak = two.sva[(k2 - 3)...(k2 + 3)].max()! - two.sva[(k1 - 3)...(k1 + 3)].max()!
            let pass = psl < -60 && wSVA < 1.1 * wRect && abs(weak + 50) < 1.5
            ok = ok && pass
            print(String(format: "%@ SVA: sidelobes %.1f dB (rect %.1f), -3 dB width %.2f bins (rect %.2f), weak tone %.1f dB (expect -50)",
                         pass ? "PASS" : "FAIL", psl, pslRect, wSVA, wRect, weak))
        }

        // 4. Range PGA: a target smeared by a known sweep phase error.
        do {
            func run(pga: Bool) -> (peak: Double, phase: [Float]?, n: Int) {
                var p = RadarParams()
                p.background = .none
                p.pgaEnabled = pga
                p.pgaPulses = 32
                let proc = RadarProcessor()
                proc.update(params: p, fs: fs)
                let n = proc.d.n, period = 2 * n
                let f = 3000.0
                var start = 0, last: ProcessorSnapshot?
                while start < Int(fs) * 4 {
                    let count = 2048
                    let l = (0..<count).map { k -> Float in (start + k) % period < n ? -0.5 : 0.5 }
                    let r = (0..<count).map { k -> Float in
                        let ph = (start + k) % period
                        guard ph < n else { return 0 }
                        let u = Double(ph) / Double(n) - 0.5
                        let err = 10 * u * u + 6 * u * u * u      // sweep phase error (rad)
                        return -Float(0.5 * sin(2 * Double.pi * f * Double(ph) / fs + err))
                    }
                    proc.push(l, r)
                    start += count
                    last = proc.takeSnapshot()
                }
                let t = last?.traceDB ?? []
                let first = Int(ceil(1 / proc.d.metersPerBin))
                return (Double(t[first...].max() ?? -200), last?.pgaPhase, n)
            }
            let off = run(pga: false), on = run(pga: true)
            var truth = (0..<on.n).map { k -> Double in
                let u = (Double(k) - 0.5) / Double(on.n) - 0.5      // pulse starts ~half a sample early
                return 10 * u * u + 6 * u * u * u
            }
            removeLinearTrend(&truth)
            let est = on.phase.map { $0.map(Double.init) } ?? []
            let err = est.count == truth.count ? rms(zip(est, truth).map { $0 - $1 }) : 99
            let gainPass = on.peak - off.peak > 2
            let phasePass = err < 0.15
            ok = ok && gainPass && phasePass
            print(String(format: "%@ PGA: peak %.2f dBFS without -> %.2f dBFS with PGA (+%.2f dB; ideal -6.02)",
                         gainPass ? "PASS" : "FAIL", off.peak, on.peak, on.peak - off.peak))
            print(String(format: "%@ PGA: phase estimate error %.3f rad rms (true error %.2f rad rms)",
                         phasePass ? "PASS" : "FAIL", err, rms(truth)))
        }
        print(ok ? "ALL PASS" : "SOME CHECKS FAILED")
        return ok
    }
}

/// `--snapshot <file.png>`: after 6 s, render the window contents to a PNG and quit
/// (used with `--simulate` to check the UI without screen-recording access).
enum SnapshotTool {
    static func scheduleIfRequested(model: RadarModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                let view = ContentView().environmentObject(model).frame(width: 1400, height: 900)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                if let tiff = renderer.nsImage?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                }
                exit(0)
            }
        }
    }
}
