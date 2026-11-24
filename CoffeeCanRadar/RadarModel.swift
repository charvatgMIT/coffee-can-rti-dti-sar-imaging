import AVFoundation
import AppKit
import UniformTypeIdentifiers
import CoreAudio
import CoreGraphics
import Foundation
import SwiftUI

struct LiveStats {
    var pulseRateHz: Double?
    var periodMs: Double?
    var jitterIntegerUs: Double?
    var jitterInterpUs: Double?
    var levelL: Float = 0
    var levelR: Float = 0
    var peakRange: Double?
    var peakDB: Double?
}

enum SourceKind { case none, live, simulation }

/// Which processing chain gets the live audio. Only one runs at a time, to save compute.
enum ProcessingMode: String { case rti = "RTI", dti = "Doppler vs. time", sar = "SAR" }

/// Thread-safe switch read by the audio thread. When a chain is switched back on, its first block
/// asks it to start over (its history would otherwise jump across the time it was off).
final class ModeGate {
    private let lock = NSLock()
    private var mode: ProcessingMode = .rti
    private var restartRTI = false, restartDTI = false

    func set(_ m: ProcessingMode) {
        lock.lock(); defer { lock.unlock() }
        guard m != mode else { return }
        mode = m
        restartRTI = true; restartDTI = true
    }

    /// (this chain is on, it must start over first)
    func take(_ m: ProcessingMode) -> (on: Bool, restart: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard mode == m else { return (false, false) }
        if m == .rti { defer { restartRTI = false }; return (true, restartRTI) }
        defer { restartDTI = false }; return (true, restartDTI)
    }
}

/// A setting change the app recommends after looking at the incoming signals.
enum Suggestion: Equatable {
    case swapChannels(toRight: Bool)
    case setTp(Double)

    var message: String {
        switch self {
        case .swapChannels(let toRight):
            return toRight
                ? "The sync square wave appears to be on the RIGHT input and the IF on the LEFT."
                : "The sync square wave appears to be on the LEFT input and the IF on the RIGHT."
        case .setTp(let tp):
            return String(format: "The sync period is %.2f ms, so each up-chirp (sync high) lasts about %.2f ms.", 2 * tp, tp)
        }
    }

    var action: String {
        switch self {
        case .swapChannels(let toRight): return toRight ? "Use right input for sync" : "Use left input for sync"
        case .setTp(let tp): return String(format: "Set Tp to %.2f ms", tp)
        }
    }
}

/// Main-thread state for the UI. DSP runs on `queue`; snapshots come back ~30 times a second.
final class RadarModel: ObservableObject {
    @Published var params = RadarModel.loadParams() { didSet { paramsChanged(from: oldValue) } }
    @Published private(set) var suggestion: Suggestion?
    @Published var devices: [AudioDeviceInfo] = []
    @Published var selectedDeviceID: AudioDeviceID = 0 { didSet { if selectedDeviceID != oldValue { userPicked = true } } }
    @Published var paused = false { didSet { let p = paused, proc = processor; queue.async { proc.paused = p } } }
    @Published private(set) var source: SourceKind = .none
    @Published private(set) var status = "Idle. Press Start to read the UCA222."
    @Published private(set) var statusIsError = false
    @Published private(set) var derived = Derived(RadarParams(), fs: 48000)
    @Published private(set) var trace: [Float]?
    @Published private(set) var hold: [Float]?
    @Published private(set) var scope: ScopeSnapshot?
    @Published private(set) var edge: EdgeSnapshot?
    @Published private(set) var stats = LiveStats()
    @Published private(set) var pulseCount = 0
    @Published private(set) var rtiImage: CGImage?
    @Published private(set) var pgaPhase: [Float]?
    @Published private(set) var pgaUpdates = 0
    @Published private(set) var pgaAccepted = 0
    @Published private(set) var pgaAgreement: Double?
    @Published private(set) var pencilTargets: [(range: Double, db: Double)] = []
    @Published private(set) var pencilOrder: Int?
    @Published private(set) var pencilMs: Double?
    @Published private(set) var rangeDoppler: RangeDopplerSnapshot?
    @Published private(set) var rdCollected = 0
    @Published private(set) var dt: DTSnapshot?
    @Published private(set) var dtBusy = false
    @Published var dtSelectedRow: Int?          // recording: the dwell whose spectrum is shown (nil = last)
    @Published private(set) var processingMode: ProcessingMode = .rti
    private let gate = ModeGate()

