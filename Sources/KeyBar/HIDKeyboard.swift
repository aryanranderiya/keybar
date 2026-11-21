import Foundation
import IOKit.hid

/// Static facts the keyboard's HID interface reports about itself.
struct HIDDeviceInfo: Equatable {
    var name: String
    var address: String
    var vendorID: Int
    var productID: Int
    var manufacturer: String
    var reportIntervalMicros: Int
    var hidVersion: Int
    var hasBatteryReport: Bool
}

enum HIDEvent {
    case attached(HIDDeviceInfo)
    case removed
    case battery(Int)
    case keyDown(usage: UInt32)
}

/// Watches Bluetooth HID keyboards whose product name contains "Keychron" and streams their events.
final class HIDKeyboardWatcher {
    private enum Usage {
        static let genericDevicePage: UInt32 = 0x06
        static let batteryStrength: UInt32 = 0x20
        static let keyboardPage: UInt32 = 0x07
        static let firstKey: UInt32 = 0x04
        static let lastNonModifierKey: UInt32 = 0xA4
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var isOpen = false
    private let onEvent: (HIDEvent) -> Void

    init(onEvent: @escaping (HIDEvent) -> Void) {
        self.onEvent = onEvent
        let matching: [String: Any] = [
            kIOHIDTransportKey: "Bluetooth",
            kIOHIDPrimaryUsagePageKey: 0x01,
            kIOHIDPrimaryUsageKey: 0x06,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDKeyboardWatcher>.fromOpaque(ctx).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDKeyboardWatcher>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    static var hasInputMonitoringAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestInputMonitoringAccess() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Opens the device for input once access is granted; safe to call repeatedly.
    func openIfPossible() {
        guard let device, !isOpen, Self.hasInputMonitoringAccess else { return }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        isOpen = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<HIDKeyboardWatcher>.fromOpaque(ctx).takeUnretainedValue().valueReceived(value)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        pollBattery()
    }

    /// Asks the keyboard for its current battery report instead of waiting for it to push one.
    func pollBattery() {
        guard let device, isOpen, let element = batteryElement(of: device) else { return }
        let reportID = IOHIDElementGetReportID(element)
        let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        var report = [UInt8](repeating: 0, count: max(size, 2))
        report[0] = UInt8(reportID)
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(reportID), &report, &length)
        guard result == kIOReturnSuccess else { return }
        let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
        var value = Unmanaged.passUnretained(placeholder)
        if IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess,
           (1...100).contains(IOHIDValueGetIntegerValue(value.takeUnretainedValue())) {
            emitBattery(IOHIDValueGetIntegerValue(value.takeUnretainedValue()))
        } else if length >= 2 {
            // Keychron's battery report is [reportID, percent]; read it directly if the element cache is stale.
            emitBattery(Int(report[1]))
        }
    }

    private func batteryElement(of device: IOHIDDevice) -> IOHIDElement? {
        let matching: [String: Any] = [
            kIOHIDElementUsagePageKey: Usage.genericDevicePage,
            kIOHIDElementUsageKey: Usage.batteryStrength,
        ]
        let elements = IOHIDDeviceCopyMatchingElements(device, matching as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone))
        return (elements as? [IOHIDElement])?.first
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        let name = stringProperty(device, kIOHIDProductKey)
        guard name.localizedCaseInsensitiveContains("keychron") else { return }
        self.device = device
        isOpen = false
        onEvent(.attached(info(for: device, name: name)))
        openIfPossible()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard device == self.device else { return }
        self.device = nil
        isOpen = false
        onEvent(.removed)
    }

    private func valueReceived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integer = IOHIDValueGetIntegerValue(value)
        if page == Usage.genericDevicePage, usage == Usage.batteryStrength {
            emitBattery(integer)
        } else if page == Usage.keyboardPage, integer == 1,
                  (Usage.firstKey...Usage.lastNonModifierKey).contains(usage) {
            onEvent(.keyDown(usage: usage))
        }
    }

    private func emitBattery(_ raw: Int) {
        // A zero report arrives before the keyboard has measured; treat it as "no reading yet".
        guard (1...100).contains(raw) else { return }
        onEvent(.battery(raw))
    }

    private func info(for device: IOHIDDevice, name: String) -> HIDDeviceInfo {
        HIDDeviceInfo(
            name: name,
            address: stringProperty(device, kIOHIDSerialNumberKey),
            vendorID: intProperty(device, kIOHIDVendorIDKey),
            productID: intProperty(device, kIOHIDProductIDKey),
            manufacturer: stringProperty(device, kIOHIDManufacturerKey),
            reportIntervalMicros: intProperty(device, kIOHIDReportIntervalKey),
            hidVersion: intProperty(device, kIOHIDVersionNumberKey),
            hasBatteryReport: reportDescriptorDeclaresBattery(device)
        )
    }

    /// True when the descriptor declares Usage Page (Generic Device) + Usage (Battery Strength).
    /// Readable before Input Monitoring is granted, when elements cannot be enumerated yet.
    private func reportDescriptorDeclaresBattery(_ device: IOHIDDevice) -> Bool {
        guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            return false
        }
        return descriptor.range(of: Data([0x05, 0x06, 0x09, 0x20])) != nil
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? ""
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
    }
}
