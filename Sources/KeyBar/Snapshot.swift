import SwiftUI

/// `KeyBar --snapshot out.png` renders the live popover to an image (used for the README).
@MainActor
enum Snapshot {
    private static let settleDelay: TimeInterval = 4

    static func render(to url: URL, chartRange: ChartRange = .today) {
        let monitor = KeyboardMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            monitor.popoverDidAppear()
            // Show the chart hovered on the fastest minute, the way someone exploring it would.
            let fastest = monitor.snapshot.timeline?.points.max { $0.wpm < $1.wpm }
                .map { SparkChart.Point(x: $0.start, y: $0.wpm.rounded()) }
            let panel = PopoverView(monitor: monitor, redactsAddress: true, showsDetails: false, chartRange: chartRange,
                                    hoveredWPM: chartRange == .today ? fastest : nil)
                .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(40)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: panel)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("snapshot failed\n".utf8))
                exit(1)
            }
            try? data.write(to: url)
            exit(0)
        }
    }
}
