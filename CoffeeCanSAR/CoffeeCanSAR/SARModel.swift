import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Main-thread state. Reading, parsing and image formation run on a background queue.
final class SARModel: ObservableObject {
    @Published var params = SARModel.loadParams() {
        didSet {
            guard params != oldValue else { return }
            if let d = try? JSONEncoder().encode(params) { UserDefaults.standard.set(d, forKey: "SARParams") }
            if params.dbRange != oldValue.dbRange { recolor() }
        }
    }
    @Published private(set) var fileURL: URL?
    @Published private(set) var status = "Open a Coffee Can Radar SAR recording (.wav), e.g. towardswarehouse.wav from MIT's Experiment 3."
    @Published private(set) var statusIsError = false
    @Published private(set) var busy = false
    @Published private(set) var result: SARResult?
    @Published private(set) var sarImage: CGImage?
    @Published private(set) var profileImage: CGImage?
    @Published private(set) var kImage: CGImage?
    @Published private(set) var recordingInfo: String?

    private let queue = DispatchQueue(label: "org.coffeecanradar.CoffeeCanSAR.work", qos: .userInitiated)
    private var recording: StereoRecording?
    private var parsedFor: SARParams?
    private var parsed: ParsedSAR?

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.async { self.open(url) }
        }
    }

    private static func loadParams() -> SARParams {
        guard let d = UserDefaults.standard.data(forKey: "SARParams"),
              let saved = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let defData = try? JSONEncoder().encode(SARParams()),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return SARParams() }
        merged.merge(saved) { _, new in new }
        guard let md = try? JSONSerialization.data(withJSONObject: merged),
              let p = try? JSONDecoder().decode(SARParams.self, from: md) else { return SARParams() }
        return p
    }

    func resetSettings() { params = SARParams() }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Coffee Can Radar SAR recording (sync on one channel, IF on the other)."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Reads the recording and processes it.
    func open(_ url: URL) {
        fileURL = url
        recording = nil; parsed = nil; parsedFor = nil
        result = nil; sarImage = nil; profileImage = nil; kImage = nil; recordingInfo = nil
        busy = true
        setStatus("Reading \(url.lastPathComponent)…")
        queue.async {
            do {
                let rec = try readStereoWAV(url)
                DispatchQueue.main.async {
                    self.recording = rec
                    self.recordingInfo = String(format: "%.1f s, %.0f Hz, 2 channels", Double(rec.left.count) / rec.fs, rec.fs)
                    self.busy = false
                    self.process()
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.setStatus(error.localizedDescription, error: true) }
            }
        }
    }

    /// Parses positions (only if the parsing settings changed) and forms the image.
    func process() {
        guard let rec = recording, !busy else { return }
        let p = params
        let reuse = parsedFor.map { Self.sameParsing($0, p) } ?? false ? parsed : nil
        busy = true
        setStatus(reuse == nil ? "Finding aperture positions and averaging up-chirps…" : "Forming the image…")
        queue.async {
            do {
                let t0 = Date()
                let data = try reuse ?? parseSAR(rec, p)
                let t1 = Date()
                let focused = autofocus(data, p)       // mean subtraction, range PGA, crossrange autofocus
                let (image, k) = formSARImage(focused, p)
                let (profiles, maxFt) = rangeProfiles(data, p)
                let t2 = Date()
                let r = SARResult(parsed: focused, image: image, rangeProfiles: profiles, rangeProfileMaxFt: maxFt, kSpace: k, algorithm: p.algorithm,
                                  parseSeconds: reuse == nil ? t1.timeIntervalSince(t0) : 0, imageSeconds: t2.timeIntervalSince(t1))
                let imgs = Self.render(r, p)
                DispatchQueue.main.async {
                    self.parsed = data; self.parsedFor = p
                    self.result = r
                    (self.sarImage, self.profileImage, self.kImage) = imgs
                    self.busy = false
                    let pp = data.pulsesPerPosition.sorted()
                    var chirps = pp.first == pp.last ? "\(pp.first ?? 0) up-chirps averaged at every position"
                                                     : "\(pp.first ?? 0)–\(pp.last ?? 0) up-chirps averaged per position"
                    if data.requestedChirps > 0 && (pp.first ?? 0) < data.requestedChirps {
                        chirps += " (\(data.requestedChirps) requested, but one position only has \(data.availableChirpsMin ?? 0) complete chirps)"
                    } else if let a = data.availableChirpsMin {
                        chirps += " (the shortest position has \(a) complete)"
                    }
                    var jit = ""
                    if let n = image.pencilNote { jit += " Super-resolution: " + n + "." }
                    if let ph = focused.rangePhase { jit += String(format: " Range PGA %.2f rad rms.", rms(ph)) }
                    if let ps = focused.crossPhase { jit += String(format: " Crossrange autofocus %.2f rad rms.", rms(ps)) }
                    if let ji = data.jitterIntegerUs {
                        jit = data.jitterInterpUs.map { String(format: " Sync period jitter σ: integer %.2f → interpolated %.2f µs.", ji, $0) }
                            ?? String(format: " Sync period jitter σ (integer edges): %.2f µs.", ji)
                    }
                    self.setStatus(String(format: "%d aperture positions (%.1f ft of rail), %@. Parsing %@, %@ %.2f s.",
                                          data.positions, Double(data.positions) * p.spacingInches / 12, chirps,
                                          reuse == nil ? String(format: "%.2f s", r.parseSeconds) : "reused",
                                          p.algorithm == .rma ? "range migration" : "backprojection", r.imageSeconds) + jit,
                                   error: data.positions < 2 || (data.requestedChirps > 0 && (pp.first ?? 0) < data.requestedChirps))
                    SnapshotTool.fireIfRequested(model: self)
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.setStatus(error.localizedDescription, error: true) }
            }
        }
    }

    private static func sameParsing(_ a: SARParams, _ b: SARParams) -> Bool {
        a.invert == b.invert && a.syncOnRight == b.syncOnRight && a.tpMs == b.tpMs && a.trpSeconds == b.trpSeconds
            && a.syncThreshold == b.syncThreshold && a.alignment == b.alignment && a.interpolation == b.interpolation
            && a.holdoff == b.holdoff && a.chirpsPerPosition == b.chirpsPerPosition
    }

    private func recolor() {
        guard let r = result else { return }
        let imgs = Self.render(r, params)
        (sarImage, profileImage, kImage) = imgs
    }

    private static func render(_ r: SARResult, _ p: SARParams) -> (CGImage?, CGImage?, CGImage?) {
        (makeImage(r.image.db, rows: r.image.rows, cols: r.image.cols, top: r.image.maxDB, range: p.dbRange, flip: true),
         makeImage(r.rangeProfiles.db, rows: r.rangeProfiles.rows, cols: r.rangeProfiles.cols, top: r.rangeProfiles.maxDB, range: p.dbRange, flip: false),
         r.kSpace.flatMap { makeImage($0.db, rows: $0.rows, cols: $0.cols, top: $0.maxDB, range: p.dbRange, flip: false) })
    }

    private func setStatus(_ s: String, error: Bool = false) { status = s; statusIsError = error }
}

