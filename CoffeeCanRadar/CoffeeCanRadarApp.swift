import AVFoundation
import Accelerate
import AppKit
import SwiftUI

@main
struct CoffeeCanRadarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RadarModel()
    @StateObject private var sarModel = SARModel()

    init() {
        CommandLineTools.handleArguments()
        SARDumpTool.runIfRequested()
    }

    var body: some Scene {
        WindowGroup(AboutInfo.appName) {
            ContentView()
                .environmentObject(model)
                .environmentObject(sarModel)
                .frame(minWidth: 1150, minHeight: 780)
                .onAppear { SnapshotTool.scheduleIfRequested(model: model, sar: sarModel) }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AboutInfo.appName)") { AboutInfo.showPanel(appName: AboutInfo.appName) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless checks, run from Terminal:
///   "Coffee Can RTI DTI SAR Imaging.app/Contents/MacOS/Coffee Can RTI DTI SAR Imaging" --list-devices
///   "Coffee Can RTI DTI SAR Imaging.app/Contents/MacOS/Coffee Can RTI DTI SAR Imaging" --selftest
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
        if let i = args.firstIndex(of: "--doppler-dump"), i + 2 < args.count {
            exit(dopplerDump(wav: args[i + 1], out: args[i + 2]) ? 0 : 1)
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

        // 3c. Matrix pencil: two equal targets half a range-resolution cell apart (the FFT
        //     cannot separate them) plus a third 20 dB weaker, in light noise, on a real pulse.
        do {
            let n = 480
            var p = RadarParams(); p.tpMs = 10
            let d = Derived(p, fs: 48000)
            let cells = [60.0, 60.5, 75.2], amps = [0.5, 0.5, 0.05]   // cycles per pulse
            var rng = SystemRandomNumberGenerator()
            let x = (0..<n).map { t -> Double in
                var v = 0.0
                for (f, a) in zip(cells, amps) { v += a * sin(2 * Double.pi * f * Double(t) / Double(n) + f) }
                return v + 1e-4 * Double.random(in: -1...1, using: &rng)
            }
            let mp = MatrixPencil(n: n, pencil: n / 3)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = mp.analyze(re: x, im: [Double](repeating: 0, count: n), maxOrder: 16, thresholdDB: 40)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            var found: [(f: Double, db: Double)] = []
            if let r { for k in 0..<r.order where r.poles[k].arg > 0 { found.append((r.poles[k].arg / (2 * .pi) * Double(n), 10 * log10(4 * r.power[k]))) } }
            found.sort { $0.f < $1.f }
            var pass = found.count == 3
            if pass {
                for (i, f) in found.enumerated() {
                    pass = pass && abs(f.f - cells[i]) < 0.02 && abs(f.db - 20 * log10(amps[i])) < 0.5
                }
            }
            if let r {
                let om = (0..<1024).map { 2 * Double.pi * Double($0) / Double(d.nfft) }
                let s2 = MatrixPencil.sigmaMin2(schur: r.schur, order: r.order, omegas: om)
                let kA = Int((60.0 / Double(n) * Double(d.nfft)).rounded()), kB = Int((60.5 / Double(n) * Double(d.nfft)).rounded())
                let dip = s2[(kA + kB) / 2] > 10 * max(s2[kA], s2[kB])    // resolved: valley between the peaks
                pass = pass && dip
            }
            let re = mp.analyze(re: x, im: [Double](repeating: 0, count: n), maxOrder: 16, thresholdDB: 40, rule: .ester, pairs: true)
            let rg = mp.analyze(re: x, im: [Double](repeating: 0, count: n), maxOrder: 16, thresholdDB: 40, rule: .gap, pairs: true)
            let rf = mp.analyze(re: x, im: [Double](repeating: 0, count: n), maxOrder: 16, thresholdDB: 40, rule: .ester, pairs: true, forwardBackward: true)
            var fbFound: [Double] = []
            if let rf { for k in 0..<rf.order where rf.poles[k].arg > 0 { fbFound.append(rf.poles[k].arg / (2 * .pi) * Double(n)) } }
            fbFound.sort()
            let fbPass = rf?.order == 6 && fbFound.count == 3 && zip(fbFound, cells).allSatisfy { abs($0 - $1) < 0.02 }
            print(String(format: "%@ forward-backward pencil: order %d, %@ cells", fbPass ? "PASS" : "FAIL", rf?.order ?? 0,
                         fbFound.map { String(format: "%.3f", $0) }.joined(separator: "/")))
            ok = ok && fbPass
            let orderPass = re?.order == 6 && rg?.order == 6
            print(String(format: "%@ adaptive model order: ESTER %d, gap %d (expect 6 = 3 targets)", orderPass ? "PASS" : "FAIL", re?.order ?? 0, rg?.order ?? 0))
            ok = ok && pass && orderPass
            print(String(format: "%@ matrix pencil: %@ (expect 60.00/60.50/75.20 cells at -6.0/-6.0/-26.0 dBFS), order %d, %.1f ms",
                         pass ? "PASS" : "FAIL", found.map { String(format: "%.3f@%.1f", $0.f, $0.db) }.joined(separator: " "), r?.order ?? 0, ms))
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
        // 6. Slow-time (Doppler) PGA: three scatterers (two moving, one stationary) share a smooth
        //    phase error plus pulse-to-pulse jitter; the estimate should match it and the
        //    moving target should keep its Doppler cell.
        do {
            let m = 64, nr = 20, log2m = 6
            let setup = vDSP_create_fftsetupD(vDSP_Length(log2m), FFTRadix(kFFTRadix2))!
            defer { vDSP_destroy_fftsetupD(setup) }
            var rng = SystemRandomNumberGenerator()
            var truth = (0..<m).map { j -> Double in
                let t = Double(j) / Double(m)
                return 1.5 * sin(2 * .pi * 1.3 * t + 0.4) + 0.8 * cos(2 * .pi * 3.1 * t) + 0.2 * Double.random(in: -1...1, using: &rng)
            }
            removeLinearTrend(&truth)
            let targets: [(bin: Int, q: Double, a: Double)] = [(5, 7.0, 1), (12, -3.0, 0.5), (15, 0, 0.7)]
            var re = [Double](repeating: 0, count: m * nr), im = re
            for kb in 0..<nr {
                for j in 0..<m {
                    var vr = 0.01 * Double.random(in: -1...1, using: &rng), vi = 0.01 * Double.random(in: -1...1, using: &rng)
                    for t in targets where t.bin == kb {
                        let ph = 2 * .pi * t.q * Double(j) / Double(m) + truth[j] + Double(kb)
                        vr += t.a * cos(ph); vi += t.a * sin(ph)
                    }
                    re[kb * m + j] = vr; im[kb * m + j] = vi
                }
            }
            func peakFraction(_ re: [Double], _ im: [Double], bin: Int) -> (frac: Double, q: Int) {
                var r = Array(re[(bin * m)..<(bin * m + m)]), i = Array(im[(bin * m)..<(bin * m + m)])
                fftInPlace(setup, &r, &i, log2n: log2m)
                let p = zip(r, i).map { $0 * $0 + $1 * $1 }
                let k = p.indices.max { p[$0] < p[$1] }!
                return (p[k] / p.reduce(0, +), k)
            }
            let before = peakFraction(re, im, bin: 5)
            var est = RadarProcessor.slowTimePGA(setup: setup, re: &re, im: &im, m: m, log2m: log2m, bins: 1..<nr, iterations: 8)
            removeLinearTrend(&est)
            let after = peakFraction(re, im, bin: 5)
            let err = rms(zip(est, truth).map { $0 - $1 })
            let pass = err < 0.1 * rms(truth) && after.frac > 0.9 && after.q == 7
            ok = ok && pass
            print(String(format: "%@ Doppler PGA: phase error %.3f rad rms (true %.2f); target peak %.0f%% -> %.0f%% of its energy, Doppler cell %d (expect 7)",
                         pass ? "PASS" : "FAIL", err, rms(truth), before.frac * 100, after.frac * 100, after.q))
        }

        // 7. Range-Doppler matrix pencil in Doppler: two targets in one range bin, half a Doppler FFT
        //    cell apart (the FFT shows one blob), must give two peaks at the right velocities.
        do {
            var p = RadarParams(); p.tpMs = 5; p.rdDopplerPGA = false; p.rdSuperRes = .doppler
            p.dbTop = 0; p.rdDbRange = 60
            let m = 64, nr = 8, kb = 3
            let qs = [10.0, 10.5], amps = [0.5, 0.5]
            var inp = RangeDopplerInput(m: m, log2m: 6, nr: nr, n: 240, nfft: 1024, metersPerBin: 0.1,
                                        params: p, analytic: true, generation: 0)
            inp.bre = [Double](repeating: 0, count: m * nr); inp.bim = inp.bre
            var rng = SystemRandomNumberGenerator()
            for j in 0..<m {
                for b in 0..<nr { inp.bre[b * m + j] = 1e-4 * Double.random(in: -1...1, using: &rng); inp.bim[b * m + j] = 1e-4 * Double.random(in: -1...1, using: &rng) }
                for (q, a) in zip(qs, amps) {
                    let ph = 2 * Double.pi * q * Double(j) / Double(m) + q
                    inp.bre[kb * m + j] += a * cos(ph); inp.bim[kb * m + j] += a * sin(ph)
                }
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let snap = RangeDopplerBuilder.compute(inp)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            var peaks: [Double] = []
            if let s = snap {
                let rows = s.rows, u = rows / m
                let col = (0..<rows).map { s.db[$0 * nr + kb] }
                for r in 1..<(rows - 1) where col[r] > col[r - 1] && col[r] >= col[r + 1] && col[r] > col.max()! - 10 {
                    peaks.append(Double(r - rows / 2) / Double(u))   // slow-time frequency in FFT cells
                }
            }
            peaks.sort()
            let order = snap?.dopplerOrder ?? 0
            let pass = peaks.count == 2 && abs(peaks[0] - qs[0]) <= 0.15 && abs(peaks[1] - qs[1]) <= 0.15 && order == 2
            ok = ok && pass
            print(String(format: "%@ range-Doppler pencil: Doppler peaks at %@ cells (expect 10.00 and 10.50), ESTER order %.0f (expect 2), %.1f ms",
                         pass ? "PASS" : "FAIL", peaks.map { String(format: "%.2f", $0) }.joined(separator: ", "), order, ms))
        }

        ok = dopplerSelfTest() && ok
        print(ok ? "ALL PASS" : "SOME CHECKS FAILED")
        return ok
    }

    /// Doppler vs. time (CW): velocity scale and level, SVA sidelobes, matrix pencil resolution, PGA.
    static func dopplerSelfTest() -> Bool {
        var ok = true
        let fs = 44100.0
        var p = RadarParams()
        func run(_ p: RadarParams, _ sig: (Double) -> Double) -> (row: DTRow, g: DTGeometry) {
            let s = DTSettings(p), g = DTGeometry(s, fs: fs)
            var rng = SystemRandomNumberGenerator()
            var x = (0..<g.n).map { sig(Double($0) / fs) + 1e-4 * Double.random(in: -1...1, using: &rng) }
            let mean = x.reduce(0, +) / Double(x.count)
            for i in x.indices { x[i] -= mean }
            return (DopplerTimeDSP().process(x, s: s, g: g), g)
        }
        let lam = speedOfLight / (p.dtCarrierMHz * 1e6)
        func tone(_ v: Double, _ a: Double = 0.1) -> (Double) -> Double { { t in a * cos(2 * .pi * 2 * v / lam * t + 0.3) } }
        let cell = lam / (2 * p.dtDwellMs / 1000)     // velocity resolution

        // 1. FFT: a 15 m/s tone of amplitude 0.1 at 15 m/s and -20 dB
        let (r1, g1) = run(p, tone(15))
        let pk = dtPeak(r1.db, mpsPerCol: g1.mpsPerCol, minVelocity: 1)
        let pass1 = pk.map { abs($0.velocity - 15) < 0.02 && abs($0.db + 20) < 0.3 } ?? false
        print(String(format: "%@ Doppler-time FFT: peak %.3f m/s at %.2f dB (expect 15.000, -20.00), %d bins of %.4f m/s, N = %d",
                     pass1 ? "PASS" : "FAIL", pk?.velocity ?? 0, pk?.db ?? 0, g1.cols, g1.mpsPerCol, g1.n))
        ok = ok && pass1

        // 2. SVA: sidelobes beyond 2 resolution cells
        func sidelobe(_ r: DTRow, _ g: DTGeometry) -> Double {
            let peak = r.db.max()!
            let far = r.db.indices.filter { abs(Double($0) * g.mpsPerCol - 15) > 2 * cell && Double($0) * g.mpsPerCol > 1 }
            return Double(far.map { r.db[$0] }.max()! - peak)
        }
        var ps = p; ps.dtSVA = true
        let rect = sidelobe(r1, g1), (r2, g2) = run(ps, tone(15)), sva = sidelobe(r2, g2)
        let pk2 = dtPeak(r2.db, mpsPerCol: g2.mpsPerCol, minVelocity: 1)
        let pass2 = sva < -30 && rect > -20 && abs((pk2?.db ?? 0) + 20) < 0.3
        print(String(format: "%@ Doppler-time SVA: sidelobes beyond 2 cells %.1f dB (rectangular %.1f dB), peak %.2f dB",
                     pass2 ? "PASS" : "FAIL", sva, rect, pk2?.db ?? 0))
        ok = ok && pass2

        // 3. Matrix pencil: two movers 0.5 resolution cells apart
        var pm = p; pm.dtMethod = .matrixPencil
        let v1 = 15.0, v2 = 15 + 0.5 * cell
        let two: (Double) -> Double = { t in tone(v1)(t) + 0.1 * cos(2 * .pi * 2 * v2 / lam * t + 1.9) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (r3, _) = run(pm, two)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let found = r3.lines.filter { $0.db > -30 }.map(\.velocity).sorted()
        let pass3 = found.count == 2 && abs(found[0] - v1) < 0.02 && abs(found[1] - v2) < 0.02
        print(String(format: "%@ Doppler-time matrix pencil: %@ m/s (expect %.3f and %.3f, 0.5 cell apart), order %d, %.1f ms",
                     pass3 ? "PASS" : "FAIL", found.map { String(format: "%.3f", $0) }.joined(separator: ", "), v1, v2, r3.order ?? 0, ms))
        ok = ok && pass3

        // 4. PGA: a mover accelerating at 8 m/s^2 (smeared over ~9 cells) is refocused at its mean speed
        let acc = 8.0, tp = p.dtDwellMs / 1000
        let accel: (Double) -> Double = { t in 0.1 * cos(2 * .pi * 2 / lam * (15 * t + 0.5 * acc * (t - tp / 2) * (t - tp / 2)) + 0.3) }
        let (r4, g4) = run(p, accel)
        p.dtPGA = true
        let (r5, g5) = run(p, accel)
        let off = dtPeak(r4.db, mpsPerCol: g4.mpsPerCol, minVelocity: 1), on = dtPeak(r5.db, mpsPerCol: g5.mpsPerCol, minVelocity: 1)
        let pass4 = r5.pga == true && (on?.db ?? -99) > -21 && (on?.db ?? -99) - (off?.db ?? 0) > 5 && abs((on?.velocity ?? 0) - 15) < 0.05
        print(String(format: "%@ Doppler-time PGA: accelerating mover %.2f dB at %.2f m/s without, %.2f dB at %.3f m/s with PGA (expect -20, 15.000)",
                     pass4 ? "PASS" : "FAIL", off?.db ?? 0, off?.velocity ?? 0, on?.db ?? 0, on?.velocity ?? 0))
        ok = ok && pass4

        // 5. Live path: 3 s of a 22 m/s tone on the right input, in 1024-sample blocks at 48 kHz
        do {
            let eng = DopplerTimeEngine()
            var snap: DTSnapshot?
            eng.onSnapshot = { snap = $0 }
            eng.request(RadarParams()); eng.applyPending()
            eng.startLive(fs: 48000)
            var start = 0
            while start < 3 * 48000 {
                let r = (0..<1024).map { k in Float(0.2 * cos(2 * .pi * 2 * 22 / lam * Double(start + k) / 48000)) }
                eng.push([Float](repeating: 0, count: 1024), r)
                start += 1024
            }
            let rows = snap?.rows.count ?? 0
            let v = snap.flatMap { s in s.rows.last.flatMap { dtPeak($0, mpsPerCol: s.mpsPerCol, minVelocity: 1) } }
            let pass5 = rows == 12 && abs((v?.velocity ?? 0) - 22) < 0.02
            print(String(format: "%@ Doppler-time live: %d dwells from 3 s (expect 12), newest peak %.3f m/s (expect 22.000)",
                         pass5 ? "PASS" : "FAIL", rows, v?.velocity ?? 0))
            ok = ok && pass5
        }
        return ok
    }

    /// `--doppler-dump <wav> <out.f32>`: Doppler vs. time of a recording with the saved settings
    /// (MIT defaults), written as float32 rows of dB relative to the strongest cell.
    static func dopplerDump(wav: String, out: String) -> Bool {
        let model = RadarModel.loadParamsForTools()
        var p = model
        let env = ProcessInfo.processInfo.environment
        if env["DT_DEFAULTS"] != nil { p = RadarParams() }
        if env["DT_MP"] != nil { p.dtMethod = .matrixPencil }
        if env["DT_SVA"] != nil { p.dtSVA = true }
        if env["DT_PGA"] != nil { p.dtPGA = true }
        if let z = env["DT_ZPAD"].flatMap(Int.init) { p.dtZeroPad = z }
        if let r = env["DT_RULE"] { p.dtOrderRule = r == "gap" ? .gap : r == "threshold" ? .threshold : .ester }
        if let t = env["DT_ESTER"].flatMap(Double.init) { p.esterThreshold = t }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: wav)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { print("can't read \(wav)"); return false }
        let n = Int(buf.frameLength)
        let left = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let right = buf.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : []
        let eng = DopplerTimeEngine()
        var snap: DTSnapshot?
        eng.onSnapshot = { snap = $0 }
        eng.request(p)
        eng.applyPending()
        let t0 = DispatchTime.now().uptimeNanoseconds
        eng.loadFile(name: wav, left: left, right: right, fs: file.processingFormat.sampleRate)
        let secs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        guard let s = snap else { return false }
        var data = Data()
        for r in s.rows { for v in r { var x = v - s.maxDB; data.append(Data(bytes: &x, count: 4)) } }
        try? data.write(to: URL(fileURLWithPath: out))
        let peaks = s.rows.prefix(10).map { dtPeak($0, mpsPerCol: s.mpsPerCol, minVelocity: 0).map { String(format: "%.3f", $0.velocity) } ?? "-" }
        print(String(format: "%d rows x %d cols, %.5f m/s per col, max %.2f dB, %.2f s total (%.2f ms/dwell avg), order %@, PGA %d/%d",
                     s.rows.count, s.cols, s.mpsPerCol, s.maxDB, secs, s.msPerDwell ?? 0, s.medianOrder.map { String(format: "%.0f", $0) } ?? "-", s.pgaApplied, s.pgaTried))
        print("peak velocity, first rows: " + peaks.joined(separator: " "))
        if p.dtMethod == .matrixPencil {
            var hist: [Int: Int] = [:]
            for l in s.lines { hist[l.count, default: 0] += 1 }
            print("poles in band per dwell: " + hist.keys.sorted().map { "\($0):\(hist[$0]!)" }.joined(separator: " "))
        }
        return true
    }
}

/// `--snapshot <file.png>`: after 6 s, render the window contents to a PNG and quit
/// (used with `--simulate` to check the UI without screen-recording access).
enum SnapshotTool {
    static func scheduleIfRequested(model: RadarModel, sar: SARModel) {
        let args = CommandLine.arguments
        // with --open-sar, the SAR model takes the snapshot once its image is formed
        guard !args.contains("--open-sar"), let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                // --snapshot-how renders the "How it works" diagram alone (ImageRenderer can't draw scroll views)
                let how = args.contains("--snapshot-how")
                let view = Group {
                    if how { HowItWorksRTIContent().padding(16).frame(width: 1100).background(Color.white) }
                    else { ContentView().frame(width: 1400, height: 900) }
                }.environmentObject(model).environmentObject(sar)
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
