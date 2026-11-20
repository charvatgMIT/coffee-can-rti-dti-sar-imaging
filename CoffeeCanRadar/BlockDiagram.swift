import AppKit
import SwiftUI

// Block diagram and About pieces.

struct DiagramBlock: Identifiable {
    enum Kind { case input, process, output }
    let id = UUID()
    var title: String
    var detail: String
    var active = true
    var kind: Kind = .process
}

/// Rows of blocks top to bottom, joined by arrows; blocks in one row are alternatives or run side by side.
struct BlockDiagram: View {
    let rows: [[DiagramBlock]]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { BlockView(block: $0) }
                }
            }
        }
    }
}

struct BlockView: View {
    let block: DiagramBlock

    private var tint: Color {
        guard block.active else { return .gray }
        switch block.kind {
        case .input: return .purple
        case .output: return .green
        case .process: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(block.title).font(.callout.weight(.semibold))
                if !block.active {
                    Text("off").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().stroke(Color.secondary.opacity(0.6)))
                }
            }
            Text(block.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(block.active ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(tint.opacity(block.active ? 0.7 : 0.35), style: StrokeStyle(lineWidth: 1, dash: block.active ? [] : [4, 3])))
        .opacity(block.active ? 1 : 0.6)
    }
}

/// Legend shown under a diagram.
struct DiagramLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([("Input", Color.purple), ("Processing", Color.accentColor), ("Output", Color.green)], id: \.0) { name, c in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.25)).overlay(RoundedRectangle(cornerRadius: 3).stroke(c))
                        .frame(width: 14, height: 10)
                    Text(name)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).stroke(Color.gray, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 14, height: 10)
                Text("Off in the current settings")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

enum AboutInfo {
    static let appName = "Coffee Can RTI DTI SAR Imaging"
    static let credit = "Vibe coded by Gregory L. Charvat & Jared Smith based on original Matlab scripts from MIT OCW"
    static let ocwURL = URL(string: "https://ocw.mit.edu/courses/res-ll-003-build-a-small-radar-system-capable-of-sensing-range-doppler-and-synthetic-aperture-radar-imaging-january-iap-2011/resources/doppler-radar-using-the-coffee-can-radar/")!

    /// The date this copy of the app was built (the executable's modification date).
    static var buildDate: String {
        let date = Bundle.main.executableURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date } ?? Date()
        return date.formatted(date: .long, time: .omitted)
    }

    static func showPanel(appName: String) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: para,
            .foregroundColor: NSColor.labelColor,
        ]
        let credits = NSMutableAttributedString(string: credit + "\n", attributes: base)
        var link = base
        link[.link] = ocwURL
        credits.append(NSAttributedString(string: ocwURL.absoluteString, attributes: link))
        credits.append(NSAttributedString(string: "\n\n" + buildDate, attributes: base))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: appName, .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// About section for a sidebar Form.
struct AboutSection: View {
    let appName: String

    var body: some View {
        Section("About") {
            Text(appName).font(.headline)
            LabeledContent("Date", value: AboutInfo.buildDate)
            Text(AboutInfo.credit).font(.callout)
            Link(AboutInfo.ocwURL.absoluteString, destination: AboutInfo.ocwURL).font(.caption)
        }
    }
}

/// About card for the "How it works" tab.
struct AboutCard: View {
    let appName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("About").font(.headline)
            Text(appName).font(.callout.weight(.semibold))
            Text(AboutInfo.buildDate).font(.callout).foregroundStyle(.secondary)
            Text(AboutInfo.credit).font(.callout)
            Link(AboutInfo.ocwURL.absoluteString, destination: AboutInfo.ocwURL).font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}
