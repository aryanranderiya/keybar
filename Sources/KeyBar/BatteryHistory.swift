import Foundation

struct BatterySample: Codable, Equatable, Identifiable {
    var date: Date
    var percent: Int
    var id: Date { date }
}

/// How long one full charge lasted, measured from a real discharge.
struct ChargeLife: Equatable {
    let daysPerCharge: Double
    let measuredAt: Date
}

enum BatteryTrend: Equatable {
    case unknown
    case charging
    case discharging(remaining: TimeInterval)
}

/// Persisted battery readings, used for the chart, charge detection and the time-left estimate.
struct BatteryHistory {
    private static let storageKey = "batteryHistory"
    private static let retention: TimeInterval = 180 * 86_400
    private static let heartbeat: TimeInterval = 30 * 60
    private static let minimumSpan: TimeInterval = 6 * 3_600
    private static let minimumDrop = 2
    private static let chargingWindow: TimeInterval = 3 * 3_600
    /// A discharge counts toward battery health once it covers at least a day and 10%.
    private static let lifeMinimumSpan: TimeInterval = 86_400
    private static let lifeMinimumDrop = 10
    private static let chargeRise = 2
    /// A gap this long with the level unchanged means the keyboard sat switched off, not in use.
    private static let absenceGap: TimeInterval = 4 * 86_400
    private static let absenceDrop = 1

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

        // Walk back over the current discharge until a lower level (a charge). Keep the latest reading
        // at each level, so time spent resting at the top doesn't count as draining.
        var start = latest
        for sample in samples.reversed().dropFirst() {
            if sample.percent < start.percent { break }
            if sample.percent > start.percent { start = sample }
        }
        let span = timeInUse(from: start.date, to: latest.date)
        let drop = start.percent - latest.percent
        guard span >= Self.minimumSpan, drop >= Self.minimumDrop else { return .unknown }
        let secondsPerPercent = span / Double(drop)
        return .discharging(remaining: secondsPerPercent * Double(latest.percent))
    }

    /// Every discharge long enough to measure, oldest first, each scaled to a full 100%.
    /// A rise of 2% or more over the run's lowest reading is a charge; a 1% wobble is not.
    var chargeLives: [ChargeLife] {
        var lives: [ChargeLife] = []
        guard var start = samples.first else { return lives }
        var lowest = start
        for sample in samples.dropFirst() + [BatterySample(date: .distantFuture, percent: 200)] {
            if sample.percent >= lowest.percent + Self.chargeRise {
                let span = timeInUse(from: start.date, to: lowest.date)
                let drop = start.percent - lowest.percent
                if span >= Self.lifeMinimumSpan, drop >= Self.lifeMinimumDrop {
                    lives.append(ChargeLife(daysPerCharge: span / 86_400 * 100 / Double(drop), measuredAt: lowest.date))
                }
                start = sample
                lowest = sample
            } else if sample.percent >= start.percent, lowest.percent == start.percent {
                // Still charging, or resting at the top: the discharge starts from the last reading up there.
                start = sample
                lowest = sample
            } else if sample.percent <= lowest.percent {
                lowest = sample
            }
        }
        return lives
    }

    /// Time between two readings, leaving out stretches the keyboard spent switched off.
    /// Nights and weekends stay in: they are part of how long a charge lasts you.
    private func timeInUse(from start: Date, to end: Date) -> TimeInterval {
        let run = samples.filter { $0.date >= start && $0.date <= end }
        let absent = zip(run, run.dropFirst())
            .filter { $1.date.timeIntervalSince($0.date) >= Self.absenceGap && $0.percent - $1.percent <= Self.absenceDrop }
            .map { $1.date.timeIntervalSince($0.date) }
            .reduce(0, +)
        return end.timeIntervalSince(start) - absent
    }

    func samples(since date: Date) -> [BatterySample] {
        samples.filter { $0.date >= date }
    }
}
