import AppKit
import SwiftUI

enum FocusPhase: String, Codable {
    case work, shortBreak, longBreak

    var isBreak: Bool { self != .work }
    var title: String { L(["work": "Focus", "shortBreak": "Short Break", "longBreak": "Long Break"][rawValue]!) }
    var icon: String { isBreak ? "cup.and.saucer.fill" : "brain.head.profile" }
    var color: Color { isBreak ? .green : .red }
}

/// Pomodoro cycles: focus, short break, focus… and a long break after every few rounds.
struct PomodoroState: Codable, Equatable {
    var phase = FocusPhase.work
    var running = false
    var endsAt: Date?
    /// Left in the phase while paused (or before it starts).
    var remaining: Double
    /// Focus sessions finished in the current cycle (resets after a long break).
    var round = 0
    /// Focus sessions finished on `day`.
    var today = 0
    var day = Calendar.current.startOfDay(for: .now)
    /// A phase has ended and the next one waits for a click (when auto-start is off).
    var waiting = false
    /// The current phase has run at some point (paused counts), so new lengths wait for the next phase.
    var didStart = false

    init(remaining: Double) { self.remaining = remaining }

    func remaining(at now: Date) -> Double {
        running ? max(0, endsAt?.timeIntervalSince(now) ?? 0) : remaining
    }

    var started: Bool { running || waiting || didStart }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(FocusPhase.self, forKey: .phase)
        running = try c.decode(Bool.self, forKey: .running)
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        remaining = try c.decode(Double.self, forKey: .remaining)
        round = try c.decode(Int.self, forKey: .round)
        today = try c.decode(Int.self, forKey: .today)
        day = try c.decode(Date.self, forKey: .day)
        waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        didStart = try c.decodeIfPresent(Bool.self, forKey: .didStart) ?? false
    }
}

@Observable
final class PomodoroStore {
    static let shared = PomodoroStore()
    private let file: URL

    private(set) var state: PomodoroState {
        didSet { try? JSONEncoder().encode(state).write(to: file, options: .atomic) }
    }

    init(file: URL = URL.appSupport.appendingPathComponent("pomodoro.json")) {
        self.file = file
        state = Stored.load(PomodoroState.self, from: file)
            ?? PomodoroState(remaining: Self.duration(of: .work))
        rollOverDay()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    static func duration(of phase: FocusPhase, prefs: Prefs = Settings.shared.prefs) -> Double {
        switch phase {
        case .work: prefs.pomodoroWork * 60
        case .shortBreak: prefs.pomodoroShortBreak * 60
        case .longBreak: prefs.pomodoroLongBreak * 60
        }
    }

    /// The live activity shows while a session runs or waits for you.
    var isActive: Bool { state.running || state.waiting }

    func toggle() {
        var s = state
        if s.running {
            s.remaining = s.remaining(at: .now)
            s.running = false
            s.endsAt = nil
        } else {
            s.waiting = false
            s.didStart = true
            s.running = true
            s.endsAt = Date().addingTimeInterval(s.remaining)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { state = s }
    }

    /// Ends the current phase now and moves on (without counting a skipped focus session).
    func skip() {
        advance(completed: false, autoStart: state.running)
    }

    /// Back to the start of a fresh cycle.
    func reset() {
        var s = PomodoroState(remaining: Self.duration(of: .work))
        s.today = state.today
        s.day = state.day
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { state = s }
    }

    /// Settings changed a duration: a phase that hasn't started yet picks it up.
    func durationsChanged() {
        guard !state.started else { return }
        state.remaining = Self.duration(of: state.phase)
    }

    private func tick() {
        rollOverDay()
        guard state.running, state.remaining(at: .now) <= 0 else { return }
        if Settings.shared.prefs.timerPlaySound { NSSound(named: state.phase.isBreak ? "Hero" : "Glass")?.play() }
        Haptics.tap()
        advance(completed: true, autoStart: Settings.shared.prefs.pomodoroAutoStart)
    }

    func advance(completed: Bool, autoStart: Bool) {
        var s = state
        let rounds = max(1, Int(Settings.shared.prefs.pomodoroRounds))
        if s.phase == .work {
            if completed {
                s.round += 1
                s.today += 1
            }
            s.phase = s.round >= rounds ? .longBreak : .shortBreak
        } else {
            if s.phase == .longBreak { s.round = 0 }
            s.phase = .work
        }
        s.remaining = Self.duration(of: s.phase)
        s.didStart = autoStart
        s.running = autoStart
        s.waiting = !autoStart && completed
        s.endsAt = autoStart ? Date().addingTimeInterval(s.remaining) : nil
        withAnimation(.notchOpen) { state = s }
        if completed { ActivityCenter.shared.peek(for: 4) }
    }

    private func rollOverDay() {
        let today = Calendar.current.startOfDay(for: .now)
        if state.day != today {
            state.day = today
            state.today = 0
        }
    }
}

// MARK: - Widget

struct PomodoroWidget: View {
    private var store = PomodoroStore.shared

    var body: some View {
        let state = store.state
        let rounds = max(1, Int(Settings.shared.prefs.pomodoroRounds))
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let left = state.remaining(at: timeline.date)
            let total = PomodoroStore.duration(of: state.phase)
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: total > 0 ? left / total : 0)
                        .stroke(state.phase.color.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: left)
                    VStack(spacing: 0) {
                        Text(TimersStore.format(left, showSeconds: true))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                        Text(state.phase.title).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<rounds, id: \.self) { i in
                            Circle()
                                .fill(i < state.round ? Color.red : .white.opacity(0.15))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .help(Text("Focus sessions until the long break"))
                    HStack(spacing: 4) {
                        Button { store.toggle(); Haptics.tap() } label: {
                            Image(systemName: state.running ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 30, height: 24)
                                .background(Pill().fill(state.phase.color.opacity(0.85)))
                        }
                        .help(state.running ? Text("Pause") : Text("Start"))
                        Button { store.skip(); Haptics.tap() } label: {
                            Image(systemName: "forward.end.fill").frame(width: 24, height: 24)
                                .background(Pill().fill(.white.opacity(0.1)))
                        }
                        .help(Text("Skip to the next phase"))
                        Button { store.reset(); Haptics.tap() } label: {
                            Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 24)
                                .background(Pill().fill(.white.opacity(0.1)))
                        }
                        .help(Text("Start over"))
                    }
                    .font(.system(size: 11, weight: .bold))
                    .buttonStyle(BouncyButtonStyle())
                    Text(state.today == 1 ? "1 session today" : "\(state.today) sessions today")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Live activity

struct PomodoroActivityLeading: View {
    private var store = PomodoroStore.shared

    var body: some View {
        let state = store.state
        Image(systemName: state.phase.icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(state.phase.color)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: state.waiting)
    }
}

/// Time left, or a play button when the next phase waits for you.
struct PomodoroActivityTrailing: View {
    private var store = PomodoroStore.shared

    var body: some View {
        let state = store.state
        if state.waiting {
            Button { store.toggle(); Haptics.tap() } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 20)
                    .background(Pill().fill(state.phase.color))
            }
            .buttonStyle(BouncyButtonStyle())
            .help(Text("Start \(state.phase.title)"))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let left = state.remaining(at: timeline.date)
                let shown = left.isFinite ? min(max(left, 0), 359_999) : 0
                Text(shown >= 60 ? "\(Int((shown / 60).rounded(.up)))m" : "\(Int(shown.rounded(.up)))s")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.phase.color)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
    }
}
