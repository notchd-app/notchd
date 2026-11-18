import AppKit
import SwiftUI

struct TimerEntry: Codable, Identifiable, Equatable {
    enum State: String, Codable { case running, paused, expired }

    var id = UUID()
    var label: String?
    var total: Double
    var state = State.running
    var endsAt: Date?        // while running
    var remaining: Double    // while paused

    init(seconds: Double, label: String? = nil, now: Date = .now) {
        self.label = label
        total = seconds
        remaining = seconds
        endsAt = now.addingTimeInterval(seconds)
    }

    func remaining(at now: Date) -> Double {
        switch state {
        case .running: max(0, endsAt?.timeIntervalSince(now) ?? 0)
        case .paused: remaining
        case .expired: 0
        }
    }
}

/// Persisted timers. A run loop timer marks them expired, rings, and drives the "Timer Ended" activity.
@Observable
final class TimersStore {
    static let shared = TimersStore()
    private let file = URL.appSupport.appendingPathComponent("timers.json")

    var entries: [TimerEntry] = [] {
        didSet { try? JSONEncoder().encode(entries).write(to: file, options: .atomic) }
    }

    var hasExpired: Bool { entries.contains { $0.state == .expired } }
    /// Name of the ringing timer, if it has one.
    var expiredLabel: String? { entries.first { $0.state == .expired }?.label }

    init() {
        entries = Stored.load([TimerEntry].self, from: file) ?? []
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func start(seconds: Double, label: String? = nil) {
        guard seconds > 0 else { return }
        let label = label?.trimmingCharacters(in: .whitespaces)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
            entries.insert(TimerEntry(seconds: seconds, label: label?.isEmpty == false ? label : nil), at: 0)
        }
    }

    /// One-tap durations, in minutes.
    static let presets = [1, 5, 10, 25, 60]

    func togglePause(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            switch entries[i].state {
            case .running:
                entries[i].remaining = entries[i].remaining(at: now)
                entries[i].state = .paused
            case .paused:
                entries[i].endsAt = now.addingTimeInterval(entries[i].remaining)
                entries[i].state = .running
            case .expired:
                break
            }
        }
    }

    func remove(_ id: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { entries.removeAll { $0.id == id } }
    }

    /// Stops the ringing: expired timers go away.
    func dismissExpired() {
        withAnimation(.notchClose) { entries.removeAll { $0.state == .expired } }
    }

    private func tick() {
        let now = Date()
        var rang = false
        for i in entries.indices where entries[i].state == .running && entries[i].remaining(at: now) <= 0 {
            rang = true
            withAnimation(.notchOpen) { entries[i].state = .expired }
        }
        if rang {
            if Settings.shared.prefs.timerPlaySound { NSSound(named: "Glass")?.play() }
            Haptics.tap()
        }
    }

    static func format(_ seconds: Double, showSeconds: Bool) -> String {
        // A damaged timers file could hold a number too big to turn into whole seconds.
        let seconds = seconds.isFinite ? min(max(seconds, 0), 359_999) : 0
        let s = Int(seconds.rounded(.up))
        if !showSeconds {
            let m = Int((seconds / 60).rounded(.up))
            return m >= 60 ? String(format: "%dh%02d", m / 60, m % 60) : "\(m) min"
        }
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Wheels

/// Snapping scroll wheel with a tick on every value, faded at the edges.
struct WheelPicker: View {
    @Binding var value: Int
    let range: Range<Int>
    let unit: String
    @Local private var position: Int?

    private let rowHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 2) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(range, id: \.self) { n in
                        Text(String(format: "%02d", n))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(height: rowHeight)
                            .scaleEffect(n == value ? 1 : 0.8)
                            .opacity(n == value ? 1 : 0.45)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: value)
                            .id(n)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .contentMargins(.vertical, rowHeight, for: .scrollContent)
            .frame(width: 38, height: rowHeight * 3)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35),
                                         .init(color: .black, location: 0.65), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onAppear { position = value }
            .onChange(of: position) { _, new in
                guard let new, new != value else { return }
                value = new
                Haptics.tap()
            }
            Text(unit).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Nook widget

