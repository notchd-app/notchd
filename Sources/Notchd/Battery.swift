import IOKit.ps
import SwiftUI

struct PowerReading: Equatable {
    var percent: Int
    var onAC: Bool
    var charged: Bool
}

enum BatteryState: Equatable {
    case plugged, unplugged, full, low
}

/// Flashes a live activity on power transitions (never on plain 1% changes).
final class BatteryMonitor {
    static let shared = BatteryMonitor()
    private var last: PowerReading?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            Unmanaged<BatteryMonitor>.fromOpaque(context!).takeUnretainedValue().update()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        update()
    }

    private func update() {
        guard let reading = Self.read() else { return }
        defer { last = reading }
        if let state = Self.event(from: last, to: reading, prefs: Settings.shared.prefs) {
            ActivityCenter.shared.show(.battery(percent: reading.percent, state: state))
        }
    }

    static func event(from old: PowerReading?, to new: PowerReading, prefs: Prefs) -> BatteryState? {
        guard let old else { return nil }  // first reading at launch: nothing changed yet
        if old.onAC != new.onAC {
            if new.onAC { return prefs.batteryShowPlugged ? .plugged : nil }
            return prefs.batteryShowUnplugged ? .unplugged : nil
        }
        if new.onAC, new.charged, !old.charged {
            return prefs.batteryShowFull ? .full : nil
        }
        let threshold = Int(prefs.batteryLowThreshold)
        if !new.onAC, new.percent <= threshold, old.percent > threshold {
            return prefs.batteryShowLow ? .low : nil
        }
        return nil
    }

    /// macOS's own estimate: minutes to full while charging, to empty on battery. nil while it's still computing.
    static func minutesRemaining() -> Int? {
        // Both can come back empty (around wake or logout, or on a Mac without a battery).
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = d[onAC ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            return minutes > 0 ? minutes : nil
        }
        return nil
    }

    static func read() -> PowerReading? {
        // Both can come back empty (around wake or logout, or on a Mac without a battery).
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let percent = capacity * 100 / max
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charged = d[kIOPSIsChargedKey] as? Bool ?? (onAC && percent >= 100)
            return PowerReading(percent: percent, onAC: onAC, charged: charged)
        }
        return nil
    }
}

struct BatteryActivityLeading: View {
    let percent: Int
    let state: BatteryState

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(batteryTint(state))
            .symbolEffect(.bounce, value: state)
    }

    private var icon: String {
        switch state {
        case .plugged: "bolt.fill"
        case .full: "battery.100percent.bolt"
        case .low: "battery.25percent"
        case .unplugged: "battery.\(min(100, (percent + 12) / 25 * 25))percent"
        }
    }
}

struct BatteryActivityTrailing: View {
    let percent: Int
    let state: BatteryState

    var body: some View {
        Text("\(percent)%")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(state == .unplugged && percent <= Int(Settings.shared.prefs.batteryLowThreshold)
                ? .red : batteryTint(state))
    }
}

private func batteryTint(_ state: BatteryState) -> Color {
    switch state {
    case .plugged, .full: .green
    case .low: .red
    case .unplugged: .white
    }
}
