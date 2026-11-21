import Foundation

/// Today's typing activity. Stores counts and timing only, never which keys were pressed.
struct TypingStats: Codable {
    struct Bucket: Codable {
        var characters = 0
        var activeSeconds: TimeInterval = 0
    }

    struct Point: Identifiable {
        let start: Date
        let end: Date
        let wpm: Double
        var id: Date { start }
    }

    /// Today's speed, grouped so the whole day fits in a readable number of points.
    struct Timeline {
        let points: [Point]
        let minutesPerPoint: Int
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
    private static let pointResolutions = [1, 2, 5, 10, 15, 30, 60]
    private static let maximumPoints = 48
    private static let minimumTimelineMinutes = 10

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

    /// From your first typing today until now. The point size grows with the span (1 minute for
    /// a short session, up to an hour for a full day) so the line stays readable. Quiet stretches read zero.
    func timeline(endingAt now: Date) -> Timeline? {
        guard let firstTyped = buckets.keys.min() else { return nil }
        let end = Self.bucketIndex(now)
        let span = max(end - firstTyped + 1, Self.minimumTimelineMinutes)
        let size = Self.pointResolutions.first { span / $0 <= Self.maximumPoints } ?? Self.pointResolutions.last!
        // Align groups to the clock (:00, :05, :10) so hover ranges read naturally.
        let first = ((end - span + 1) / size) * size
        let midnight = Calendar.current.startOfDay(for: now)
        let points = stride(from: first, through: end, by: size).map { groupStart -> Point in
            let group = (groupStart..<groupStart + size).compactMap { buckets[$0] }
            let combined = Bucket(characters: group.map(\.characters).reduce(0, +),
                                  activeSeconds: group.map(\.activeSeconds).reduce(0, +))
            return Point(start: midnight.addingTimeInterval(Double(groupStart) * Self.bucketLength),
                         end: midnight.addingTimeInterval(Double(groupStart + size) * Self.bucketLength),
                         wpm: Self.wpm(combined) ?? 0)
        }
        return Timeline(points: points, minutesPerPoint: size)
    }

    private static func wpm(_ bucket: Bucket) -> Double? {
        guard bucket.characters >= minimumCharacters else { return nil }
        return Double(bucket.characters) / charactersPerWord / (max(bucket.activeSeconds, 15) / 60)
    }

    private static func bucketIndex(_ date: Date) -> Int {
        Int(date.timeIntervalSince(Calendar.current.startOfDay(for: date)) / bucketLength)
    }

    /// The local calendar day, so the stats roll over at your midnight.
    private static func dayStamp(_ date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
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
