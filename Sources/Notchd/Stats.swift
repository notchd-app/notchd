import Darwin
import IOKit
import SwiftUI

struct SystemStats: Equatable {
    var cpu: Double = 0          // 0...1
    var gpu: Double?             // 0...1, nil when unavailable
    var memoryUsed: Double = 0   // bytes
    var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var download: Double = 0     // bytes per second
    var upload: Double = 0
    var diskFree: Double = 0     // bytes
    var diskTotal: Double = 0

    var memory: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }
    var disk: Double { diskTotal > 0 ? 1 - diskFree / diskTotal : 0 }
}

/// Samples CPU, GPU, memory, network and disk every two seconds while the System widget is in the notch.
@Observable
final class StatsMonitor {
    static let shared = StatsMonitor()
    private(set) var stats = SystemStats()
    /// Last minute of samples, oldest first, for the sparklines.
    private(set) var cpuHistory: [Double] = []
    private(set) var networkHistory: [Double] = []

    private var timer: Timer?
    private var lastTicks: [UInt64]?
    private var lastBytes: (down: UInt64, up: UInt64, at: Date)?
    private static let historyLength = 30

    func apply() {
        let wanted = Settings.shared.prefs.widgets.contains { $0.kind == .stats && $0.enabled }
        if wanted, timer == nil {
            sample()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func sample() {
        var next = stats
        if let cpu = cpuUsage() { next.cpu = cpu }
        next.gpu = Self.gpuUsage()
        next.memoryUsed = Self.memoryUsed()
        if let (down, up) = networkRates() {
            next.download = down
            next.upload = up
        }
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            next.diskFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            next.diskTotal = Double(values.volumeTotalCapacity ?? 0)
        }
        stats = next
        cpuHistory = Array((cpuHistory + [next.cpu]).suffix(Self.historyLength))
        networkHistory = Array((networkHistory + [next.download + next.upload]).suffix(Self.historyLength))
    }

    /// Share of non-idle ticks across all cores since the last sample.
    private func cpuUsage() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var ticks = [UInt64](repeating: 0, count: 2)  // busy, total
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks[0] += user + system + nice
            ticks[1] += user + system + nice + idle
        }
        defer { lastTicks = ticks }
        guard let last = lastTicks, ticks[1] > last[1], ticks[0] >= last[0] else { return nil }  // counters can reset
        return Double(ticks[0] - last[0]) / Double(ticks[1] - last[1])
    }

    /// Active + wired + compressed pages, the figure Activity Monitor calls "Memory Used" (roughly).
    static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let anonymous = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (anonymous + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    /// The GPU's own utilization, published by its IOAccelerator driver.
    static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let performance = dict["PerformanceStatistics"] as? [String: Any],
               let utilization = performance["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(utilization) / 100)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    /// Bytes per second in and out over physical interfaces. Uses the 64-bit counters (the 32-bit ones
    /// wrap every 4 GB) and skips loopback and tunnels, which would count VPN traffic twice.
    private func networkRates() -> (Double, Double)? {
        guard let (down, up) = Self.interfaceBytes() else { return nil }
        let now = Date()
        defer { lastBytes = (down, up, now) }
        guard let last = lastBytes, down >= last.down, up >= last.up else { return nil }
        let seconds = max(now.timeIntervalSince(last.at), 0.5)
        return (Double(down - last.down) / seconds, Double(up - last.up) / seconds)
    }

    private static let skippedInterfaces = ["lo", "utun", "ipsec", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap"]

    static func interfaceBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        var down: UInt64 = 0, up: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.load(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        if !skippedInterfaces.contains(where: interface.hasPrefix) {
                            down += message.ifm_data.ifi_ibytes
                            up += message.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (down, up)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

// MARK: - Widget

struct StatsWidget: View {
    private var monitor = StatsMonitor.shared

    var body: some View {
        let stats = monitor.stats
        GeometryReader { geo in
            let wide = geo.size.width > 200
            VStack(alignment: .leading, spacing: 5) {
                row("cpu", "CPU", value: stats.cpu, text: Self.percent(stats.cpu),
                    history: wide ? monitor.cpuHistory : nil, color: .blue)
                if let gpu = stats.gpu {
                    row("cube.transparent", "GPU", value: gpu, text: Self.percent(gpu), color: .purple)
                }
                row("memorychip", "Memory", value: stats.memory,
                    text: wide ? "\(StatsMonitor.bytes(stats.memoryUsed)) / \(StatsMonitor.bytes(stats.memoryTotal))"
                               : Self.percent(stats.memory),
                    color: stats.memory > 0.85 ? .orange : .green)
                row("internaldrive", "Disk", value: stats.disk,
                    text: wide ? String(localized: "\(StatsMonitor.bytes(stats.diskFree)) free") : Self.percent(stats.disk),
                    color: stats.disk > 0.9 ? .orange : .teal)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 14)
                    Text("↓ \(StatsMonitor.rate(stats.download))").lineLimit(1)
                    Text("↑ \(StatsMonitor.rate(stats.upload))").lineLimit(1).foregroundStyle(.secondary)
                    if wide {
                        Sparkline(values: monitor.networkHistory, color: .cyan).frame(height: 12)
                    }
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
        .help(Text("Open Activity Monitor"))
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func row(_ icon: String, _ title: LocalizedStringKey, value: Double, text: String,
                     history: [Double]? = nil, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 14)
            Text(title).frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
            if let history {
                Sparkline(values: history, color: color, maximum: 1).frame(height: 12)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(color.gradient).frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
                    }
                }
                .frame(height: 5)
            }
            Text(text).lineLimit(1).frame(minWidth: 34, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: value)
    }
}

/// A small filled line chart, scaled to its largest value (or a fixed maximum).
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var maximum: Double?

    var body: some View {
        GeometryReader { geo in
            let top = maximum ?? max(values.max() ?? 1, 1)
            let points = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? geo.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                        y: geo.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                }
                .fill(color.opacity(0.25))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }
}
