import AppKit
import Carbon
import IOBluetooth
import Observation
import ServiceManagement
import UserNotifications

enum ConnectionState: Equatable {
    case connected
    /// The keyboard's own idle timer dropped the link; a keypress brings it back.
    case asleep(since: Date)
    /// Switched off, out of range, or on another device. The Mac can't tell these apart.
    case disconnected(lastSeen: Date?)
    case notPaired
}

@MainActor
@Observable
final class KeyboardMonitor {
    /// Keychron K-series boards sleep after 10 minutes without a keypress in Bluetooth mode.
    /// Other keyboards don't publish their timeout, so the countdown is Keychron-only.
    static let autoSleepAfter: TimeInterval = 10 * 60
    /// A link that drops this close to the idle timeout (or later) is the keyboard going to sleep.
    private static let sleepDetectionSlack: TimeInterval = 60
    /// A keyboard that has been asleep this long is more likely off or flat than napping.
    private static let asleepExpiry: TimeInterval = 12 * 3_600
    /// Coming back within this long continues the session instead of starting a new one.
    private static let sessionGrace: TimeInterval = 30 * 60
    /// After the Mac wakes, a link drop reported this soon really happened when the Mac went to sleep.
    private static let wakeSettleTime: TimeInterval = 60
    private static let batteryPollInterval: TimeInterval = 10 * 60
    private static let saveInterval: TimeInterval = 30
    private static let lowBatteryThresholds = [20, 10, 5]
    private static let alertResetLevel = 30
    /// Nudge to charge once the estimate says the battery runs out within this long.
    private static let chargeReminderLead: TimeInterval = 2 * 86_400

    // Connection and battery: change rarely, published as they happen.
    private(set) var connection: ConnectionState = .notPaired
    private(set) var info: HIDDeviceInfo?
    private(set) var pairedName: String?
    private(set) var battery: Int?
    private(set) var batteryUpdated: Date?
    private(set) var history = BatteryHistory()
    private(set) var firmware: String?
    private(set) var hasAccess = HIDKeyboardWatcher.hasInputMonitoringAccess
    private(set) var sessionStart: Date?
    private(set) var isTogglingLink = false

    // Live view state: refreshed once a second, only while the popover is open.
    private(set) var now = Date.now
    private(set) var snapshot = TypingSnapshot()
    private(set) var capsLockOn = false
    private(set) var fnKeysAreStandard = false
    private(set) var inputSource = ""

