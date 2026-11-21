import SwiftUI

@main
struct KeyBarApp: App {
    @ViewState private var monitor = KeyboardMonitor()

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let week = CommandLine.arguments.contains("--week")
            Snapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), chartRange: week ? .week : .today)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let monitor: KeyboardMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: KeycapGlyph.image(pointSize: 17, dimmed: !monitor.isConnected))
            if monitor.isConnected, monitor.showsPercentInMenuBar, let battery = monitor.battery {
                Text("\(battery)%").monospacedDigit()
            }
        }
    }
}
