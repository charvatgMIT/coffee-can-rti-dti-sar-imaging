import SwiftUI

// Jet colour map for the SAR images (the plot helpers are shared with the RTI tabs, in Plots.swift).

enum Jet {
    static let jet: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
        let v = Double(i) / 255
        let c = { (x: Double) in UInt8(min(1, max(0, 1.5 - abs(4 * v - x))) * 255) }
        return [c(3), c(2), c(1), 255]
    }
}
