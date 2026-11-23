import Foundation

/// `--dump <wav> <dir>`: writes the parsed data (before and after the mean subtraction) as raw
/// little-endian doubles, re/im interleaved, [position][sample], for comparison with MIT's .mat files.
enum SARDumpTool {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--dump"), i + 2 < args.count else { return }
        do {
            var p = SARParams()
            p.alignment = .mit          // reproduce the MIT script exactly, for comparison with its .mat files
            p.chirpsPerPosition = 0
            let t0 = Date()
            let rec = try readStereoWAV(URL(fileURLWithPath: args[i + 1]))
            let t1 = Date()
            let d = try parseSAR(rec, p)
            let t2 = Date()
            let dir = URL(fileURLWithPath: args[i + 2])
            func write(_ re: [Double], _ im: [Double], _ name: String) throws {
                var inter = [Double](repeating: 0, count: re.count * 2)
                for k in re.indices { inter[2 * k] = re[k]; inter[2 * k + 1] = im[k] }
                try inter.withUnsafeBufferPointer { try Data(buffer: $0).write(to: dir.appendingPathComponent(name)) }
            }
            try write(d.re, d.im, "s.bin")
            var re = d.re, im = d.im
            subtractMeanLikeMATLAB(&re, &im, rows: d.positions, cols: d.cols)
            try write(re, im, "sif.bin")
            let t3 = Date()
            _ = formImage(d, p)
            print(String(format: "positions %d x %d samples; pulses/position %d-%d; read %.2f s, parse %.2f s, image %.2f s",
                         d.positions, d.cols, d.pulsesPerPosition.min() ?? 0, d.pulsesPerPosition.max() ?? 0,
                         t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), Date().timeIntervalSince(t3)))
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
}

/// `--sar-dump <wav> <prefix>`: the whole SAR chain (parse, autofocus, image, range profiles) with the default
/// settings overridden by the JSON in $SAR_PARAMS. Writes <prefix>.img.f32 (image dB, [row][col], row 0 nearest),
/// <prefix>.prof.f32 (range profiles dB) and prints the sizes, used to check the web version against this app.
enum SARCompareTool {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--sar-dump"), i + 2 < args.count else { return }
        var p = SARParams()
        if let js = ProcessInfo.processInfo.environment["SAR_PARAMS"],
           let over = try? JSONSerialization.jsonObject(with: Data(js.utf8)) as? [String: Any],
           let defData = try? JSONEncoder().encode(p),
           var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] {
            merged.merge(over) { _, new in new }
            guard let md = try? JSONSerialization.data(withJSONObject: merged), let q = try? JSONDecoder().decode(SARParams.self, from: md) else {
                print("bad SAR_PARAMS"); exit(1)
            }
            p = q
        }
        do {
            let rec = try readStereoWAV(URL(fileURLWithPath: args[i + 1]))
            let t0 = Date()
            let data = try parseSAR(rec, p)
            let focused = autofocus(data, p)
            let (img, _) = formSARImage(focused, p)
            let (prof, _) = rangeProfiles(data, p)
            let secs = Date().timeIntervalSince(t0)
            let out = args[i + 2]
            img.db.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: URL(fileURLWithPath: out + ".img.f32")) }
            prof.db.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: URL(fileURLWithPath: out + ".prof.f32")) }
            print(String(format: "%d positions, pulses %d-%d; image %d x %d, cross %.2f..%.2f ft, down %.2f..%.2f ft, max %.3f dB; range PGA %@ rad rms, cross %@ rad rms; %.2f s%@",
                         data.positions, data.pulsesPerPosition.min() ?? 0, data.pulsesPerPosition.max() ?? 0, img.rows, img.cols,
                         img.crossRange.0, img.crossRange.1, img.downRange.0, img.downRange.1, img.maxDB,
                         focused.rangePhase.map { String(format: "%.4f", rms($0)) } ?? "-", focused.crossPhase.map { String(format: "%.4f", rms($0)) } ?? "-",
                         secs, img.pencilNote.map { "; " + $0 } ?? ""))
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
}
