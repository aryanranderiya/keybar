import Foundation
import IOBluetooth

/// The paired Bluetooth record for the keyboard: link control and firmware.
enum BluetoothLink {
    private static let peripheralMajorClass = UInt32(kBluetoothDeviceClassMajorPeripheral)
    /// Bit 4 of a peripheral's minor class marks a keyboard (Bluetooth Assigned Numbers, Class of Device).
    private static let keyboardMinorBit: UInt32 = 0x10

    static func pairedKeyboard(preferring address: String?) -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let keyboards = paired.filter {
            $0.deviceClassMajor == peripheralMajorClass && $0.deviceClassMinor & keyboardMinorBit != 0
        }
        if let address, let match = keyboards.first(where: { normalized($0.addressString) == normalized(address) }) {
            return match
        }
        return keyboards.first(where: { $0.isConnected() }) ?? keyboards.first
    }

    /// Firmware version as System Information reports it (the only public source for it).
    static func firmwareVersion(address: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["-json", "SPBluetoothDataType"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return firmware(in: data, address: address)
        }.value
    }

    private static func firmware(in data: Data, address: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for controller in controllers {
            for key in ["device_connected", "device_not_connected"] {
                for entry in (controller[key] as? [[String: Any]]) ?? [] {
                    for case let properties as [String: Any] in entry.values
                    where normalized(properties["device_address"] as? String) == normalized(address) {
                        return properties["device_firmwareVersion"] as? String
                    }
                }
            }
        }
        return nil
    }

    private static func normalized(_ address: String?) -> String {
        (address ?? "").uppercased().replacingOccurrences(of: "-", with: ":")
    }
}