    let rti = RTIBuffer()
    private let queue = DispatchQueue(label: "org.coffeecanradar.CoffeeCanRadar.dsp", qos: .userInteractive)
    private let processor = RadarProcessor()
    private let input = AudioInput()
    private var simulator: SimulatedSource?
    private var timer: Timer?
    private var fs: Double = 48000
    private var generation = -1
    private var userPicked = false
    private let backlog = AudioBacklog()
    private let dtQueue = DispatchQueue(label: "org.coffeecanradar.CoffeeCanRadar.doppler", qos: .userInitiated)
    private let dtEngine = DopplerTimeEngine()
    private let dtBacklog = AudioBacklog()

    init() {
        derived = Derived(params, fs: fs)
        let p = params, f = fs, proc = processor
        queue.async { proc.update(params: p, fs: f) }
        dtEngine.onSnapshot = { [weak self] snap in
            DispatchQueue.main.async {
                guard let self else { return }
                if let sel = self.dtSelectedRow, sel >= snap.rows.count { self.dtSelectedRow = nil }
                self.dt = snap
                self.dtBusy = false
            }
        }
        requestDopplerUpdate()
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
        if CommandLine.arguments.contains("--simulate") {
            DispatchQueue.main.async { self.startSimulation() }
        }
        if CommandLine.arguments.contains("--live") {
            DispatchQueue.main.async { self.startLive() }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--open-doppler"), i + 1 < CommandLine.arguments.count {
            UserDefaults.standard.set(3, forKey: "mainTab")
            openDopplerRecording(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }

    // MARK: devices

    func refreshDevices() {
        devices = AudioDevices.inputs()
        let keep = userPicked && devices.contains { $0.id == selectedDeviceID }
        if !keep, let uca = devices.first(where: { $0.looksLikeUCA222 }) {
            selectedDeviceID = uca.id
            userPicked = false
        } else if !devices.contains(where: { $0.id == selectedDeviceID }), let first = devices.first {
            selectedDeviceID = first.id
            userPicked = false
        }
    }

    // MARK: sources

    func startLive() {
        stop()
        refreshDevices()
        guard let dev = devices.first(where: { $0.id == selectedDeviceID }) else {
            setStatus("No audio input selected. Is the UCA222 plugged in?", error: true)
            return
        }
        requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.setStatus("Microphone access is off. Allow Coffee Can Radar in System Settings → Privacy & Security → Microphone.", error: true)
                return
            }
            do {
                try self.input.prepare(deviceID: dev.id)
                self.begin(fs: self.input.sampleRate)
                let proc = self.processor, q = self.queue, backlog = self.backlog
                backlog.reset()
                let dtEng = self.dtEngine, dq = self.dtQueue, dtBacklog = self.dtBacklog, fs = self.input.sampleRate
                dtBacklog.reset()
                dq.async { dtEng.startLive(fs: fs) }
                let dtLimit = Int(fs * 2)
                // At most 0.5 s of audio may wait for processing; beyond that blocks are dropped so
                // the display can never lag further behind real time.
                let limit = Int(self.input.sampleRate / 2)
                let gate = self.gate
                self.input.onSamples = { l, r in
                    let n = l.count
                    // only the chain for the selected tab gets the audio
                    let rti = gate.take(.rti)
                    if rti.on, let resync = backlog.tryAdd(n, limit: limit) {
                        q.async {
                            if rti.restart { proc.restart() } else if resync { proc.discontinuity() }
                            proc.push(l, r)
                            backlog.remove(n)
                        }
                    }
                    // Doppler vs. time (CW) runs on its own queue
                    let dti = gate.take(.dti)
                    if dti.on, let dtResync = dtBacklog.tryAdd(n, limit: dtLimit) {
                        dq.async {
                            if dti.restart { dtEng.startLive(fs: fs) } else if dtResync { dtEng.discontinuity() }
                            dtEng.push(l, r)
                            dtBacklog.remove(n)
                        }
                    }
                }
                try self.input.start()
                self.source = .live
                if self.input.deviceChannels < 2 {
                    self.setStatus("\(dev.name) is delivering only \(self.input.deviceChannels) channel. Trigger and IF need stereo.", error: true)
                } else {
                    self.setStatus("Live: \(dev.name), \(Int(self.input.sampleRate)) Hz, \(self.input.deviceChannels) ch.")
                }
            } catch {
                self.input.stop()
                self.setStatus("Audio start failed: \(error.localizedDescription)", error: true)
            }
        }
    }

