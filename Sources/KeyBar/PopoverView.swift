import SwiftUI

struct PopoverView: View {
    @Bindable var monitor: KeyboardMonitor
    let redactsAddress: Bool
    @ViewState private var showsDetails: Bool
    @ViewState private var hoveredWPM: SparkChart.Point?
    @ViewState private var chartRange = ChartRange.today

    init(monitor: KeyboardMonitor, redactsAddress: Bool = false, showsDetails: Bool = false, chartRange: ChartRange = .today,
         hoveredWPM: SparkChart.Point? = nil) {
        self.monitor = monitor
        self.redactsAddress = redactsAddress
        _showsDetails = ViewState(initialValue: showsDetails)
        _chartRange = ViewState(initialValue: chartRange)
        _hoveredWPM = ViewState(initialValue: hoveredWPM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.padding(.bottom, 2)
            if monitor.isConnected {
                if !monitor.hasAccess { accessCard }
                batteryCard
                typingCard
                tiles
                details
            } else {
                disconnectedCard
            }
            Divider().padding(.horizontal, 6).padding(.vertical, 2)
            options
            Divider().padding(.horizontal, 6).padding(.vertical, 2)
            actions
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { monitor.popoverDidAppear() }
        .onDisappear { monitor.popoverDidDisappear() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: KeycapGlyph.image(pointSize: 22))
                .renderingMode(.template)
                .foregroundStyle(monitor.isConnected ? Color.accentColor : .secondary)
                .frame(width: 38, height: 38)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.displayName).font(.system(size: 14, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isConnected, monitor.supportsBattery {
                BatteryRing(percent: monitor.battery, isCharging: monitor.trend == .charging)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 2)
    }

    private var statusLine: String {
        switch monitor.connection {
        case .connected:
            let session = monitor.sessionStart.map { " · " + Format.duration(monitor.now.timeIntervalSince($0)) } ?? ""
            return "Connected" + session
        case .disconnected(let lastSeen):
            guard let lastSeen else { return "Not connected" }
            return "Last seen " + lastSeen.formatted(.relative(presentation: .named))
        case .notPaired:
            return "No Keychron paired"
        }
    }

    // MARK: Cards

    private var accessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow Input Monitoring").font(.system(size: 13, weight: .semibold))
                Text("The keyboard sends its battery level and keystrokes over HID, and macOS asks before an app can read them. KeyBar only keeps counts, never what you type.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { monitor.requestAccess() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var batteryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(title: "Battery", trailing: batteryUpdatedText)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    bigNumber(monitor.battery.map(String.init) ?? "--", unit: "%")
                    Spacer()
                    Text(batteryCaption).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                let start = monitor.now.addingTimeInterval(-7 * 86_400)
                let week = monitor.history.samples(since: start).map { SparkChart.Point(x: $0.date, y: Double($0.percent)) }
                // A chart only says something once the level has moved; until then the bar is clearer.
                if Set(week.map(\.y)).count >= 2 {
                    SparkChart(points: week + [SparkChart.Point(x: monitor.now, y: week.last!.y)],
                               color: Palette.battery(monitor.battery), yDomain: Self.zoomedDomain(week.map(\.y)),
                               xDomain: week.first!.x...monitor.now, interpolation: .stepEnd)
                        .frame(height: 36)
                } else {
                    LevelBar(fraction: Double(monitor.battery ?? 0) / 100, color: Palette.battery(monitor.battery))
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var batteryUpdatedText: String? {
        guard let updated = monitor.batteryUpdated else { return nil }
        let age = monitor.now.timeIntervalSince(updated)
        return age < 60 ? "Updated just now" : "Updated \(Format.duration(age)) ago"
    }

    private var batteryCaption: String {
        guard monitor.supportsBattery else { return "Not reported" }
        guard monitor.battery != nil else { return monitor.hasAccess ? "Waiting for keyboard" : "Needs permission" }
        switch monitor.trend {
        case .charging: return "Charging"
        case .discharging(let remaining): return "About \(Format.longDuration(remaining)) left"
        case .unknown: return "Estimating time left"
        }
    }

    private var typingCard: some View {
        let typing = monitor.snapshot
        let hasHistory = typing.days.count >= 2
        let range = hasHistory ? chartRange : .today
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Typing speed").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if hasHistory { RangePicker(selection: $chartRange) }
                }
                .onChange(of: chartRange) { hoveredWPM = nil }
                if range == .today { todayChart(typing) } else { daysChart(typing, range: range) }
            }
        }
    }

    @ViewBuilder
    private func todayChart(_ typing: TypingSnapshot) -> some View {
        let timeline = typing.timeline
        let points = (timeline?.points ?? []).map { SparkChart.Point(x: $0.start, y: $0.wpm.rounded()) }
        let hoveredPoint = hoveredWPM.flatMap { hovered in timeline?.points.first { $0.start == hovered.x } }
        HStack(alignment: .firstTextBaseline) {
            bigNumber("\(hoveredWPM.map { Int($0.y) } ?? typing.liveWPM)", unit: "wpm")
            Spacer()
            Text(hoveredPoint.map { timeRange($0, minutes: timeline!.minutesPerPoint) } ?? "Right now")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        if let timeline, let first = points.first, points.contains(where: { $0.y > 0 }) {
            SparkChart(points: points, color: Palette.typing, xDomain: first.x...monitor.now,
                       hovered: $hoveredWPM, reference: typing.averageWPM.map(Double.init))
                .frame(height: 48)
            chartFooter(start: first.x.formatted(date: .omitted, time: .shortened),
                        middle: timeline.minutesPerPoint == 1 ? "each minute" : "every \(timeline.minutesPerPoint) min",
                        end: "Now", stats: [typing.averageWPM.map { "avg \($0)" }, typing.peakWPM.map { "best \($0)" }])
        } else {
            Text("Your speed through the day appears here as you type.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
    }

    @ViewBuilder
    private func daysChart(_ typing: TypingSnapshot, range: ChartRange) -> some View {
        let start = Calendar.current.startOfDay(for: monitor.now).addingTimeInterval(-Double(range.days - 1) * 86_400)
        let days = typing.days.filter { $0.date >= start && $0.averageWPM != nil }
        let points = days.map { SparkChart.Point(x: $0.date, y: Double($0.averageWPM!)) }
        let hoveredDay = hoveredWPM.flatMap { hovered in days.first { $0.date == hovered.x } }
        let rangeAverage = Self.weightedAverage(days)
        HStack(alignment: .firstTextBaseline) {
            bigNumber("\(hoveredDay?.averageWPM ?? rangeAverage ?? 0)", unit: "wpm")
            Spacer()
            Text(hoveredDay.map { "\($0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \($0.keys.formatted()) keys" }
                 ?? "Average, \(range.label.lowercased())")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        if let first = points.first, points.count >= 2 {
            SparkChart(points: points, color: Palette.typing, yDomain: Self.zoomedDomain(points.map(\.y)),
                       xDomain: first.x...Calendar.current.startOfDay(for: monitor.now),
                       hovered: $hoveredWPM, reference: rangeAverage.map(Double.init), showsDots: true)
                .frame(height: 48)
            chartFooter(start: first.x.formatted(.dateTime.month(.abbreviated).day()), middle: "daily average",
                        end: "Today", stats: [days.compactMap(\.peakWPM).max().map { "best \($0)" }])
        } else {
            Text("Not enough typing in this range yet.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
    }

    private func chartFooter(start: String, middle: String, end: String, stats: [String?]) -> some View {
        HStack {
            Text(start)
            Spacer()
            Text(([middle] + stats.compactMap { $0 }).joined(separator: " · "))
            Spacer()
            Text(end)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    /// Fits the y-axis to the data so day-to-day changes are visible rather than flattened against zero.
    private static func zoomedDomain(_ values: [Double]) -> ClosedRange<Double> {
        let low = values.min() ?? 0, high = values.max() ?? 1
        let padding = max((high - low) * 0.25, 5)
        return max(low - padding, 0)...(high + padding)
    }

    /// Average speed across days, weighted by how long each day was spent typing.
    private static func weightedAverage(_ days: [DaySummary]) -> Int? {
        let seconds = days.map(\.activeSeconds).reduce(0, +)
        guard seconds >= 60 else { return nil }
        let characters = Double(days.map(\.characters).reduce(0, +))
        return Int((characters / TypingStats.charactersPerWord / (seconds / 60)).rounded())
    }

    private func timeRange(_ point: TypingStats.Point, minutes: Int) -> String {
        let start = point.start.formatted(date: .omitted, time: .shortened)
        guard minutes > 1 else { return start }
        return "\(start) – \(point.end.formatted(date: .omitted, time: .shortened))"
    }

    private var tiles: some View {
        let typing = monitor.snapshot
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                StatTile(title: "Keystrokes", symbol: "number", value: typing.keysToday.formatted(),
                         caption: typing.activeTime >= 60 ? "\(Format.duration(typing.activeTime)) of typing today" : "Today")
                StatTile(title: "Corrections", symbol: "delete.left",
                         value: typing.correctionRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–",
                         caption: "Backspace share")
            }
            GridRow {
                StatTile(title: "Caps Lock", symbol: "capslock", value: monitor.capsLockOn ? "On" : "Off",
                         caption: monitor.capsLockOn ? "Typing in capitals" : "Lowercase", isHighlighted: monitor.capsLockOn)
                sleepTile
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sleepTile: some View {
        let remaining = monitor.sleepCountdown
        let idle = remaining.map { KeyboardMonitor.autoSleepAfter - $0 } ?? 0
        let (value, caption): (String, String) = switch remaining {
        case .some(let left) where left <= 0: ("Asleep", "Press a key to wake")
        case .some(let left) where idle >= 60: (Format.countdown(left), "Sleeps if you stay idle")
        default: ("Awake", "After 10 min idle")
        }
        return StatTile(title: "Auto-sleep", symbol: "moon", value: value, caption: caption)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showsDetails.toggle() }
            } label: {
                HStack {
                    Text("Device Details").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDetails, let info = monitor.info {
                Card {
                    VStack(spacing: 7) {
                        DetailRow(label: "Firmware", value: monitor.firmware ?? "Reading…")
                        DetailRow(label: "Address", value: redactsAddress ? "XX:XX:XX:XX:XX:XX" : info.address)
                        if let hz = monitor.pollingRateHz { DetailRow(label: "Report rate", value: "\(hz) Hz") }
                        DetailRow(label: "Identifies as", value: "\(Format.hex(info.vendorID)):\(Format.hex(info.productID))")
                        DetailRow(label: "Top row in macOS", value: monitor.fnKeysAreStandard ? "F1–F12" : "Media keys")
                        DetailRow(label: "Input source", value: monitor.inputSource)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var disconnectedCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(nsImage: KeycapGlyph.image(pointSize: 30, dimmed: true))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                Text(monitor.connection == .notPaired
                     ? "Pair your Keychron in Bluetooth settings to see it here."
                     : "Press any key to wake the keyboard, or connect it below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let battery = monitor.battery {
                    Text("Battery was \(battery)% when last seen").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    // MARK: Footer

    private var options: some View {
        VStack(spacing: 0) {
            SwitchRow(title: "Battery in menu bar", isOn: $monitor.showsPercentInMenuBar)
            SwitchRow(title: "Low battery alerts", isOn: $monitor.lowBatteryAlerts)
            SwitchRow(title: "Open at login", isOn: $monitor.launchAtLogin)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            if monitor.connection != .notPaired {
                MenuRow(title: monitor.isTogglingLink ? "Working…" : monitor.isConnected ? "Disconnect" : "Connect") {
                    monitor.toggleConnection()
                }
            }
            MenuRow(title: "Bluetooth Settings…") { monitor.openBluetoothSettings() }
            MenuRow(title: "Quit KeyBar", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func bigNumber(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(unit).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
    }
}