struct TimerWidget: View {
    @Bindable var model: NotchModel
    private var store = TimersStore.shared
    @Local private var hours = 0
    @Local private var minutes = 5
    @Local private var seconds = 0
    @Local private var label = ""
    @FocusState private var labelFocused: Bool

    init(model: NotchModel) { self.model = model }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack(spacing: 2) {
                    WheelPicker(value: $hours, range: 0..<24, unit: "h")
                    WheelPicker(value: $minutes, range: 0..<60, unit: "m")
                    WheelPicker(value: $seconds, range: 0..<60, unit: "s")
                }
                .background(alignment: .top) {
                    // Glassy focus pill behind the selected row.
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                        .frame(height: 28)
                        .offset(y: 25)
                }
                Button {
                    start(Double(hours * 3600 + minutes * 60 + seconds))
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(Pill().fill(.orange.opacity(0.85)))
                }
                .buttonStyle(BouncyButtonStyle())
                .disabled(hours + minutes + seconds == 0)
            }

            VStack(spacing: 6) {
                TextField("Name (optional)", text: $label)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Pill().fill(.white.opacity(0.08)))
                    .focused($labelFocused)
                    .onChange(of: labelFocused) { _, value in model.typing = value }
                HStack(spacing: 4) {
                    ForEach(TimersStore.presets, id: \.self) { minutes in
                        Button { start(Double(minutes * 60)) } label: {
                            Text(minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 2)
                                .frame(maxWidth: .infinity)
                                .frame(height: 20)
                                .background(Pill().fill(.white.opacity(0.1)))
                        }
                        .buttonStyle(BouncyButtonStyle())
                    }
                }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    if store.entries.isEmpty {
                        Text("No timers").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
                    }
                    ForEach(store.entries) { entry in
                        TimerRow(entry: entry)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            }
        }
    }

    private func start(_ seconds: Double) {
        store.start(seconds: seconds, label: label)
        label = ""
        labelFocused = false
        Haptics.tap()
    }
}

private struct TimerRow: View {
    let entry: TimerEntry
    private var store: TimersStore { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let left = entry.remaining(at: timeline.date)
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: entry.total > 0 ? left / entry.total : 0)
                        .stroke(entry.state == .paused ? .secondary : Color.orange,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: left)
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    if let label = entry.label {
                        Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(TimersStore.format(left, showSeconds: Settings.shared.prefs.timerShowSeconds))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(entry.state == .expired ? .orange : .primary)
                }
                Spacer(minLength: 0)
                if entry.state != .expired {
                    Button { store.togglePause(entry.id) } label: {
                        Image(systemName: entry.state == .running ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                Button { store.remove(entry.id) } label: { Image(systemName: "xmark") }
            }
            .font(.system(size: 10, weight: .bold))
            .buttonStyle(BouncyButtonStyle())
            .padding(.horizontal, 8)
            .frame(height: entry.label == nil ? 30 : 34)
            .background(Pill().fill(.white.opacity(0.07)))
        }
    }
}

// MARK: - Live activity

struct TimerActivityLeading: View {
    var body: some View {
        Image(systemName: "timer")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.orange)
            // Rings like an alarm clock: quick wiggle, short rest, repeat.
            .phaseAnimator([0.0, -14, 14, -10, 10, 0, 0]) { view, angle in
                view.rotationEffect(.degrees(angle), anchor: .top)
            } animation: { angle in
                angle == 0 ? .easeInOut(duration: 0.35) : .spring(response: 0.09, dampingFraction: 0.5)
            }
    }
}

/// Tap to stop the ringing timer.
struct TimerActivityTrailing: View {
    var body: some View {
        Button {
            TimersStore.shared.dismissExpired()
            Haptics.tap()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 20)
                .background(Pill().fill(.orange))
        }
        .buttonStyle(BouncyButtonStyle())
        .help("Stop timer")
    }
}
