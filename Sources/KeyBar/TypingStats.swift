import Foundation

/// Today's typing activity. Stores counts and timing only, never which keys were pressed.
struct TypingStats: Codable {
    struct Bucket: Codable {
        var characters = 0
        var activeSeconds: TimeInterval = 0
    }

    struct Point: Identifiable {
        let date: Date
        let wpm: Double
        var id: Date { date }
    }

    /// Gaps longer than this are pauses, not typing time.
    static let pauseThreshold: TimeInterval = 5
    static let bucketLength: TimeInterval = 60
    private static let charactersPerWord = 5.0
    private static let liveWindow: TimeInterval = 30
    private static let minimumLiveSpan: TimeInterval = 8
    private static let minimumCharacters = 20
    /// A peak must be sustained, not a few seconds of fast typing.
    private static let minimumPeakSeconds: TimeInterval = 30
    private static let storageKey = "typingStats.v2"

    private(set) var day: String
    private(set) var keys = 0
    private(set) var characters = 0
    private(set) var corrections = 0
    private(set) var activeSeconds: TimeInterval = 0
    private(set) var buckets: [Int: Bucket] = [:]
    private(set) var lastKey: Date?
    private var recentCharacters: [Date] = []

    private enum CodingKeys: String, CodingKey {
        case day, keys, characters, corrections, activeSeconds, buckets
    }

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(TypingStats.self, from: $0) }
        let today = Self.dayStamp(.now)
        self = stored?.day == today ? stored! : TypingStats(day: today)
    }

    private init(day: String) { self.day = day }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    mutating func record(usage: UInt32, at date: Date) {
        let stamp = Self.dayStamp(date)
        if stamp != day { self = TypingStats(day: stamp) }
        let bucket = Self.bucketIndex(date)
        if let lastKey, date.timeIntervalSince(lastKey) < Self.pauseThreshold {
            let gap = date.timeIntervalSince(lastKey)
            activeSeconds += gap
            buckets[bucket, default: Bucket()].activeSeconds += gap
        }
        lastKey = date
        keys += 1
        if usage == KeyUsage.backspace {
            corrections += 1
        } else if KeyUsage.isCharacter(usage) {
            characters += 1
            buckets[bucket, default: Bucket()].characters += 1
            recentCharacters.append(date)
        }
    }

    /// Speed over the last 30 seconds of typing, measured the same way as the chart and average:
    /// characters per minute of typing time. Reads zero a few seconds after you stop.
    mutating func liveWPM(at now: Date) -> Int {
        recentCharacters.removeAll { now.timeIntervalSince($0) > Self.liveWindow }
        guard let last = recentCharacters.last, now.timeIntervalSince(last) < Self.pauseThreshold,
              recentCharacters.count >= 5 else { return 0 }
        let typingTime = zip(recentCharacters, recentCharacters.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 < Self.pauseThreshold }
            .reduce(0, +)
        let minutes = max(typingTime, Self.minimumLiveSpan) / 60
        return Int((Double(recentCharacters.count) / Self.charactersPerWord / minutes).rounded())
    }

    var averageWPM: Int? {
        guard activeSeconds >= 60 else { return nil }
        return Int((Double(characters) / Self.charactersPerWord / (activeSeconds / 60)).rounded())
    }

    var peakWPM: Int? {
        buckets.values
            .filter { $0.activeSeconds >= Self.minimumPeakSeconds }
            .compactMap(Self.wpm).max().map { Int($0.rounded()) }
    }

    /// Share of keystrokes that were Backspace.
    var correctionRate: Double? {
        let total = characters + corrections
        return total >= 50 ? Double(corrections) / Double(total) : nil
    }

    /// One point per minute, quiet minutes reading zero. Spans from the first typing in the
    /// window (at least `minimumSpan` back) until now.
    func chart(endingAt now: Date, span: TimeInterval, minimumSpan: TimeInterval) -> [Point] {
        let end = Self.bucketIndex(now)
        let windowStart = Self.bucketIndex(now.addingTimeInterval(-span))
        guard let firstTyped = buckets.keys.filter({ $0 >= windowStart }).min() else { return [] }
        let first = max(windowStart, min(firstTyped, end - Int(minimumSpan / Self.bucketLength)))
        let midnight = Calendar.current.startOfDay(for: now)
        return (first...end).map { index in
            Point(date: midnight.addingTimeInterval(Double(index) * Self.bucketLength),
                  wpm: buckets[index].flatMap(Self.wpm) ?? 0)
        }
    }

    private static func wpm(_ bucket: Bucket) -> Double? {
        guard bucket.characters >= minimumCharacters else { return nil }
        return Double(bucket.characters) / charactersPerWord / (max(bucket.activeSeconds, 15) / 60)
    }

    private static func bucketIndex(_ date: Date) -> Int {
        Int(date.timeIntervalSince(Calendar.current.startOfDay(for: date)) / bucketLength)
    }

    private static func dayStamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}

/// HID keyboard-page usages (USB HID Usage Tables, page 0x07).
enum KeyUsage {
    static let backspace: UInt32 = 0x2A
    static let capsLock: UInt32 = 0x39
    private static let letterAndDigitRange: ClosedRange<UInt32> = 0x04...0x27
    private static let enter: UInt32 = 0x28
    private static let space: UInt32 = 0x2C
    private static let punctuationRange: ClosedRange<UInt32> = 0x2D...0x38

    static func isCharacter(_ usage: UInt32) -> Bool {
        letterAndDigitRange.contains(usage) || punctuationRange.contains(usage) || usage == enter || usage == space
    }
}