    func startSimulation() {
        stop()
        let sim = SimulatedSource(params: params)
        begin(fs: 48000)
        let proc = processor
        let gate = self.gate
        sim.onSamples = { l, r in                     // already on `queue`
            let rti = gate.take(.rti)
            guard rti.on else { return }
            if rti.restart { proc.restart() }
            proc.push(l, r)
        }
        sim.start(queue: queue)
        simulator = sim
        source = .simulation
        setStatus("Simulation: targets at 8 m (fixed), 13–37 m (moving) and 60 m. The sync period is not a whole number of samples.")
    }

    func stop() {
        input.onSamples = nil
        input.stop()
        simulator?.stop()
        simulator = nil
        if source != .none { setStatus("Stopped.") }
        source = .none
        paused = false
    }

    private func begin(fs newFs: Double) {
        fs = newFs
        derived = Derived(params, fs: newFs)
        let p = params, proc = processor
        queue.async { proc.update(params: p, fs: newFs); proc.restart() }
        paused = false
        stats = LiveStats()
        suggestion = nil
        droppedSeconds = 0
    }

    private func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    private func setStatus(_ s: String, error: Bool = false) {
        status = s
        statusIsError = error
    }

    // MARK: settings

    private static let paramsKey = "RadarParams"

    static func loadParamsForTools() -> RadarParams { loadParams() }

    private static func loadParams() -> RadarParams {
        // Merge the saved settings over the defaults so settings added in later versions still load.
        guard let data = UserDefaults.standard.data(forKey: paramsKey),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(RadarParams()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return RadarParams()
        }
        merged.merge(saved) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              var p = try? JSONDecoder().decode(RadarParams.self, from: mergedData) else { return RadarParams() }
        if saved["band"] == nil { p.band = Band.allCases.first { $0.matches(p) } ?? .custom }
        return p
    }

    func applySuggestion() {
        switch suggestion {
        case .swapChannels(let toRight): params.syncOnRight = toRight
        case .setTp(let tp): params.tpMs = tp
        case nil: break
        }
        suggestion = nil
        stats = LiveStats()
    }

    func resetSettings() {
        params = RadarParams()
    }

    private func paramsChanged(from old: RadarParams) {
        guard params != old else { return }
        // Keep the band picker and f start / f stop consistent.
        if params.band != old.band, let r = params.band.range {
            params.fStartMHz = r.start
            params.fStopMHz = r.stop
        } else if params.band != .custom && !params.band.matches(params) {
            params.band = .custom
        }
        if let data = try? JSONEncoder().encode(params) {
            UserDefaults.standard.set(data, forKey: RadarModel.paramsKey)
        }
        if params.syncOnRight != old.syncOnRight || params.tpMs != old.tpMs {
            stats = LiveStats()
            suggestion = nil
        }
        derived = Derived(params, fs: fs)
        let p = params, f = fs, proc = processor
        queue.async { proc.update(params: p, fs: f) }
        requestDopplerUpdate()
        if params.rtiSeconds != old.rtiSeconds {
            resetRTI(width: rti.width)
        } else if params.rtiViewSeconds != old.rtiViewSeconds {
            rti.setView(pulses: rtiViewPulses, top: params.dbTop, range: params.rtiDbRange)
            rtiImage = rti.makeImage()
        } else if params.dbTop != old.dbTop || params.rtiDbRange != old.rtiDbRange {
            rti.recolor(top: params.dbTop, range: params.rtiDbRange)
            rtiImage = rti.makeImage()
        }
    }

