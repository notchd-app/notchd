import AppKit
import SwiftUI

enum AgentTool: String, Codable {
    case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
    var icon: String { self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }
    var color: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .white }
}

struct AgentSession: Equatable, Identifiable {
    enum State: Equatable { case working, waiting, done }

    var id: String
    var tool: AgentTool
    var project: String
    var state: State
    var message: String?
    var updated = Date()
    /// The app you typed the prompt in (Terminal, iTerm, VS Code…), brought forward on click.
    var app: String?

    static let sample = AgentSession(id: "sample", tool: .claude, project: "notchd", state: .working)
}

/// Coding agents report to Notchd through tiny hooks that drop their event JSON into a folder:
/// Claude Code's hooks (prompt sent, tool used, needs you, finished) and Codex's `notify` command.
/// No network, no daemon: the folder is watched and each file is read once, then deleted.
@Observable
final class AgentMonitor {
    static let shared = AgentMonitor()
    static let spool = URL.appSupport.appendingPathComponent("Agents", isDirectory: true)
    private(set) var sessions: [AgentSession] = []
    private var source: DispatchSourceFileSystemObject?
    private var sweep: Timer?

    /// Sessions running or waiting for you, newest first.
    var active: [AgentSession] { sessions.filter { $0.state != .done }.sorted { $0.updated > $1.updated } }

    func apply() {
        let prefs = Settings.shared.prefs
        let wanted = prefs.isEnabled(.agent) && prefs.liveActivitiesEnabled
        if wanted, source == nil {
            try? FileManager.default.createDirectory(at: Self.spool, withIntermediateDirectories: true)
            let fd = open(Self.spool.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.drain(maxAge: 600) }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
            sweep = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.dropStale() }
            // Hooks keep writing while the activity is off: old events are history, not news.
            drain(maxAge: 60)
        } else if !wanted, source != nil {
            source?.cancel()
            source = nil
            sweep?.invalidate()
            sweep = nil
            sessions = []
        }
    }

    /// Reads and deletes every finished event file (hooks write a hidden temp file, then rename it).
    private func drain(maxAge: TimeInterval? = nil) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.spool, includingPropertiesForKeys: [.creationDateKey]))
            ?? []).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { Self.created($0) < Self.created($1) }
        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }
            if let maxAge, Date().timeIntervalSince(Self.created(file)) > maxAge { continue }
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(json)
        }
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    func handle(_ json: [String: Any]) {
        let cwd = json["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? L("Agent") : (cwd as NSString).lastPathComponent
        if let type = json["type"] as? String {
            // Codex: only reports finished turns.
            guard type == "agent-turn-complete" else { return }
            let id = json["thread-id"] as? String ?? cwd
            sessions.removeAll { $0.id == id }
            finished(AgentSession(id: id, tool: .codex, project: project, state: .done,
                                  message: json["last-assistant-message"] as? String))
            return
        }
        guard let event = json["hook_event_name"] as? String else { return }
        let id = json["session_id"] as? String ?? cwd
        var session = sessions.first { $0.id == id }
            ?? AgentSession(id: id, tool: .claude, project: project, state: .working)
        session.updated = Date()
        switch event {
        case "UserPromptSubmit":
            session.state = .working
            session.message = nil
            session.app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        case "PreToolUse", "PostToolUse":
            guard session.state != .done else { return }
            session.state = .working
            session.message = nil
        case "Notification":
            session.state = .waiting
            session.message = json["message"] as? String
            ActivityCenter.shared.peek(for: 4)
            Haptics.tap()
        case "Stop", "SubagentStop":
            guard event == "Stop" else { return }
            sessions.removeAll { $0.id == id }
            session.state = .done
            finished(session)
            return
        case "SessionEnd":
            withAnimation(.notchClose) { sessions.removeAll { $0.id == id } }
            return
        default:
            return
        }
        withAnimation(.notchOpen) {
            sessions.removeAll { $0.id == id }
            sessions.append(session)
        }
    }

    private func finished(_ session: AgentSession) {
        if Settings.shared.prefs.agentSound { NSSound(named: "Glass")?.play() }
        ActivityCenter.shared.show(.agentDone(session), for: 5)
    }

    /// A session that crashed or was closed mid-turn sends nothing more: let it go after a while.
    private func dropStale() {
        let now = Date()
        let kept = sessions.filter { now.timeIntervalSince($0.updated) < ($0.state == .waiting ? 7200 : 1800) }
        if kept != sessions { withAnimation(.notchClose) { sessions = kept } }
    }

    /// Brings the session's terminal or editor forward.
    static func focus(_ session: AgentSession) {
        guard let id = session.app, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        else { return }
        app.activate()
    }
}

// MARK: - Connecting the agents

