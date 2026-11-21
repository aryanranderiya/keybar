import Foundation

/// One finished (or in-progress) day of typing, reduced to totals.
struct DaySummary: Codable, Identifiable, Equatable {
    let day: String
    let keys: Int
    let characters: Int
    let corrections: Int
    let activeSeconds: TimeInterval
    let peakWPM: Int?

    var id: String { day }

    var date: Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    var averageWPM: Int? {
        guard activeSeconds >= 60 else { return nil }
        return Int((Double(characters) / TypingStats.charactersPerWord / (activeSeconds / 60)).rounded())
    }

    /// Share of keystrokes that were Backspace.
    var correctionRate: Double? {
        let total = characters + corrections
        return total >= 50 ? Double(corrections) / Double(total) : nil
    }
}

/// Past days, kept for 90 days so the chart can show weeks and months.
struct TypingHistory {
    private static let storageKey = "typingHistory"
    private static let retainedDays = 90

    private(set) var days: [DaySummary]

    init() {
        days = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([DaySummary].self, from: $0) } ?? []
    }

    mutating func archive(_ summary: DaySummary) {
        guard summary.keys > 0 else { return }
        days.removeAll { $0.day == summary.day }
        days.append(summary)
        days.sort { $0.day < $1.day }
        days = Array(days.suffix(Self.retainedDays))
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