    /// Pulses in the RTI history: the sync period is 2*Tp (high = up-chirp, low = down-chirp).
    private var rtiPulses: Int {
        Int((params.rtiSeconds * 1000 / (2 * params.tpMs)).rounded())
    }

    /// The waterfall time span shown, in seconds.
    var rtiViewSecondsShown: Double {
        params.rtiViewSeconds > 0 ? min(params.rtiViewSeconds, params.rtiSeconds) : params.rtiSeconds
    }

    /// Pulses in the displayed part of the waterfall (the time-span slider).
    private var rtiViewPulses: Int {
        let secs = params.rtiViewSeconds > 0 ? min(params.rtiViewSeconds, params.rtiSeconds) : params.rtiSeconds
        return Int((secs * 1000 / (2 * params.tpMs)).rounded())
    }

    /// The waterfall plot's height in screen pixels: rebuilds the image with at most that many rows.
    func setRTIPixelHeight(_ px: Int) {
        let rows = max(40, min(2000, px))
        guard rows != rti.maxRows else { return }
        rti.maxRows = rows
        guard rti.width > 0 else { return }
        rti.setView(pulses: rtiViewPulses, top: params.dbTop, range: params.rtiDbRange)
        rtiImage = rti.makeImage()
    }

    private func resetRTI(width: Int) {
        rti.reset(width: width, pulses: rtiPulses, viewPulses: rtiViewPulses, top: params.dbTop, range: params.rtiDbRange)
        rtiImage = rti.makeImage()
    }

    /// Binding to a range setting (stored in metres) shown in the chosen display unit.
    func inDisplayUnits(_ key: WritableKeyPath<RadarParams, Double>) -> Binding<Double> {
        Binding(get: { self.params[keyPath: key] * self.params.rangeUnit.perMeter },
                set: { self.params[keyPath: key] = $0 / self.params.rangeUnit.perMeter })
    }

    // MARK: processing mode

    /// Tabs 0 (Radar) and 1 (Diagnostics) run the FMCW (RTI) chain, 3 the Doppler-vs-time chain,
    /// 4 (SAR) neither; 2 (How it works) leaves the mode as it was.
    func selectTab(_ tab: Int) {
        let m: ProcessingMode
        switch tab {
        case 0, 1: m = .rti
        case 3: m = .dti
        case 4: m = .sar
        default: return
        }
        guard m != processingMode else { return }
        processingMode = m
        gate.set(m)
    }

    // MARK: Doppler vs. time

    /// The Doppler-vs-time plot's height in screen pixels: its image gets at most that many rows.
    func setDTPixelHeight(_ px: Int) {
        let eng = dtEngine
        eng.requestPixelRows(px)
        dtQueue.async { eng.applyPending() }
    }

    private func requestDopplerUpdate() {
        let eng = dtEngine
        eng.request(params)
        dtQueue.async { eng.applyPending() }
    }

