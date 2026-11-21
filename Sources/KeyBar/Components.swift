import Charts
import SwiftUI

/// The Command Line Tools ship no SwiftUI macro plugin, so `@State` (now a macro) cannot expand.
/// The underlying property wrapper still exists; this alias reaches it directly.
typealias ViewState<Value> = SwiftUI.State<Value>

enum Format {
    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : interval >= 3_600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(interval, 60)) ?? ""
    }

    static func longDuration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = interval >= 86_400 ? [.day] : [.hour]
        return formatter.string(from: interval) ?? ""
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func hex(_ value: Int) -> String { String(format: "0x%04X", value) }
}

enum Palette {
    static func battery(_ percent: Int?) -> Color {
        guard let percent else { return .secondary }
        return percent <= 10 ? .red : percent <= 20 ? .orange : .green
    }

    static let typing = Color.blue
}

/// Rounded fill used for every card, like Control Center modules.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CardTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

/// A fixed-shape stat: label on top, one big value, one quiet caption. Every tile is the same height.
struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    let caption: String
    var isHighlighted = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                        .frame(width: 12)
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct BatteryRing: View {
    let percent: Int?
    var isCharging = false

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(Palette.battery(percent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: percent)
            if isCharging {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.green)
            } else {
                Text(percent.map { "\($0)" } ?? "–")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

/// Smooth line over a soft gradient. Hovering marks the nearest point and reports it through `hovered`.
struct SparkChart: View {
    struct Point: Identifiable, Equatable {
        let x: Date
        let y: Double
        var id: Date { x }
    }

    let points: [Point]
    let color: Color
    var yDomain: ClosedRange<Double>?
    var xDomain: ClosedRange<Date>?
    var interpolation: InterpolationMethod = .monotone
    var hovered: Binding<Point?>?
    /// What hovering snaps to, when it differs from the drawn points (e.g. every reading under a simplified line).
    var hoverTargets: [Point]?
    /// A faint dashed line for context, e.g. the day's average.
    var reference: Double?
    var showsDots = false

    var body: some View {
        let top = yDomain?.upperBound ?? max((points.map(\.y) + [reference ?? 0]).max()! * 1.15, 1)
        let selection = hovered?.wrappedValue
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.x), yStart: .value("Base", yDomain?.lowerBound ?? 0), yEnd: .value("Value", point.y))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(.linearGradient(colors: [color.opacity(0.32), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.x), y: .value("Value", point.y))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if showsDots {
                    PointMark(x: .value("Time", point.x), y: .value("Value", point.y))
                        .foregroundStyle(color)
                        .symbolSize(14)
                }
            }
            if let reference {
                RuleMark(y: .value("Reference", reference))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let selection {
                RuleMark(x: .value("Time", selection.x))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", selection.x), y: .value("Value", selection.y))
                    .foregroundStyle(color)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: (yDomain?.lowerBound ?? 0)...top)
        .chartXScale(domain: xDomain ?? ((points.first?.x ?? .now)...(points.last?.x ?? .now)))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            if let hovered {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let date: Date = proxy.value(atX: location.x) else { return }
                            hovered.wrappedValue = (hoverTargets ?? points).min { abs($0.x.timeIntervalSince(date)) < abs($1.x.timeIntervalSince(date)) }
                        case .ended:
                            hovered.wrappedValue = nil
                        }
                    }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                MiniSwitch(isOn: isOn)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Drawn in SwiftUI (not an AppKit switch) so it matches the cards and renders in snapshots.
struct MiniSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            .frame(width: 26, height: 15)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(1.5)
            }
            .animation(.snappy(duration: 0.18), value: isOn)
    }
}

struct LevelBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 6)
            .animation(.smooth, value: fraction)
    }
}

/// Plain full-width row like a native menu item, highlighted on hover.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @ViewState private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

enum ChartRange: CaseIterable {
    case today, week, month

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    var label: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .week: "7D"
        case .month: "30D"
        }
    }
}

/// A compact segmented control drawn in SwiftUI so it matches the cards.
struct RangePicker: View {
    @Binding var selection: ChartRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases, id: \.self) { range in
                Button { selection = range } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(selection == range ? .primary : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(selection == range ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .animation(.snappy(duration: 0.15), value: selection)
    }
}