    var showsPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showsPercentInMenuBar, forKey: Keys.showPercent) }
    }
    var lowBatteryAlerts: Bool {
        didSet {
            UserDefaults.standard.set(lowBatteryAlerts, forKey: Keys.alerts)
            if lowBatteryAlerts { requestNotificationPermission() }
        }
    }
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("KeyBar: launch at login change failed: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private enum Keys {
        static let showPercent = "showPercentInMenuBar"
        static let alerts = "lowBatteryAlerts"
        static let lastAddress = "lastAddress"
        static let lastSeen = "lastSeen"
        static let lastSeenAsleep = "lastSeenAsleep"
        static let awakeSeconds = "awakeSeconds"
        static let lastAlert = "lastAlertThreshold"
        static let chargeReminderSent = "chargeReminderSent"
        static func firmware(_ address: String) -> String { "firmware-\(address)" }
    }

    // Keystrokes land here without touching observed state, so typing never re-renders anything.
    @ObservationIgnored private var typing = TypingStats(for: .now)
    @ObservationIgnored private var typingHistory = TypingHistory()
    @ObservationIgnored private var typingDirty = false
    @ObservationIgnored private var keysThisSession = 0
    @ObservationIgnored private var lastKeyAt: Date?
    @ObservationIgnored private var linkUpAt: Date?
    @ObservationIgnored private var linkLostAt: Date?
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private var macSleptAt: Date?
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var awakeSeconds = UserDefaults.standard.double(forKey: Keys.awakeSeconds)
    @ObservationIgnored private var awakeCountedTo: Date?
    @ObservationIgnored private var watcher: HIDKeyboardWatcher?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var timers: [Timer] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.showPercent: true, Keys.alerts: true])
        showsPercentInMenuBar = defaults.bool(forKey: Keys.showPercent)
        lowBatteryAlerts = defaults.bool(forKey: Keys.alerts)
        battery = history.samples.last?.percent
        if let stored = TypingStats.stored() {
            if stored.isSameDay(as: .now) { typing = stored } else { typingHistory.archive(stored.summary) }
        }
        batteryUpdated = history.samples.last?.date

        watcher = HIDKeyboardWatcher { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        refreshPairing()
        timers = [
            repeating(Self.batteryPollInterval) {
                $0.watcher?.pollBattery()
                $0.expireSleep()
            },
            repeating(Self.saveInterval) { $0.saveTyping() },
            // Picks up a permission granted in System Settings without a relaunch.
            repeating(2) { $0.checkAccess() },
        ]
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveTyping()
                self?.countAwake(until: .now)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macSleptAt = .now }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeSettleTime) {
                    MainActor.assumeIsolated { self?.macSleptAt = nil }
                }
            }
        }
        if lowBatteryAlerts { requestNotificationPermission() }
    }

    // MARK: Derived

    var displayName: String { info?.name ?? pairedName ?? "Keyboard" }
    var isKeychron: Bool { displayName.localizedCaseInsensitiveContains("keychron") }
    var isConnected: Bool { connection == .connected }
    var isAsleep: Bool { if case .asleep = connection { true } else { false } }
    var supportsBattery: Bool { info?.hasBatteryReport ?? true }
    var trend: BatteryTrend { history.trend }

    var pollingRateHz: Int? {
        guard let micros = info?.reportIntervalMicros, micros > 0 else { return nil }
        return 1_000_000 / micros
    }

    /// Seconds until the keyboard's own idle timer puts it to sleep, once we have seen a keypress.
    var sleepCountdown: TimeInterval? {
        guard isConnected, isKeychron, let lastKey = snapshot.lastKey else { return nil }
        return max(0, Self.autoSleepAfter - now.timeIntervalSince(lastKey))
    }

    // MARK: Popover lifecycle

    func popoverDidAppear() {
        tick()
        refreshPairing()
        ticker = repeating(1) { $0.tick() }
    }

    func popoverDidDisappear() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Stands in a connection state for `--snapshot`, so each one can be rendered on demand.
    func preview(_ state: ConnectionState) {
        isPreview = true
        connection = state
    }

    // MARK: Actions

    func requestAccess() {
        HIDKeyboardWatcher.requestInputMonitoringAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func toggleConnection() {
        guard let device = BluetoothLink.pairedKeyboard(preferring: info?.address ?? lastAddress) else { return }
        isTogglingLink = true
        Task { @MainActor in
            if device.isConnected() {
                userDisconnected = true
                device.closeConnection()
            } else {
                device.openConnection()
            }
            try? await Task.sleep(for: .seconds(2))
            isTogglingLink = false
            refreshPairing()
        }
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    // MARK: Events

    private func handle(_ event: HIDEvent) {
        switch event {
        case .attached(let info):
            self.info = info
            connection = .connected
            let resumes = sessionStart != nil && linkLostAt.map { Date.now.timeIntervalSince($0) <= Self.sessionGrace } == true
            if !resumes {
                sessionStart = .now
                keysThisSession = 0
            }
            linkUpAt = .now
            awakeCountedTo = .now
            linkLostAt = nil
            userDisconnected = false
            macSleptAt = nil
            UserDefaults.standard.set(info.address, forKey: Keys.lastAddress)
            refreshPairing()
            loadFirmware(address: info.address)
        case .removed:
            // A drop the Mac slept through is reported on wake; the link really went when the Mac did.
            let lostAt = macSleptAt ?? .now
            UserDefaults.standard.set(lostAt, forKey: Keys.lastSeen)
            linkLostAt = lostAt
            countAwake(until: lostAt)
            awakeCountedTo = nil
            let asleep = wentToSleep(at: lostAt)
            UserDefaults.standard.set(asleep, forKey: Keys.lastSeenAsleep)
            connection = asleep ? .asleep(since: lostAt) : .disconnected(lastSeen: lostAt)
            userDisconnected = false
        case .battery(let percent):
            battery = percent
            batteryUpdated = .now
            countAwake(until: .now)
            history.record(percent, awake: awakeSeconds)
            evaluateLowBattery(percent)
        case .keyDown(let usage):
            rollOverIfNeeded(.now)
            typing.record(usage: usage, at: .now)
            typingDirty = true
            keysThisSession += 1
            lastKeyAt = .now
            if usage == KeyUsage.capsLock, ticker != nil { refreshSystemModes() }
        }
    }

    /// The keyboard sleeping looks like any other link drop, except for when it happens:
    /// after a full idle timeout with no keypress, or while the Mac itself was asleep.
    private func wentToSleep(at lostAt: Date) -> Bool {
        guard isKeychron, !userDisconnected else { return false }
        if macSleptAt != nil { return true }
        guard let idleSince = [lastKeyAt, linkUpAt].compactMap({ $0 }).max() else { return false }
        return lostAt.timeIntervalSince(idleSince) >= Self.autoSleepAfter - Self.sleepDetectionSlack
    }

    /// Adds the connected time since the last count to the running total.
    private func countAwake(until date: Date) {
        guard let from = awakeCountedTo else { return }
        awakeSeconds += max(0, date.timeIntervalSince(from))
        awakeCountedTo = date
        UserDefaults.standard.set(awakeSeconds, forKey: Keys.awakeSeconds)
    }

    private func expireSleep() {
        guard case .asleep(let since) = connection, Date.now.timeIntervalSince(since) > Self.asleepExpiry else { return }
        connection = .disconnected(lastSeen: since)
    }

    private func tick() {
        now = .now
        expireSleep()
        rollOverIfNeeded(now)
        snapshot = TypingSnapshot(stats: &typing, history: typingHistory, keysThisSession: keysThisSession, now: now)
        refreshSystemModes()
    }

    private func checkAccess() {
        guard !hasAccess, HIDKeyboardWatcher.hasInputMonitoringAccess else { return }
        hasAccess = true
        watcher?.openIfPossible()
    }

    /// At midnight, files the finished day into history and starts a new one.
    private func rollOverIfNeeded(_ date: Date) {
        guard !typing.isSameDay(as: date) else { return }
        typingHistory.archive(typing.summary)
        typing = TypingStats(for: date)
        typingDirty = true
    }

    private func saveTyping() {
        guard typingDirty else { return }
        typing.save()
        typingDirty = false
    }

    private func loadFirmware(address: String) {
        let key = Keys.firmware(address)
        firmware = UserDefaults.standard.string(forKey: key)
        Task {
            guard let fresh = await BluetoothLink.firmwareVersion(address: address) else { return }
            firmware = fresh
            UserDefaults.standard.set(fresh, forKey: key)
        }
    }

    private var lastAddress: String? { UserDefaults.standard.string(forKey: Keys.lastAddress) }

    private func refreshPairing() {
        guard !isPreview else { return }
        guard let device = BluetoothLink.pairedKeyboard(preferring: info?.address ?? lastAddress) else {
            if info == nil { connection = .notPaired }
            return
        }
        pairedName = device.name
        if info != nil { return }
        // Our own record of the link dropping comes first: macOS refreshes its access date on its own,
        // so it can read minutes old for a keyboard that has been off for hours.
        let lastSeen = (UserDefaults.standard.object(forKey: Keys.lastSeen) as? Date) ?? device.recentAccessDate()
        if device.isConnected() {
            connection = .connected
        } else if let lastSeen, UserDefaults.standard.bool(forKey: Keys.lastSeenAsleep) {
            // Relaunched while the keyboard was napping.
            connection = .asleep(since: lastSeen)
            expireSleep()
        } else {
            connection = .disconnected(lastSeen: lastSeen)
        }
    }

    private func refreshSystemModes() {
        capsLockOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        let fnState = CFPreferencesCopyAppValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication)
        fnKeysAreStandard = (fnState as? Bool) ?? false
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            inputSource = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
    }

    private func repeating(_ interval: TimeInterval, _ action: @escaping (KeyboardMonitor) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Low battery

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluateLowBattery(_ percent: Int) {
        let defaults = UserDefaults.standard
        if percent >= Self.alertResetLevel || trend == .charging {
            defaults.removeObject(forKey: Keys.lastAlert)
            defaults.removeObject(forKey: Keys.chargeReminderSent)
        }
        guard lowBatteryAlerts else { return }
        remindToChargeIfRunningOut(percent)
        let lastAlert = defaults.object(forKey: Keys.lastAlert) as? Int ?? Int.max
        guard percent < Self.alertResetLevel,
              let threshold = Self.lowBatteryThresholds.last(where: { percent <= $0 }),
              threshold < lastAlert else { return }
        defaults.set(threshold, forKey: Keys.lastAlert)
        notify(id: "low-battery-\(threshold)", title: "\(displayName) battery low",
               body: "\(percent)% left. Plug it in to keep typing wirelessly.")
    }

    /// Once per discharge: a heads-up a couple of days before the estimate says it runs out.
    private func remindToChargeIfRunningOut(_ percent: Int) {
        let defaults = UserDefaults.standard
        guard case .discharging(let remaining) = trend, remaining <= Self.chargeReminderLead,
              !defaults.bool(forKey: Keys.chargeReminderSent) else { return }
        defaults.set(true, forKey: Keys.chargeReminderSent)
        let runsOut = Date.now.addingTimeInterval(remaining)
        notify(id: "charge-reminder", title: "Charge \(displayName) soon",
               body: "\(percent)% left. At your usual pace it runs out around \(runsOut.formatted(.dateTime.weekday(.wide).hour())).")
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// What the popover shows about typing, captured once per tick.
struct TypingSnapshot {
    var liveWPM = 0
    var averageWPM: Int?
    var peakWPM: Int?
    var keysToday = 0
    var keysThisSession = 0
    var activeTime: TimeInterval = 0
    var correctionRate: Double?
    var lastKey: Date?
    var timeline: TypingStats.Timeline?
    /// Past days plus today, oldest first.
    var days: [DaySummary] = []

    init() {}

    init(stats: inout TypingStats, history: TypingHistory, keysThisSession: Int, now: Date) {
        days = history.days + (stats.keys > 0 ? [stats.summary] : [])
        liveWPM = stats.liveWPM(at: now)
        averageWPM = stats.averageWPM
        peakWPM = stats.peakWPM
        keysToday = stats.keys
        self.keysThisSession = keysThisSession
        activeTime = stats.activeSeconds
        correctionRate = stats.correctionRate
        lastKey = stats.lastKey
        timeline = stats.timeline(endingAt: now)
    }
}
