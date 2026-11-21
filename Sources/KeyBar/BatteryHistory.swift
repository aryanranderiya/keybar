import Foundation

struct BatterySample: Codable, Equatable, Identifiable {
    var date: Date
    var percent: Int
    var id: Date { date }
}

enum BatteryTrend: Equatable {
    case unknown
    case charging
    case discharging(remaining: TimeInterval)
}

/// Persisted battery readings, used for the chart, charge detection and the time-left estimate.
struct BatteryHistory {
    private static let storageKey = "batteryHistory"
    private static let retention: TimeInterval = 14 * 86_400
    private static let heartbeat: TimeInterval = 30 * 60
    private static let minimumSpan: TimeInterval = 6 * 3_600
    private static let minimumDrop = 2
    private static let chargingWindow: TimeInterval = 3 * 3_600

    private(set) var samples: [BatterySample]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.storageKey)
        samples = data.flatMap { try? JSONDecoder().decode([BatterySample].self, from: $0) } ?? []
    }

    /// Stores a reading when the level changed or the last stored one is older than the heartbeat.
    mutating func record(_ percent: Int, at date: Date = .now) {
        if let last = samples.last, last.percent == percent, date.timeIntervalSince(last.date) < Self.heartbeat {
            return
        }
        samples.append(BatterySample(date: date, percent: percent))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.retention }
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var trend: BatteryTrend {
        guard let latest = samples.last else { return .unknown }
        let recentRise = samples.reversed()
            .prefix { latest.date.timeIntervalSince($0.date) <= Self.chargingWindow }
            .contains { $0.percent < latest.percent }
        if recentRise { return .charging }

        // Walk back over the current discharge: stop at the first point where the level was lower (a charge).
        var start = latest
        for sample in samples.reversed().dropFirst() {
            if sample.percent < start.percent { break }
            start = sample
        }
        let span = latest.date.timeIntervalSince(start.date)
        let drop = start.percent - latest.percent
        guard span >= Self.minimumSpan, drop >= Self.minimumDrop else { return .unknown }
        let secondsPerPercent = span / Double(drop)
        return .discharging(remaining: secondsPerPercent * Double(latest.percent))
    }

    func samples(since date: Date) -> [BatterySample] {
        samples.filter { $0.date >= date }
    }
}
