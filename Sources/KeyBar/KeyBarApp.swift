import SwiftUI

@main
struct KeyBarApp: App {
    @ViewState private var monitor = KeyboardMonitor()

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let week = CommandLine.arguments.contains("--week")
            let state: ConnectionState? = switch CommandLine.arguments.drop(while: { $0 != "--state" }).dropFirst().first {
            case "asleep": .asleep(since: .now.addingTimeInterval(-25 * 60))
            case "off": .disconnected(lastSeen: .now.addingTimeInterval(-3 * 3_600))
            default: nil
            }
            Snapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), chartRange: week ? .week : .today, state: state)
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
            // A nap keeps the percent, so it doesn't blink away every time you stop typing.
            if monitor.isConnected || monitor.isAsleep, monitor.showsPercentInMenuBar, let battery = monitor.battery {
                Text("\(battery)%").monospacedDigit()
            }
        }
    }
}
