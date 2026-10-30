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
    /// Claude Code's transcript file, read to notice interruptions (they send no event).
    var transcript: String?

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
    /// When each agent was last heard from, shown in Settings so you can tell the hook works.
    private(set) var lastHeard: [AgentTool: Date] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var sweep: Timer?

    /// Sessions running or waiting for you, newest first.
    var active: [AgentSession] { sessions.filter { $0.state != .done }.sorted { $0.updated > $1.updated } }

    private var enabled = false

    /// The folder is always watched while Notchd runs, so it never piles up; events only count
    /// while the activity is on.
    func apply() {
        let prefs = Settings.shared.prefs
        let wanted = prefs.isEnabled(.agent) && prefs.liveActivitiesEnabled
        if wanted, !enabled {
            sweep = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.dropStale() }
        } else if !wanted, enabled {
            sweep?.invalidate()
            sweep = nil
            sessions = []
        }
        // Before draining: events from the last minute (sent while Notchd was starting) still count.
        enabled = wanted
        if source == nil {
            try? FileManager.default.createDirectory(at: Self.spool, withIntermediateDirectories: true)
            let fd = open(Self.spool.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename],
                                                                       queue: .main)
                source.setEventHandler { [weak self] in self?.drain(maxAge: 600) }
                source.setCancelHandler { close(fd) }
                source.resume()
                self.source = source
            }
            // Written while Notchd wasn't watching: history, not news.
            drain(maxAge: 60)
        }
    }

    /// Reads and deletes every finished event file (hooks write a hidden temp file, then rename it).
    private func drain(maxAge: TimeInterval) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.spool, includingPropertiesForKeys: [.creationDateKey]))
            ?? []).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { Self.created($0) < Self.created($1) }
        for file in files {
            defer { try? FileManager.default.removeItem(at: file) }
            guard enabled, Date().timeIntervalSince(Self.created(file)) <= maxAge,
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(json)
        }
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    func handle(_ json: [String: Any]) {
        lastHeard[json["type"] is String ? .codex : .claude] = Date()
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
        if let transcript = json["transcript_path"] as? String { session.transcript = transcript }
        switch event {
        case "UserPromptSubmit":
            session.state = .working
            session.message = nil
            session.app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        case "PreToolUse", "PostToolUse":
            // Only an ongoing turn: a tool event never starts one (and isn't news for a session we don't know).
            guard sessions.contains(where: { $0.id == id }) else { return }
            session.state = .working
            session.message = nil
        case "Notification":
            // Claude also says "waiting for your input" a minute after it finished: that's not a question.
            guard Self.needsYou(json) else { return }
            session.state = .waiting
            session.message = json["message"] as? String
            ActivityCenter.shared.peek(for: 4)
            Haptics.tap()
        case "Stop":
            sessions.removeAll { $0.id == id }
            session.state = .done
            finished(session)
            return
        case "StopFailure", "SessionEnd":
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

    /// Permission requests and questions need you; idle reminders and sign-in notices don't.
    static func needsYou(_ json: [String: Any]) -> Bool {
        if let type = json["notification_type"] as? String {
            return type == "permission_prompt" || type == "elicitation_dialog"
        }
        let message = (json["message"] as? String ?? "").lowercased()
        return !message.contains("waiting for your input") && !message.isEmpty
    }

    private func finished(_ session: AgentSession) {
        if Settings.shared.prefs.agentSound { NSSound(named: "Glass")?.play() }
        ActivityCenter.shared.show(.agentDone(session), for: 5)
    }

    /// Claude sends nothing when you press Esc or a request fails, so the transcript tells us instead:
    /// an interruption is written there, and a turn that stopped writing for a while is over.
    private func dropStale() {
        let now = Date()
        let kept = sessions.filter { session in
            guard session.state == .working else { return now.timeIntervalSince(session.updated) < 7200 }
            guard let path = session.transcript else { return now.timeIntervalSince(session.updated) < 600 }
            let url = URL(fileURLWithPath: path)
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if now.timeIntervalSince(max(written ?? session.updated, session.updated)) > 600 { return false }
            return !Self.interrupted(url)
        }
        if kept != sessions { withAnimation(.notchClose) { sessions = kept } }
    }

    /// Whether the transcript's last entry is Claude Code's "[Request interrupted by user]" marker.
    static func interrupted(_ transcript: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd() else { return false }
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return last.contains("[Request interrupted by user")
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

    /// Writes the event JSON from stdin into the spool, atomically, only while Notchd is running.
    static let claudeCommand = #"pgrep -xq Notchd || exit 0; f="$HOME/Library/Application Support/Notchd/Agents"; mkdir -p "$f" && n="$f/.$(uuidgen)" && cat > "$n" && mv "$n" "$f/$(uuidgen).json""#
    /// Codex passes the event JSON as the last argument. Any notify command that was there before
    /// follows ours in the argument list and still runs, with the same arguments it always got.
    static let codexCommand = #"j=""; for a in "$@"; do j="$a"; done; if pgrep -xq Notchd; then f="$HOME/Library/Application Support/Notchd/Agents"; mkdir -p "$f" && n="$f/.$(uuidgen)" && printf %s "$j" > "$n" && mv "$n" "$f/$(uuidgen).json"; fi; if [ $# -gt 1 ]; then exec "$@"; fi"#
    private static let claudeEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd"]
    private static let originalPrefix = "# notchd-original: "

    enum Status: Equatable { case notInstalled, connected, unavailable }

    static var claudeStatus: Status {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) else { return .unavailable }
        let text = (try? String(contentsOf: claudeSettings, encoding: .utf8)) ?? ""
        return text.contains(marker) ? .connected : .notInstalled
    }

    static var codexStatus: Status {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) else { return .unavailable }
        let text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        return text.contains(marker) ? .connected : .notInstalled
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

    /// `notify` must be a top-level key. Without one, ours goes above the first [table]. With one, it's
    /// wrapped: Codex runs our command, which runs the original. The original line is kept as a comment
    /// so Disconnect can put it back exactly.
    static func connectCodex(at link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !text.contains(marker) else { return }
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let ours = "'sh', '-c', '\(codexCommand)', 'notchd'"
        if let index = topLevelNotifyLine(lines) {
            let original = lines[index]
            guard let open = original.firstIndex(of: "["), let close = original.lastIndex(of: "]"), open < close else {
                throw AgentError(L("Codex's notify setting spans several lines. Put it on one line, then try again."))
            }
            let inner = original[original.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            lines[index] = "notify = [\(ours)\(inner.isEmpty ? "" : ", " + inner)]  # added by Notchd"
            lines.insert(originalPrefix + original, at: index)
        } else {
            lines.insert("notify = [\(ours)]  # added by Notchd", at: 0)
            if lines.count > 1 { lines.insert("", at: 1) }
        }
        try write(lines.joined(separator: "\n") + (text.isEmpty ? "\n" : ""), to: url)
    }

    static func disconnectCodex(at link: URL) throws {
        let url = link.resolvingSymlinksInPath()
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(originalPrefix) { lines.append(String(line.dropFirst(originalPrefix.count))) }
            else if !line.contains(marker) { lines.append(line) }
        }
        if lines.first?.isEmpty == true, !text.contains(originalPrefix) { lines.removeFirst() }
        try write(lines.joined(separator: "\n"), to: url)
    }

    static func hasTopLevelNotify(_ toml: String) -> Bool { topLevelNotifyLine(toml.components(separatedBy: "\n")) != nil }

    private static func topLevelNotifyLine(_ lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            if trimmed.range(of: #"^notify\s*="#, options: .regularExpression) != nil { return i }
        }
        return nil
    }

    /// Writes with a backup, keeping the file's permissions (config files are often private).
    private static func write(_ text: String, to url: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try backup(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
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
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try write(String(decoding: data, as: UTF8.self) + "\n", to: url)
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
