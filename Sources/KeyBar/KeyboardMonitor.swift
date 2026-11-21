import AppKit
import Carbon
import IOBluetooth
import Observation
import ServiceManagement
import UserNotifications

enum ConnectionState: Equatable {
    case connected
    case disconnected(lastSeen: Date?)
    case notPaired
}

@MainActor
@Observable
final class KeyboardMonitor {
    /// Keychron K-series boards sleep after 10 minutes without a keypress in Bluetooth mode.
    static let autoSleepAfter: TimeInterval = 10 * 60
    private static let batteryPollInterval: TimeInterval = 10 * 60
    private static let saveInterval: TimeInterval = 30
    private static let lowBatteryThresholds = [20, 10, 5]
    private static let alertResetLevel = 30

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
        static let lastAlert = "lastAlertThreshold"
        static func firmware(_ address: String) -> String { "firmware-\(address)" }
    }

    // Keystrokes land here without touching observed state, so typing never re-renders anything.
    @ObservationIgnored private var typing = TypingStats(for: .now)
    @ObservationIgnored private var typingHistory = TypingHistory()
    @ObservationIgnored private var typingDirty = false
    @ObservationIgnored private var keysThisSession = 0
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
            repeating(Self.batteryPollInterval) { $0.watcher?.pollBattery() },
            repeating(Self.saveInterval) { $0.saveTyping() },
            // Picks up a permission granted in System Settings without a relaunch.
            repeating(2) { $0.checkAccess() },
        ]
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTyping() }
        }
        if lowBatteryAlerts { requestNotificationPermission() }
    }

    // MARK: Derived

    var displayName: String { info?.name ?? pairedName ?? "Keychron" }
    var isConnected: Bool { connection == .connected }
    var supportsBattery: Bool { info?.hasBatteryReport ?? true }
    var trend: BatteryTrend { history.trend }

    var pollingRateHz: Int? {
        guard let micros = info?.reportIntervalMicros, micros > 0 else { return nil }
        return 1_000_000 / micros
    }

    /// Seconds until the keyboard's own idle timer puts it to sleep, once we have seen a keypress.
    var sleepCountdown: TimeInterval? {
        guard isConnected, let lastKey = snapshot.lastKey else { return nil }
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

    // MARK: Actions

    func requestAccess() {
        HIDKeyboardWatcher.requestInputMonitoringAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func toggleConnection() {
        guard let device = BluetoothLink.pairedKeychron(preferring: info?.address ?? lastAddress) else { return }
        isTogglingLink = true
        Task { @MainActor in
            if device.isConnected() { device.closeConnection() } else { device.openConnection() }
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
            sessionStart = .now
            keysThisSession = 0
            UserDefaults.standard.set(info.address, forKey: Keys.lastAddress)
            refreshPairing()
            loadFirmware(address: info.address)
        case .removed:
            UserDefaults.standard.set(Date.now, forKey: Keys.lastSeen)
            connection = .disconnected(lastSeen: .now)
            sessionStart = nil
        case .battery(let percent):
            battery = percent
            batteryUpdated = .now
            history.record(percent)
            evaluateLowBattery(percent)
        case .keyDown(let usage):
            rollOverIfNeeded(.now)
            typing.record(usage: usage, at: .now)
            typingDirty = true
            keysThisSession += 1
            if usage == KeyUsage.capsLock, ticker != nil { refreshSystemModes() }
        }
    }

    private func tick() {
        now = .now
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
        guard let device = BluetoothLink.pairedKeychron(preferring: info?.address ?? lastAddress) else {
            if info == nil { connection = .notPaired }
            return
        }
        pairedName = device.name
        if info != nil { return }
        let lastSeen = device.recentAccessDate() ?? (UserDefaults.standard.object(forKey: Keys.lastSeen) as? Date)
        connection = device.isConnected() ? .connected : .disconnected(lastSeen: lastSeen)
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
        let lastAlert = defaults.object(forKey: Keys.lastAlert) as? Int ?? Int.max
        if percent >= Self.alertResetLevel {
            defaults.removeObject(forKey: Keys.lastAlert)
            return
        }
        guard lowBatteryAlerts,
              let threshold = Self.lowBatteryThresholds.last(where: { percent <= $0 }),
              threshold < lastAlert else { return }
        defaults.set(threshold, forKey: Keys.lastAlert)
        let content = UNMutableNotificationContent()
        content.title = "\(displayName) battery low"
        content.body = "\(percent)% left. Plug in the USB-C cable to keep typing wirelessly."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "low-battery-\(threshold)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