/// Jet-coloured image of a dB array ([row][col]); `flip` puts row 0 at the bottom.
func makeImage(_ db: [Float], rows: Int, cols: Int, top: Double, range: Double, flip: Bool) -> CGImage? {
    guard rows > 0, cols > 0 else { return nil }
    let lo = Float(top - range), scale = Float(255 / max(1, range))
    var rgba = [UInt8](repeating: 255, count: rows * cols * 4)
    for r in 0..<rows {
        let dst = (flip ? rows - 1 - r : r) * cols
        for c in 0..<cols {
            let o = (dst + c) * 4
            let v = db[r * cols + c]
            if v == -.infinity { rgba[o] = Jet.jet[0]; rgba[o + 1] = Jet.jet[1]; rgba[o + 2] = Jet.jet[2]; continue }   // blanked: the colour scale's bottom blue
            let i = Int(max(0, min(255, ((v - lo) * scale).rounded()))) * 4
            rgba[o] = Jet.jet[i]; rgba[o + 1] = Jet.jet[i + 1]; rgba[o + 2] = Jet.jet[i + 2]
        }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// `--open <wav> --snapshot <png> [--tab 0|1|2]`: renders the window once processing finishes, then quits.
enum SnapshotTool {
    static func fireIfRequested(model: SARModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