    /// Asks for a .wav recording (sync/IF stereo or IF only) and shows its Doppler vs. time.
    func chooseDopplerRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .audio]
        panel.message = "Choose a CW Doppler recording (.wav), e.g. MIT's \"Off of Newton Exit 17.wav\""
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDopplerRecording(url)
    }

    func openDopplerRecording(_ url: URL) {
        dtBusy = true
        dtSelectedRow = nil
        let eng = dtEngine
        dtQueue.async { [weak self] in
            do {
                let file = try AVAudioFile(forReading: url)
                let frames = AVAudioFrameCount(file.length)
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw CocoaError(.fileReadCorruptFile) }
                try file.read(into: buf)
                guard let ch = buf.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
                let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
                let left = Array(UnsafeBufferPointer(start: ch[0], count: n))
                let right = chans > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : []
                eng.loadFile(name: url.lastPathComponent, left: left, right: right, fs: file.processingFormat.sampleRate)
            } catch {
                DispatchQueue.main.async {
                    self?.dtBusy = false
                    self?.setStatus("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    /// Back from a recording to the live input.
    func showDopplerLive() {
        dtBusy = true
        dtSelectedRow = nil
        let eng = dtEngine
        dtQueue.async { eng.showLive() }
    }

    func resetPGA() {
        let proc = processor
        queue.async { proc.resetPGA() }
    }

    func clearHold() {
        let proc = processor
        queue.async { proc.clearHold() }
    }

    func autoScale() {
        guard let t = trace, t.count > 1 else { return }
        let mx = Double(t[1..<min(t.count, derived.nBins)].max() ?? -60)
        params.dbTop = (ceil((mx + 3) / 5) * 5)
    }

    // MARK: polling

    private func poll() {
        // the RTI displays only change while the RTI chain runs; polling would just redraw the window
        guard processingMode == .rti else { return }
        let proc = processor
        queue.async { [weak self] in
            let s = proc.takeSnapshot()
            DispatchQueue.main.async { self?.apply(s) }
        }
    }

    private var droppedSeconds = 0.0

    // automatic top: per-pulse peak levels over the last few seconds, and when the top last moved
    private var levelHistory: [(time: Double, db: Double)] = []
    private var lastTopChange = 0.0

    /// Moves the top dB to follow the 90th percentile of the per-pulse peak over the last 10 s.
    /// The top only moves when that level leaves a 10 dB band, by whole 5 dB steps, and at
    /// most every 5 s, so single pulses can't change the scale or recolour the RTI.
    private func updateAutoTop(rows: [[Float]]) {
        let now = ProcessInfo.processInfo.systemUptime
        let hi = min(derived.nBins, rows.first?.count ?? 0)
        if hi > 2 {
            for row in rows { levelHistory.append((now, Double(row[1..<hi].max() ?? -200))) }
        }
        levelHistory.removeAll { now - $0.time > 10 }
        guard params.autoTop, levelHistory.count >= 25, now - lastTopChange >= 5 else { return }
        let sorted = levelHistory.map(\.db).sorted()
        let level = sorted[Int(Double(sorted.count - 1) * 0.9)]
        let target = ceil((level + 3) / 5) * 5
        if target > params.dbTop || target < params.dbTop - 10 {
            params.dbTop = target
            lastTopChange = now
        }
    }

    private func apply(_ s: ProcessorSnapshot) {
        let dropped = backlog.takeDropped()
        if dropped > 0 && source == .live {
            droppedSeconds += Double(dropped) / fs
            setStatus(String(format: "Processing can't keep up with real time: %.1f s of audio skipped so far. Try fewer options (matrix pencil, SVA, PGA), or run the Release build.", droppedSeconds), error: true)
        }
        if s.generation != generation {
            generation = s.generation
            resetRTI(width: s.derived.nfft / 2)
            levelHistory.removeAll()
            rangeDoppler = nil
        }
        updateAutoTop(rows: s.newRows)
        if !s.newRows.isEmpty {
            var added = false
            for row in s.newRows where rti.append(row, top: params.dbTop, range: params.rtiDbRange) { added = true }
            if added { rtiImage = rti.makeImage() }
        }
        if source == .none && s.newRows.isEmpty && s.scope == nil { return }

        trace = s.traceDB
        hold = s.holdDB
        if let sc = s.scope { scope = sc }
        if let e = s.edge { edge = e }
        pgaPhase = s.pgaPhase
        if pgaUpdates != s.pgaUpdates { pgaUpdates = s.pgaUpdates }
        if pgaAccepted != s.pgaAccepted { pgaAccepted = s.pgaAccepted }
        pgaAgreement = s.pgaAgreement
        pencilTargets = s.pencilTargets
        pencilOrder = s.pencilOrder
        pencilMs = s.pencilMs
        if pulseCount != s.pulseCount { pulseCount = s.pulseCount }
        if let rd = s.rangeDoppler { rangeDoppler = rd }
        if rdCollected != s.rdCollected { rdCollected = s.rdCollected }

        var st = stats
        st.pulseRateHz = s.pulseRateHz ?? st.pulseRateHz
        st.periodMs = s.periodMs ?? st.periodMs
        st.jitterIntegerUs = s.jitterIntegerUs ?? st.jitterIntegerUs
        st.jitterInterpUs = s.jitterInterpUs ?? st.jitterInterpUs
        st.levelL = max(s.peakL, st.levelL * 0.85)
        st.levelR = max(s.peakR, st.levelR * 0.85)
        if let t = s.traceDB { (st.peakRange, st.peakDB) = strongestReturn(t, s.derived) }
        stats = st
        updateSuggestion(s)
    }

    /// Checks that the trigger channel looks like a square wave and that its period matches Tp.
    private func updateSuggestion(_ s: ProcessorSnapshot) {
        guard source == .live, let sqT = s.squarenessTrigger, let sqI = s.squarenessIF else { return }
        var next: Suggestion?
        if sqT < 0.5 && sqI > 0.65 {
            next = .swapChannels(toRight: !params.syncOnRight)
        } else if sqT > 0.65, let period = s.periodMs, let rate = s.pulseRateHz, rate > 1 {
            // The sync is high during the up-chirp and low during the down-chirp, so Tp is half its period.
            let tp = (period / 2 * 100).rounded() / 100
            if abs(tp - params.tpMs) / params.tpMs > 0.05 { next = .setTp(tp) }
        }
        if next != suggestion { suggestion = next }
    }

    /// Largest bin beyond 0.5 m (skips DC / feed-through), refined with a parabolic fit.
    private func strongestReturn(_ db: [Float], _ d: Derived) -> (Double?, Double?) {
        let first = max(1, Int(ceil(0.5 / d.metersPerBin)))
        let nb = min(db.count, d.nBins)
        guard first < nb - 1 else { return (nil, nil) }
        var kb = first
        for k in first..<nb where db[k] > db[kb] { kb = k }
        var kf = Double(kb)
        if kb > 0 && kb + 1 < nb {
            let a = Double(db[kb - 1]), b = Double(db[kb]), c = Double(db[kb + 1])
            let den = a - 2 * b + c
            if den < 0 { kf += 0.5 * (a - c) / den }
        }
        return (kf * d.metersPerBin, Double(db[kb]))
    }
}

// MARK: - RTI image

/// Rolling range-time-intensity image, newest row first, coloured with a jet map.
/// Long histories keep the image at most `maxRows` tall by combining several pulses per
/// row (keeping the strongest value in each range bin, so brief targets stay visible).
final class RTIBuffer {
    /// At most the plot's height in screen pixels, so drawing never drops rows: dropping a different
    /// set of rows as the image scrolls makes narrow returns flicker. Set from the plot's size.
    var maxRows = 400
    private(set) var height = 400
    private(set) var pulsesPerRow = 1
    private(set) var width = 0
    private(set) var rows = 0
    // every pulse of the history, newest at rawNewest
    private var raw: [Float] = []
    private var rawCap = 0
    private var rawNewest = 0
    private var rawCount = 0
    // the displayed window: rows combining pulsesPerRow pulses
    private var db: [Float] = []
    private var rgba: [UInt8] = []
    private var newest = 0
    private var pending: [Float] = []
    private var pendingCount = 0

    static let jet: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
        let v = Double(i) / 255
        let c = { (x: Double) in UInt8(min(1, max(0, 1.5 - abs(4 * v - x))) * 255) }
        return [c(3), c(2), c(1), 255]
    }

    /// Sizes the buffer to keep `pulses` pulses of history and show the newest `viewPulses`.
    func reset(width: Int, pulses: Int, viewPulses: Int, top: Double, range: Double) {
        self.width = width
        rawCap = max(10, pulses)
        raw = [Float](repeating: -400, count: width * rawCap)
        rawNewest = 0
        rawCount = 0
        configureView(viewPulses)
        recolor(top: top, range: range)
    }

    /// Shows the newest `pulses` pulses of the history, rebuilt from the stored pulses.
    func setView(pulses: Int, top: Double, range: Double) {
        configureView(pulses)
        let ppr = pulsesPerRow
        for r in 0..<height {
            let first = r * ppr
            guard first < rawCount else { break }
            let base = r * width
            for i in first..<min(first + ppr, rawCount) {
                let src = ((rawNewest + i) % rawCap) * width
                for k in 0..<width where raw[src + k] > db[base + k] { db[base + k] = raw[src + k] }
            }
            rows = r + 1
        }
        recolor(top: top, range: range)
    }

    private func configureView(_ pulses: Int) {
        let total = max(10, min(pulses, rawCap))
        pulsesPerRow = max(1, Int((Double(total) / Double(maxRows)).rounded(.up)))
        height = max(10, total / pulsesPerRow)
        rows = 0
        newest = 0
        pending = []
        pendingCount = 0
        db = [Float](repeating: -400, count: width * height)
        rgba = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Adds one pulse; returns true when a new image row was completed.
    @discardableResult
    func append(_ row: [Float], top: Double, range: Double) -> Bool {
        guard row.count == width, width > 0 else { return false }
        rawNewest = (rawNewest - 1 + rawCap) % rawCap
        let rb = rawNewest * width
        for k in 0..<width { raw[rb + k] = row[k] }
        rawCount = min(rawCount + 1, rawCap)

        if pendingCount == 0 {
            pending = row
        } else {
            for k in 0..<width where row[k] > pending[k] { pending[k] = row[k] }
        }
        pendingCount += 1
        guard pendingCount >= pulsesPerRow else { return false }
        pendingCount = 0
        let row = pending
        newest = (newest - 1 + height) % height
        let base = newest * width
        for k in 0..<width { db[base + k] = row[k] }
        colorRow(newest, top: top, range: range)
        rows = min(rows + 1, height)
        return true
    }

    func recolor(top: Double, range: Double) {
        for r in 0..<height { colorRow(r, top: top, range: range) }
    }

    private func colorRow(_ r: Int, top: Double, range: Double) {
        let lo = Float(top - range), scale = Float(255 / max(1, range))
        let base = r * width
        for k in 0..<width {
            let i = Int(max(0, min(255, ((db[base + k] - lo) * scale).rounded())))
            let p = (base + k) * 4
            rgba[p] = RTIBuffer.jet[i * 4]
            rgba[p + 1] = RTIBuffer.jet[i * 4 + 1]
            rgba[p + 2] = RTIBuffer.jet[i * 4 + 2]
            rgba[p + 3] = 255
        }
    }

    func makeImage() -> CGImage? {
        guard width > 0 else { return nil }
        let rowBytes = width * 4
        var ordered = Data(count: rgba.count)
        // rows newest ... height-1 then 0 ... newest-1
        let headRows = height - newest
        ordered.withUnsafeMutableBytes { dst in
            rgba.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress! + newest * rowBytes, byteCount: headRows * rowBytes)
                if newest > 0 {
                    (dst.baseAddress! + headRows * rowBytes).copyMemory(from: src.baseAddress!, byteCount: newest * rowBytes)
                }
            }
        }
        guard let provider = CGDataProvider(data: ordered as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Counts audio frames waiting on the DSP queue (audio thread adds, DSP queue removes).
final class AudioBacklog {
    private let lock = NSLock()
    private var frames = 0
    private var dropped = 0
    private var resync = false

    func reset() { lock.lock(); frames = 0; dropped = 0; resync = false; lock.unlock() }

    /// nil = drop this block; otherwise whether the processor must re-acquire the trigger first.
    func tryAdd(_ n: Int, limit: Int) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        if frames + n > limit { dropped += n; resync = true; return nil }
        frames += n
        let r = resync
        resync = false
        return r
    }

    func remove(_ n: Int) { lock.lock(); frames -= n; lock.unlock() }

    func takeDropped() -> Int { lock.lock(); defer { lock.unlock() }; let d = dropped; dropped = 0; return d }
}
