import Foundation

/// Mini-Circuits ZX95-2536C+ VCO, from its datasheet (REV. A):
/// specified 2315-2536 MHz over Vtune 0.5-5 V, 57-77 MHz/V, +6 dBm, Vcc 5 V.
enum VCO {
    static let name = "Mini-Circuits ZX95-2536C+"

    /// Typical frequency vs. tuning voltage at +25 °C (datasheet page 2).
    static let curve: [(volts: Double, mhz: Double)] = [
        (0.00, 2257.4), (0.50, 2297.3), (0.75, 2315.9), (1.00, 2334.4), (1.25, 2352.9),
        (1.50, 2371.3), (1.75, 2389.8), (2.00, 2408.5), (2.25, 2427.0), (2.50, 2445.3),
        (2.75, 2463.3), (3.00, 2481.0), (3.25, 2498.1), (3.50, 2514.5), (3.75, 2529.8),
        (4.00, 2544.2), (4.25, 2557.6), (4.50, 2570.1), (4.75, 2581.5), (5.00, 2591.8),
    ]

    static var minMHz: Double { curve.first!.mhz }
    static var maxMHz: Double { curve.last!.mhz }

    /// Linear interpolation of the curve; nil outside 0-5 V.
    static func mhz(atVolts v: Double) -> Double? {
        guard let hi = curve.firstIndex(where: { $0.volts >= v }) else { return nil }
        if hi == 0 { return v == curve[0].volts ? curve[0].mhz : nil }
        let a = curve[hi - 1], b = curve[hi]
        return a.mhz + (v - a.volts) / (b.volts - a.volts) * (b.mhz - a.mhz)
    }

    /// Inverse of `mhz(atVolts:)`; nil outside the curve.
    static func volts(atMHz f: Double) -> Double? {
        guard let hi = curve.firstIndex(where: { $0.mhz >= f }) else { return nil }
        if hi == 0 { return f == curve[0].mhz ? curve[0].volts : nil }
        let a = curve[hi - 1], b = curve[hi]
        return a.volts + (f - a.mhz) / (b.mhz - a.mhz) * (b.volts - a.volts)
    }
}

/// Sweep band presets for f start / f stop.
enum Band: String, CaseIterable, Identifiable, Codable {
    case full = "Full VCO range (0–5 V)"
    case ism = "ISM band"
    case custom = "Custom"
    var id: String { rawValue }

    /// (f start, f stop) in MHz, or nil for custom.
    var range: (start: Double, stop: Double)? {
        switch self {
        case .full: return (VCO.minMHz, VCO.maxMHz)
        case .ism: return (2402, 2495)        // read_data_RTI.m ISM settings (2-3.2 V sweep)
        case .custom: return nil
        }
    }

    /// True if these settings' f start / f stop are this band's preset.
    func matches(_ p: RadarParams) -> Bool {
        guard let r = range else { return false }
        return abs(p.fStartMHz - r.start) < 0.05 && abs(p.fStopMHz - r.stop) < 0.05
    }
}