/// Adds and removes Notchd's hooks in the agents' own config files. Every change keeps a backup.
enum AgentHooks {
    private static let marker = "Notchd/Agents"
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    static let codexConfig = home.appendingPathComponent(".codex/config.toml")

    /// Writes the event JSON from stdin into the spool, atomically.
    static let claudeCommand = #"f="$HOME/Library/Application Support/Notchd/Agents"; mkdir -p "$f" && n="$f/.$(uuidgen)" && cat > "$n" && mv "$n" "$f/$(uuidgen).json""#
    /// Codex passes the event JSON as the last argument.
    static let codexCommand = #"f="$HOME/Library/Application Support/Notchd/Agents"; mkdir -p "$f" && n="$f/.$(uuidgen)" && printf %s "$1" > "$n" && mv "$n" "$f/$(uuidgen).json""#
    private static let claudeEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    enum Status: Equatable { case notInstalled, connected, connectedDifferently, unavailable }

    static var claudeStatus: Status {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) else { return .unavailable }
        let text = (try? String(contentsOf: claudeSettings, encoding: .utf8)) ?? ""
        return text.contains(marker) ? .connected : .notInstalled
    }

    static var codexStatus: Status {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else { return .unavailable }
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if text.contains(marker) { return .connected }
        return hasTopLevelNotify(text) ? .connectedDifferently : .notInstalled
    }

    static func connectClaude() throws { try connectClaude(at: claudeSettings) }
    static func disconnectClaude() throws { try disconnectClaude(at: claudeSettings) }
    static func connectCodex() throws { try connectCodex(at: codexConfig) }
    static func disconnectCodex() throws { try disconnectCodex(at: codexConfig) }

    static func connectClaude(at link: URL) throws {
        let url = link.resolvingSymlinksInPath()  // dotfiles setups link these; keep the link
        var settings = try readJSON(url)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !groups.contains(where: { describes($0) }) else { continue }
            var group: [String: Any] = ["hooks": [["type": "command", "command": claudeCommand]]]
            if event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeJSON(settings, to: url)
    }

    static func disconnectClaude(at link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        var settings = try readJSON(url)
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !describes($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(settings, to: url)
    }

    private static func describes(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    /// `notify` must be a top-level key, so it goes above the first [table].
    static func connectCodex(at link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !text.contains(marker) else { return }
        guard !hasTopLevelNotify(text) else { throw AgentError(L("Codex already runs a notify command. Remove it from ~/.codex/config.toml first.")) }
        let line = "notify = ['sh', '-c', '\(codexCommand)', 'notchd']  # added by Notchd\n"
        try backup(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (line + (text.isEmpty ? "" : "\n" + text)).write(to: url, atomically: true, encoding: .utf8)
    }

    static func disconnectCodex(at link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let text = try String(contentsOf: url, encoding: .utf8)
        try backup(url)
        var lines = text.components(separatedBy: "\n").filter { !$0.contains(marker) }
        if lines.first?.isEmpty == true { lines.removeFirst() }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func hasTopLevelNotify(_ toml: String) -> Bool {
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return false }
            if trimmed.range(of: #"^notify\s*="#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    struct AgentError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError(L("~/.claude/settings.json isn't valid JSON, so Notchd left it alone."))
        }
        return json
    }

    private static func writeJSON(_ json: [String: Any], to url: URL) throws {
        try backup(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// settings.json → settings.json.notchd-backup, overwritten each time.
    private static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let copy = url.appendingPathExtension("notchd-backup")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
    }
}

// MARK: - Live activity

struct AgentActivityLeading: View {
    let session: AgentSession

    var body: some View {
        Button {
            AgentMonitor.focus(session)
            Haptics.tap()
        } label: {
            Group {
                switch session.state {
                case .working:
                    // Claude's spark turns slowly while it works; Codex's glyph breathes.
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        Image(systemName: session.tool.icon)
                            .foregroundStyle(session.tool.color)
                            .rotationEffect(.degrees(session.tool == .claude ? (t * 90).truncatingRemainder(dividingBy: 360) : 0))
                            .opacity(session.tool == .claude ? 1 : 0.65 + 0.35 * sin(t * 3))
                    }
                case .waiting:
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange).symbolEffect(.bounce, value: session.updated)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text("Show \(session.project)"))
    }
}

struct AgentActivityTrailing: View {
    let session: AgentSession
    var count = 1

    var body: some View {
        Group {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(session.tool.color)
            } else {
                switch session.state {
                case .working:
                    TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle().fill(session.tool.color).frame(width: 4, height: 4)
                                    .opacity(0.3 + 0.7 * max(0, sin(t * 4 - Double(i) * 0.8)))
                            }
                        }
                    }
                case .waiting:
                    Text("!").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.orange)
                case .done:
                    Text("Done").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.green)
                }
            }
        }
    }
}
