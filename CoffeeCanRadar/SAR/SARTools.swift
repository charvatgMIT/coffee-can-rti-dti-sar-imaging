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
