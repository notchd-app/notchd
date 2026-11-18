import CoreBluetooth
import IOBluetooth
import SwiftUI

struct BluetoothEvent: Equatable {
    var name: String
    var icon: String
    var connected: Bool
    var battery: Int?

    static let sample = BluetoothEvent(name: "AirPods Pro", icon: "airpodspro", connected: true, battery: 85)
}

/// Flashes a live activity when a Bluetooth device connects or disconnects.
final class BluetoothMonitor: NSObject, CBCentralManagerDelegate {
    static let shared = BluetoothMonitor()
    private var suppressUntil = Date.distantFuture
    private var registered = false
    /// Only exists to ask for Bluetooth access without blocking.
    private var permission: CBCentralManager?

    /// IOBluetooth waits on the main thread for the permission prompt to be answered, which froze the
    /// whole app (no notch at all) on first launch. So ask through CoreBluetooth, which doesn't block,
    /// and only touch IOBluetooth once access is granted.
    func start() {
        switch CBCentralManager.authorization {
        case .allowedAlways: register()
        case .notDetermined: permission = CBCentralManager(delegate: self, queue: .main)
        default: break  // denied or restricted: no Bluetooth activity
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBCentralManager.authorization != .notDetermined else { return }
        if CBCentralManager.authorization == .allowedAlways { register() }
        permission = nil
    }

    private func register() {
        guard !registered else { return }
        registered = true
        // Registering replays a connect notification for every already-connected device: ignore that burst.
        suppressUntil = Date().addingTimeInterval(3)
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        show(device, connected: true)
        // Headphones report their battery a moment after connecting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let battery = Self.battery(of: device),
                  case var .bluetooth(event)? = ActivityCenter.shared.flash,
                  event.connected, event.name == device.name, event.battery == nil else { return }
            event.battery = battery
            ActivityCenter.shared.show(.bluetooth(event))
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        show(device, connected: false)
    }

    private func show(_ device: IOBluetoothDevice, connected: Bool) {
        guard Date() > suppressUntil else { return }
        ActivityCenter.shared.show(.bluetooth(BluetoothEvent(
            name: device.name ?? L("Bluetooth device"),
            icon: Self.icon(for: device),
            connected: connected,
            battery: connected ? Self.battery(of: device) : nil
        )))
    }

    static func icon(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        switch (device.deviceClassMajor, device.deviceClassMinor) {
        case (0x04, _): return "headphones"
        case (0x05, let minor) where minor & 0x10 != 0: return "keyboard"
        case (0x05, let minor) where minor & 0x20 != 0: return "computermouse"
        case (0x05, _): return "gamecontroller"
        case (0x02, _): return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// Best effort: Apple headphones expose private battery keys on IOBluetoothDevice.
    static func battery(of device: IOBluetoothDevice) -> Int? {
        for key in ["batteryPercentCombined", "batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight"]
        where device.responds(to: NSSelectorFromString(key)) {
            if let value = device.value(forKey: key) as? Int, value > 0 { return value }
        }
        return nil
    }
}

struct BluetoothActivityLeading: View {
    let event: BluetoothEvent

    var body: some View {
        Image(systemName: event.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(event.connected ? .white : .secondary)
            .symbolEffect(.bounce, value: event.connected)
    }
}

struct BluetoothActivityTrailing: View {
    let event: BluetoothEvent

    var body: some View {
        Group {
            if !event.connected {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            } else if let battery = event.battery {
                Text("\(battery)%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(battery <= 20 ? .red : .green)
                    .contentTransition(.numericText(value: Double(battery)))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: event)
    }
}
