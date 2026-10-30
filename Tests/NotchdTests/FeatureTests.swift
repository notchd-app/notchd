import AppKit
@testable import Notchd
import Testing

private func temporary(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("notchd-\(name)-\(UUID().uuidString)")
}

// MARK: - Clipboard

@Test func clipboardReadsFilesTextLinksAndImages() throws {
    let folder = temporary("clips")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pasteboard = NSPasteboard(name: .init("notchd-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("hello world", forType: .string)
    #expect(ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder)?.kind == .text)

    pasteboard.clearContents()
    pasteboard.setString("https://example.com/a?b=1", forType: .string)
    #expect(ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder)?.kind == .link)

    pasteboard.clearContents()
    pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
    let files = ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder)
    #expect(files?.kind == .files)
    #expect(files?.files == ["/tmp/a.txt"])

    pasteboard.clearContents()
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
        NSColor.red.setFill(); rect.fill(); return true
    }
    pasteboard.writeObjects([image])
    let clip = try #require(ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder))
    #expect(clip.kind == .image)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(clip.imageFile ?? "").path))
    // The same picture copied again is the same item.
    let again = try #require(ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder))
    #expect(again.contentKey == clip.contentKey)

    // Whitespace alone isn't worth keeping.
    pasteboard.clearContents()
    pasteboard.setString("  \n ", forType: .string)
    #expect(ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder) == nil)
}

@Test func clipboardSkipsSecretsAndIgnoredApps() {
    let folder = temporary("clips")
    let pasteboard = NSPasteboard(name: .init("notchd-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    // Password managers mark copied passwords as concealed.
    pasteboard.clearContents()
    pasteboard.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
    pasteboard.setString("hunter2", forType: .string)
    #expect(ClipboardStore.read(pasteboard, source: nil, ignoredApps: [], imageFolder: folder) == nil)

    pasteboard.clearContents()
    pasteboard.setString("from 1Password", forType: .string)
    #expect(ClipboardStore.read(pasteboard, source: "com.1password.1password",
                                ignoredApps: ClipboardStore.defaultIgnoredApps, imageFolder: folder) == nil)
    #expect(ClipboardStore.read(pasteboard, source: "com.apple.TextEdit",
                                ignoredApps: ClipboardStore.defaultIgnoredApps, imageFolder: folder) != nil)
}

@Test func clipboardLinksNeedAWebAddress() {
    #expect(ClipboardStore.isLink("https://apple.com"))
    #expect(ClipboardStore.isLink("  http://localhost:3000/x \n"))
    #expect(!ClipboardStore.isLink("apple.com"))
    #expect(!ClipboardStore.isLink("see https://apple.com for more"))
    #expect(!ClipboardStore.isLink("mailto:me@example.com"))
}

