import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherInstances()
        handleTerminationSignal()
        rebuildWindows()
        // No Dock icon, no window: a quick wave says "I'm running".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ActivityCenter.shared.show(.hello, for: 2) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            NSLog("[Screens] changed: %@", NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                .joined(separator: ", "))
            self?.rebuildWindows()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in NSLog("[Power] going to sleep") }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in NSLog("[Power] woke up") }
        CrashReporter.debugCrashIfAsked()
        NotificationCenter.default.addObserver(forName: .notchLayoutChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }

        BatteryMonitor.shared.start()
        MediaManager.shared.start()
        BluetoothMonitor.shared.start()
        _ = TimersStore.shared  // rings even if the timer widget is never shown
        _ = FullscreenMonitor.shared
        Updater.shared.start()
        HUDCenter.shared.start()
        _ = PomodoroStore.shared
        applyServices()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyServices()
        }
        installMainMenu()

        // Dev: `--args -demo battery|unplugged|full|low|bluetooth|timer|peek|update|install|focus|download|agent|agentDone`
        // fires a sample activity.
        if let demo = UserDefaults.standard.string(forKey: "demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                switch demo {
                case "bluetooth": ActivityCenter.shared.show(.bluetooth(.sample))
                case "timer": TimersStore.shared.start(seconds: 3)
                case "peek": ActivityCenter.shared.peek(for: 10)
                case "update": Updater.shared.check()
                case "install":
                    Updater.shared.check()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Updater.shared.install() }
                case "unplugged": ActivityCenter.shared.show(.battery(percent: 64, state: .unplugged))
                case "full": ActivityCenter.shared.show(.battery(percent: 100, state: .full))
                case "low": ActivityCenter.shared.show(.battery(percent: 15, state: .low))
                case "focus": ActivityCenter.shared.show(.focus(.sample))
                case "keepAwake": KeepAwake.shared.turnOn(minutes: 30)
                case "pomodoro": PomodoroStore.shared.toggle()
                case "download": ActivityCenter.shared.show(.download(DownloadEvent(url: DownloadsMonitor.defaultFolder)), for: 6)
                case "agent": AgentMonitor.shared.handle(["hook_event_name": "UserPromptSubmit", "session_id": "demo",
                                                          "cwd": FileManager.default.currentDirectoryPath])
                case "agentDone": AgentMonitor.shared.handle(["hook_event_name": "Stop", "session_id": "demo",
                                                              "cwd": FileManager.default.currentDirectoryPath])
                default: ActivityCenter.shared.show(.battery(percent: 82, state: .plugged))
                }
            }
        }
        if CommandLine.arguments.contains("--settings") { SettingsWindowController.shared.show() }
        if CommandLine.arguments.contains("--welcome") { WelcomeWindowController.shared.show() } else {
            WelcomeWindowController.shared.showIfFirstLaunch()
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let model = self?.controllers.first?.model else { return }
                model.locked = true
                switch UserDefaults.standard.string(forKey: "debugTab") {
                case "tray": model.tab = .tray
                case "clipboard": model.tab = .clipboard
                default: break
                }
                model.open()
            }
        }
        // Dev: `-debugSnapshot /path.png [-debugSnapshotDelay 2.5]` saves the notch as an image (no Screen Recording needed).
        if let path = UserDefaults.standard.string(forKey: "debugSnapshot") {
            let delay = max(UserDefaults.standard.double(forKey: "debugSnapshotDelay"), 2.5)  // launch arguments arrive as strings
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // With --settings, the Settings window; otherwise the notch.
                if CommandLine.arguments.contains("--settings"),
                   let window = NSApp.windows.first(where: { $0.isVisible && $0.contentViewController is NSTabViewController }),
                   let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                       [.boundsIgnoreFraming, .bestResolution]) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                } else {
                    self?.controllers.first?.snapshot(to: path)
                }
            }
        }
    }

    /// Background features follow their settings: each starts or stops itself as needed.
    private var lastKeepAwakeDisplay = Settings.shared.prefs.keepAwakeDisplay
    private func applyServices() {
        ClipboardStore.shared.apply()
        ClipboardShortcut.shared.apply()
        PrivacyMonitor.shared.apply()
        DownloadsMonitor.shared.apply()
        FocusMonitor.shared.apply()
        AgentMonitor.shared.apply()
        StatsMonitor.shared.apply()
        WeatherStore.shared.apply()
        LyricsStore.shared.trackChanged(MediaManager.shared.nowPlaying)  // lyrics just switched on or off
        let display = Settings.shared.prefs.keepAwakeDisplay
        if display != lastKeepAwakeDisplay {
            lastKeepAwakeDisplay = display
            KeepAwake.shared.settingsChanged()
        }
    }

    /// One notch is enough: a freshly launched copy (e.g. a new version) replaces any running one.
    private func quitOtherInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.processIdentifier != me {
            app.terminate()
        }
    }

    /// `kill`/`pkill` send SIGTERM, which skips applicationWillTerminate and would orphan the media helper.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CaptureManager.shared.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Finish your capture first"
        alert.informativeText = "Use the macOS Stop button to finish your recording, or press Escape to cancel the selection. Your capture will then be saved to the tray."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
    }

    /// Never shown (no Dock icon), but it's what makes ⌘C/⌘V/⌘Z/⌘B work in text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let items: [(String, [(String, String, String)])] = [
            ("Edit", [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]),
            ("Format", [("Bold", "toggleBold:", "b"), ("Italic", "toggleItalic:", "i"), ("Underline", "underline:", "u")]),
        ]
        for (title, entries) in items {
            let menu = NSMenu(title: title)
            for (name, action, key) in entries {
                menu.addItem(NSMenuItem(title: name, action: Selector(action), keyEquivalent: key))
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardStore.shared.save(wait: true)
        NotesStore.shared.save()  // edits from the last moments are otherwise still waiting to be written
        KeepAwake.shared.turnOff()
        HUDCenter.shared.stop()
        MediaManager.shared.stop()
        CrashReporter.markCleanExit()
    }

    private func rebuildWindows() {
        controllers.forEach { $0.close() }
        let showOnPlainScreens = Settings.shared.prefs.enableOnNonNotchScreens
        controllers = NSScreen.screens
            .filter { $0.notchSize != nil || showOnPlainScreens }
            .map(NotchController.init)
    }
}

CrashReporter.install()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