@Test func clipboardHistoryDedupesPinsAndPersists() throws {
    let folder = temporary("clips")
    defer { try? FileManager.default.removeItem(at: folder) }
    let pasteboard = NSPasteboard(name: .init("notchd-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let store = ClipboardStore(folder: folder, pasteboard: pasteboard)
    store.record(ClipItem(kind: .text, text: "one", date: Date(timeIntervalSince1970: 1)))
    store.record(ClipItem(kind: .text, text: "two", date: Date(timeIntervalSince1970: 2)))
    store.record(ClipItem(kind: .text, text: "three", date: Date(timeIntervalSince1970: 3)))
    #expect(store.visible.map(\.text) == ["three", "two", "one"])

    // Copying the same text again moves it up instead of adding a second card.
    store.record(ClipItem(kind: .text, text: "one", date: Date(timeIntervalSince1970: 4)))
    #expect(store.items.count == 3)
    #expect(store.visible.first?.text == "one")

    // Pinned items lead and survive clearing.
    let two = try #require(store.items.first { $0.text == "two" })
    store.togglePin(two)
    #expect(store.visible.first?.text == "two")
    store.query = "thr"
    #expect(store.visible.map(\.text) == ["three"])
    store.query = ""
    store.clear()
    #expect(store.items.map(\.text) == ["two"])

    store.save()
    #expect(ClipboardStore(folder: folder, pasteboard: pasteboard).items.map(\.text) == ["two"])

    // Copying back puts it on the pasteboard without recording it twice.
    store.copy(store.items[0])
    #expect(pasteboard.string(forType: .string) == "two")
    store.poll()
    #expect(store.items.count == 1)
}

@Test func clipboardKeyboardSelection() {
    let store = ClipboardStore(folder: temporary("clips"), pasteboard: NSPasteboard(name: .init("notchd-\(UUID())")))
    for (i, text) in ["a", "b", "c"].enumerated() {
        store.record(ClipItem(kind: .text, text: text, date: Date(timeIntervalSince1970: Double(i))))
    }
    store.moveSelection(by: 1)
    #expect(store.selectedItem?.text == "c")
    store.moveSelection(by: 1)
    store.moveSelection(by: 1)
    store.moveSelection(by: 1)  // stops at the end
    #expect(store.selectedItem?.text == "a")
    store.moveSelection(by: -1)
    #expect(store.selectedItem?.text == "b")
}

// MARK: - Lyrics

@Test func lyricsParseLRC() {
    let lines = LyricsStore.parse("""
    [ar: Someone]
    [00:12.50] First line
    [00:05.00]Intro
    [01:02.3][01:30.00] Chorus
    no tag here
    """)
    #expect(lines.map(\.text) == ["Intro", "First line", "Chorus", "Chorus"])
    #expect(lines.map(\.time) == [5, 12.5, 62.3, 90])
    #expect(LyricsStore.index(in: lines, at: 0) == nil)
    #expect(LyricsStore.index(in: lines, at: 5) == 0)
    #expect(LyricsStore.index(in: lines, at: 70) == 2)
    #expect(LyricsStore.index(in: lines, at: 999) == 3)
}

@Test func lyricsSearchWithCleanTitles() {
    #expect(LyricsStore.cleanTitle("Let It Be (Remastered 2009)") == "Let It Be")
    #expect(LyricsStore.cleanTitle("Song - Live at Wembley") == "Song")
    #expect(LyricsStore.cleanTitle("Hey Jude [Mono Version]") == "Hey Jude")
    #expect(LyricsStore.cleanTitle("Bohemian Rhapsody") == "Bohemian Rhapsody")
}

// MARK: - Focus timer

@Test func pomodoroCycles() {
    let file = temporary("pomodoro")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = PomodoroStore(file: file)
    store.reset()
    #expect(store.state.phase == .work)
    #expect(!store.isActive)

    store.toggle()
    #expect(store.state.running)
    #expect(store.isActive)
    store.toggle()  // pause keeps the time left
    #expect(!store.state.running)

    // Finishing focus sessions: short breaks, then a long one after the 4th (the default).
    for round in 1...4 {
        store.advance(completed: true, autoStart: false)
        #expect(store.state.round == round)
        #expect(store.state.phase == (round == 4 ? .longBreak : .shortBreak))
        #expect(store.state.waiting)
        store.advance(completed: true, autoStart: false)
        #expect(store.state.phase == .work)
    }
    #expect(store.state.round == 0)  // the long break starts a new cycle
    #expect(store.state.today == 4)

    // Skipping focus doesn't count it.
    store.skip()
    #expect(store.state.phase == .shortBreak)
    #expect(store.state.today == 4)
    #expect(PomodoroStore(file: file).state.phase == .shortBreak)
}

// MARK: - Weather

@Test func weatherParsesOpenMeteo() throws {
    let json = """
    {"utc_offset_seconds":0,
     "current":{"temperature_2m":21.4,"apparent_temperature":20.1,"weather_code":2,"is_day":1,"wind_speed_10m":9.5,"relative_humidity_2m":55},
     "hourly":{"time":["2099-01-01T10:00","2099-01-01T11:00"],"temperature_2m":[20,22],"weather_code":[1,61],"is_day":[1,1],"precipitation_probability":[0,70]},
     "daily":{"temperature_2m_max":[24.6],"temperature_2m_min":[12.2]}}
    """
    let report = try #require(WeatherStore.parse(Data(json.utf8)))
    #expect(report.temperature == 21.4)
    #expect(report.high == 24.6)
    #expect(report.low == 12.2)
    #expect(report.hours.count == 2)
    #expect(report.hours[1].precipitation == 70)
    #expect(WeatherStore.symbol(report.code, isDay: true) == "cloud.sun.fill")
    #expect(WeatherStore.symbol(0, isDay: false) == "moon.stars.fill")
    #expect(WeatherStore.degrees(21.5) == "22°")
    #expect(WeatherStore.parse(Data("{}".utf8)) == nil)
}

// MARK: - Focus

@Test func focusReadsTheNewestAssertion() {
    let assertions = """
    {"data":[{"storeAssertionRecords":[
      {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"},"assertionStartDateTimestamp":100},
      {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"},"assertionStartDateTimestamp":200}
    ]}]}
    """
    #expect(FocusMonitor.activeMode(Data(assertions.utf8)) == "com.apple.focus.work")
    #expect(FocusMonitor.activeMode(Data(#"{"data":[{"storeAssertionRecords":[]}]}"#.utf8)) == nil)

    let modes = """
    {"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"name":"Deep Work","modeIdentifier":"com.apple.focus.work",
      "symbolImageName":"laptopcomputer","tintColorName":"systemTealColor"}}}}]}
    """
    let work = FocusMonitor.describe("com.apple.focus.work", configurations: Data(modes.utf8))
    #expect(work.name == "Deep Work")
    #expect(work.symbol == "laptopcomputer")
    #expect(work.color == .teal)
    #expect(FocusMonitor.describe("com.apple.donotdisturb.mode.default", configurations: nil).symbol == "moon.fill")
}

// MARK: - Coding agents

@Test func agentHooksInstallAndRemoveCleanly() throws {
    let folder = temporary("agents")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // Claude Code: the user's own settings and hooks stay as they were.
    let claude = folder.appendingPathComponent("settings.json")
    try Data(#"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8).write(to: claude)
    try AgentHooks.connectClaude(at: claude)
    try AgentHooks.connectClaude(at: claude)  // twice is the same as once
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any])
    var hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
    #expect(json["model"] as? String == "opus")
    #expect(hooks["Stop"]?.count == 2)
    #expect(hooks["UserPromptSubmit"]?.count == 1)
    #expect(hooks["PostToolUse"]?.first?["matcher"] as? String == "*")
    #expect(FileManager.default.fileExists(atPath: claude.path + ".notchd-backup"))
    try AgentHooks.disconnectClaude(at: claude)
    json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: claude)) as? [String: Any])
    hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
    #expect(Array(hooks.keys) == ["Stop"])
    #expect(hooks["Stop"]?.count == 1)

    // Codex without a notify: ours goes above the first table, and comes out cleanly.
    let codex = folder.appendingPathComponent("config.toml")
    let plain = "model = \"o3\"\n\n[profiles.fast]\nnotify = [\"x\"]\n"
    try Data(plain.utf8).write(to: codex)
    #expect(!AgentHooks.hasTopLevelNotify(plain))
    try AgentHooks.connectCodex(at: codex)
    let connected = try String(contentsOf: codex, encoding: .utf8)
    #expect(connected.hasPrefix("notify = ['sh', '-c', "))
    #expect(AgentHooks.hasTopLevelNotify(connected))
    try AgentHooks.disconnectCodex(at: codex)
    #expect(try String(contentsOf: codex, encoding: .utf8) == plain)

    // Codex with its own notify (Computer Use, terminal-notifier…): wrapped, kept, and restored exactly.
    let existing = "notify = [\"/Apps/Helper\", \"turn-ended\"]\nmodel = \"o3\"\n\n[projects.\"/x\"]\ntrust_level = \"trusted\"\n"
    try Data(existing.utf8).write(to: codex)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codex.path)
    try AgentHooks.connectCodex(at: codex)
    let wrapped = try String(contentsOf: codex, encoding: .utf8)
    #expect(wrapped.contains("'notchd', \"/Apps/Helper\", \"turn-ended\"]  # added by Notchd"))
    #expect(wrapped.components(separatedBy: "\n").filter { $0.hasPrefix("notify") }.count == 1)
    #expect((try FileManager.default.attributesOfItem(atPath: codex.path)[.posixPermissions] as? Int) == 0o600)
    try AgentHooks.disconnectCodex(at: codex)
    #expect(try String(contentsOf: codex, encoding: .utf8) == existing)

    try Data("notify = [\n  \"a\",\n]\n".utf8).write(to: codex)
    #expect(throws: AgentHooks.AgentError.self) { try AgentHooks.connectCodex(at: codex) }
}

@Test func agentHookCommandsWriteTheEventFile() throws {
    let home = temporary("home")
    let bin = home.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    // Stand-ins: `pgrep` answers "Notchd is running" (or not), the old notify command records its arguments.
    func script(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    try script("pgrep", "exit ${PGREP_EXIT:-0}")
    try script("old-notify", "printf '%s|' \"$@\" > \"$HOME/old-notify.txt\"")
    let spool = home.appendingPathComponent("Library/Application Support/Notchd/Agents")

    func run(_ command: String, _ args: [String], stdin: String = "", running: Bool = true) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command] + args
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "PGREP_EXIT": running ? "0" : "1"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    let event = #"{"type":"agent-turn-complete"}"#
    try run(AgentHooks.claudeCommand, [], stdin: #"{"hook_event_name":"Stop"}"#)
    try run(AgentHooks.codexCommand, ["notchd", event])
    // Wrapped: the original notify still runs, with exactly the arguments Codex gave it.
    try run(AgentHooks.codexCommand, ["notchd", bin.appendingPathComponent("old-notify").path, "turn-ended", event])
    let files = try FileManager.default.contentsOfDirectory(atPath: spool.path)
    #expect(files.filter { $0.hasSuffix(".json") }.count == 3)
    #expect(!files.contains { $0.hasPrefix(".") })  // temp files were renamed into place
    #expect(try String(contentsOf: home.appendingPathComponent("old-notify.txt"), encoding: .utf8) == "turn-ended|\(event)|")

    // Notchd not running: nothing piles up, and the original notify still runs.
    try FileManager.default.removeItem(at: spool)
    try run(AgentHooks.claudeCommand, [], stdin: "{}", running: false)
    try run(AgentHooks.codexCommand, ["notchd", bin.appendingPathComponent("old-notify").path, event], running: false)
    #expect(!FileManager.default.fileExists(atPath: spool.path))
    #expect(try String(contentsOf: home.appendingPathComponent("old-notify.txt"), encoding: .utf8) == "\(event)|")
}

@Test func agentEventsDriveTheActivity() throws {
    let monitor = AgentMonitor()
    monitor.handle(["hook_event_name": "UserPromptSubmit", "session_id": "a", "cwd": "/x/notchd"])
    #expect(monitor.active.map(\.state) == [.working])
    #expect(monitor.active.first?.project == "notchd")
    #expect(monitor.lastHeard[.claude] != nil)

    // "Waiting for your input" after a finished turn isn't a question; a permission prompt is.
    monitor.handle(["hook_event_name": "Notification", "session_id": "a", "notification_type": "idle_prompt",
                    "message": "Claude is waiting for your input"])
    #expect(monitor.active.first?.state == .working)
    monitor.handle(["hook_event_name": "Notification", "session_id": "a",
                    "message": "Claude needs your permission to use Bash"])
    #expect(monitor.active.first?.state == .waiting)
    monitor.handle(["hook_event_name": "PostToolUse", "session_id": "a"])
    #expect(monitor.active.first?.state == .working)

    monitor.handle(["hook_event_name": "Stop", "session_id": "a"])
    #expect(monitor.active.isEmpty)
    // A tool event for a session that isn't running a turn doesn't bring it back.
    monitor.handle(["hook_event_name": "PostToolUse", "session_id": "a"])
    #expect(monitor.active.isEmpty)
    // A failed request ends the turn too.
    monitor.handle(["hook_event_name": "UserPromptSubmit", "session_id": "b"])
    monitor.handle(["hook_event_name": "StopFailure", "session_id": "b"])
    #expect(monitor.active.isEmpty)
}

@Test func agentInterruptionsAreReadFromTheTranscript() throws {
    let transcript = temporary("transcript")
    defer { try? FileManager.default.removeItem(at: transcript) }
    try Data((#"{"type":"assistant","message":{"content":"working on it"}}"# + "\n").utf8).write(to: transcript)
    #expect(!AgentMonitor.interrupted(transcript))
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    handle.write(Data((#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
    try handle.close()
    #expect(AgentMonitor.interrupted(transcript))
}

// MARK: - Small helpers

@Test func colorFormats() {
    let color = PickedColor(red: 1, green: 0.5, blue: 0)
    #expect(color.formatted(.hex) == "#FF8000")
    #expect(color.formatted(.rgb) == "rgb(255, 128, 0)")
    #expect(color.formatted(.hsl) == "hsl(30, 100%, 50%)")
    #expect(color.formatted(.swiftUI) == "Color(red: 1.000, green: 0.500, blue: 0.000)")
    #expect(PickedColor(red: 1, green: 1, blue: 1).isLight)
    #expect(!PickedColor(red: 0.1, green: 0.1, blue: 0.3).isLight)
}

@Test func downloadsIgnorePartialFiles() {
    #expect(DownloadsMonitor.isFinished("Report.pdf"))
    #expect(!DownloadsMonitor.isFinished("Report.pdf.crdownload"))
    #expect(!DownloadsMonitor.isFinished("Movie.mov.download"))
    #expect(!DownloadsMonitor.isFinished("file.part"))
    #expect(!DownloadsMonitor.isFinished(".DS_Store"))
    #expect(!DownloadsMonitor.isFinished("Unconfirmed 12345.crdownload"))
}

@Test func keepAwakeTitles() {
    #expect(KeepAwake.title(minutes: 0) == "Until I turn it off")
    #expect(KeepAwake.title(minutes: 60) == "For 1 hour")
    #expect(KeepAwake.title(minutes: 120) == "For 2 hours")
}

@Test func newActivitiesJoinAtTheirDefaultPriority() {
    // Someone's saved order from before the new activities, Tray last as usual.
    let saved: [Slot<ActivityKind>] = [Slot(kind: .media), Slot(kind: .bluetooth), Slot(kind: .battery),
                                       Slot(kind: .timerExpired), Slot(kind: .updateAvailable), Slot(kind: .calendar),
                                       Slot(kind: .tray)]
    let kinds = Slot.normalized(saved).map(\.kind)
    #expect(kinds.count == ActivityKind.allCases.count)
    // Their order is kept, and nothing new lands below Tray.
    #expect(kinds.filter { saved.map(\.kind).contains($0) } == saved.map(\.kind))
    #expect(kinds.last == .tray)
    #expect(kinds.firstIndex(of: .focus)! < kinds.firstIndex(of: .updateAvailable)!)
    #expect(Slot.normalized(saved).first { $0.kind == .download }?.enabled == false)
}

// MARK: - Tray actions

@Test func trayActionsConvertShrinkAndZip() throws {
    let folder = temporary("actions")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = NSImage(size: NSSize(width: 3000, height: 1500), flipped: false) { rect in
        NSColor.systemTeal.setFill(); rect.fill(); return true
    }
    let png = folder.appendingPathComponent("photo.png")
    try #require(image.pngData).write(to: png)
    #expect(TrayActions.isImage(png))

    let jpeg = folder.appendingPathComponent("photo.jpg")
    try TrayActions.writeImage(from: png, to: jpeg, type: .jpeg, quality: 0.9, maxPixels: nil)
    #expect(TrayActions.isImage(jpeg))

    // "Make Smaller" caps the long side.
    let small = folder.appendingPathComponent("small.jpg")
    try TrayActions.writeImage(from: png, to: small, type: .jpeg, quality: 0.75, maxPixels: 2560)
    let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: small)))
    #expect(max(rep.pixelsWide, rep.pixelsHigh) == 2560)

    // Archives hold relative paths and expand back to the same file.
    let archive = folder.appendingPathComponent("photos.zip")
    try TrayActions.tool("/usr/bin/zip", ["-r", "-y", "-q", archive.path, "photo.png", "photo.jpg"], in: folder)
    #expect(TrayActions.isZip(archive))
    let out = folder.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try TrayActions.tool("/usr/bin/ditto", ["-x", "-k", archive.path, out.path])
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == ["photo.png", "photo.jpg"])

    #expect(throws: TrayActions.ActionError.self) { try TrayActions.tool("/usr/bin/false", []) }
}

@Test func networkCountersAreReadable() throws {
    let (down, up) = try #require(StatsMonitor.interfaceBytes())
    #expect(down + up > 0)  // any Mac that ran this test has moved some bytes
}
