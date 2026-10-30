import AppKit
import ServiceManagement
import SwiftUI

protocol SlotKind: Codable, Hashable, CaseIterable, Identifiable {
    var title: String { get }
    var icon: String { get }
    var defaultEnabled: Bool { get }
}

extension SlotKind {
    var defaultEnabled: Bool { true }
}

enum ActivityKind: String, SlotKind {
    // Default priority: short events first (they flash for a few seconds), long-lived ones after.
    case bluetooth, battery, timerExpired, focus, download, agent, updateAvailable, calendar, privacy, pomodoro, media,
         keepAwake, tray
    var id: Self { self }
    var title: String {
        L(["media": "Media", "tray": "Tray", "calendar": "Calendar", "bluetooth": "Bluetooth",
         "battery": "Battery", "timerExpired": "Timer Done", "updateAvailable": "New Update", "focus": "Focus",
         "download": "Downloads", "agent": "Coding Agents", "privacy": "Camera & Mic", "pomodoro": "Focus Timer",
         "keepAwake": "Keep Awake"][rawValue]!)
    }
    var icon: String {
        ["media": "music.note", "tray": "tray.fill", "calendar": "calendar", "bluetooth": "headphones",
         "battery": "bolt.fill", "timerExpired": "timer", "updateAvailable": "arrow.down.circle.fill", "focus": "moon.fill",
         "download": "arrow.down.circle", "agent": "sparkle", "privacy": "video.fill", "pomodoro": "brain.head.profile",
         "keepAwake": "cup.and.heat.waves.fill"][rawValue]!
    }
    /// Downloads reads a folder macOS protects, so it waits until you turn it on.
    var defaultEnabled: Bool { self != .download }
}

enum WidgetKind: String, SlotKind {
    case media, calendar, todo, timer, notes, shortcuts, mirror, capture, pomodoro, stats, weather, colors
    var id: Self { self }
    var title: String {
        L(["media": "Media Player", "calendar": "Calendar", "todo": "To-do List", "timer": "Timer", "notes": "Notes",
         "shortcuts": "Shortcuts", "mirror": "Mirror", "capture": "Capture", "pomodoro": "Focus Timer",
         "stats": "System", "weather": "Weather", "colors": "Color Picker"][rawValue]!)
    }
    var icon: String {
        ["media": "music.note", "calendar": "calendar", "todo": "checklist", "timer": "timer", "notes": "note.text",
         "shortcuts": "square.stack.3d.up.fill", "mirror": "web.camera.fill", "capture": "camera.viewfinder",
         "pomodoro": "brain.head.profile", "stats": "gauge.with.dots.needle.50percent", "weather": "cloud.sun.fill",
         "colors": "eyedropper.halffull"][rawValue]!
    }
    /// Enabled by default: media, calendar, to-do and capture.
    var defaultEnabled: Bool { [.media, .calendar, .todo, .capture].contains(self) }
}

enum FullscreenMode: String, Codable, CaseIterable, Identifiable {
    case allMonitors, notchedScreens, never
    var id: Self { self }
    var title: String { L(["allMonitors": "All screens", "notchedScreens": "Screens with a notch", "never": "Never"][rawValue]!) }
}

enum OpenNotchSize: String, Codable, CaseIterable, Identifiable {
    case compact, roomy
    var id: Self { self }
    var title: String { self == .compact ? L("Compact") : L("Roomy") }
}

enum MediaEffect: String, Codable, CaseIterable, Identifiable {
    case spectrograph, waves, vibratingCircle, gif
    var id: Self { self }
    var title: String {
        L(["spectrograph": "Equalizer", "waves": "Wave", "vibratingCircle": "Pulse", "gif": "Your GIF"][rawValue]!)
    }
}

/// An orderable, switchable entry (live activity or nook widget). Order = display priority.
struct Slot<Kind: SlotKind>: Codable, Equatable {
    var kind: Kind
    var enabled = true
    var customUnits: Int?  // widgets only: width in U, nil = default

    static var all: [Slot] { Kind.allCases.map { Slot(kind: $0, enabled: $0.defaultEnabled) } }

    /// Keeps the user's order and adds kinds from newer versions where they sit by default: before the
    /// first kind that comes after them. (Appending would rank a new activity below Tray, which is almost
    /// always active, so it would never show.)
    static func normalized(_ slots: [Slot]) -> [Slot] {
        let order = Array(Kind.allCases)
        var result = slots
        for (rank, kind) in order.enumerated() where !result.contains(where: { $0.kind == kind }) {
            let position = result.firstIndex { (order.firstIndex(of: $0.kind) ?? 0) > rank } ?? result.endIndex
            result.insert(Slot(kind: kind, enabled: kind.defaultEnabled), at: position)
        }
        return result
    }
}

struct Prefs: Codable, Equatable {
    // General
    var alwaysOpenOnHover = false
    var disableHaptics = false
    var preventCloseWhenTyping = true
    var notchWidthFineTune = 0.0
    var notchHeightFineTune = 0.0
    var enableOnNonNotchScreens = true
    var transparentHandle = false
    var handleWidth = 184.0
    var handleHeight = 8.0
    var showInFullscreen = FullscreenMode.notchedScreens
    var lockWhileTyping = false
    var preferRoundButtons = true
    var translucentBackground = false
    var contentPadding = 12.0
    var demoMode = false
    var didShowWelcome = false
    var autoCheckUpdates = true
    // Gestures
    var allowGestures = true
    var gestureOpenClose = true
    var gestureControlMedia = true
    var invertMediaGestures = false
    // Live activities
    var liveActivitiesEnabled = true
    var inactivityTimeout = 10.0
    var interactiveActivities = true
    var unhideAutomatically = true
    var hideActivitiesOnPlainScreens = false
    var hiddenInFullscreen: [ActivityKind] = []
    var enableGlance = true
    var peekOnSongChange = false
    var activities = Slot<ActivityKind>.all
    // Calendar live activity
    var calendarMinutesBefore = 15.0
    var calendarShowDuringEvent = true
    var calendarShowElapsed = false
    var calendarOnlyMeetings = false
    // Battery live activity
    var batteryShowPlugged = true
    var batteryShowUnplugged = true
    var batteryShowFull = true
    var batteryShowLow = true
    var batteryLowThreshold = 20.0
    // Volume & brightness HUD
    var hudEnabled = false
    var hudAllScreens = false
    var hudColoredVolume = true
    var hudKeyboard = true
    // Calendar widget
    var calendarHidden: [String] = []  // calendar identifiers left out
    var calendarShowAllDay = true
    var calendarShowPast = false
    var calendarDays = 7.0             // days shown before and after today
    // To-do widget
    var todoShowCompleted = true
    var todoClearAfterDays = 7.0       // 0 = keep forever
    var todoRemindersList: String?     // Reminders list identifier, nil = the widget's own tasks
    // Timer widget
    var timerShowSeconds = true
    var timerPlaySound = true
    // Focus timer (Pomodoro), minutes
    var pomodoroWork = 25.0
    var pomodoroShortBreak = 5.0
    var pomodoroLongBreak = 15.0
    var pomodoroRounds = 4.0
    var pomodoroAutoStart = true
    // Notes widget
    var notesHighlightCode = true
    // Shortcuts widget
    var shortcuts: [String] = []
    // Mirror widget
    var mirrorCamera: String?          // AVCaptureDevice uniqueID, nil = default
    var mirrorFlip = true
    // Media
    var mediaPinnedSource: String?     // bundle ID the widget sticks to
    var mediaShowLyrics = false        // lyrics instead of title and progress in the widget
    var lyricsEnabled = true
    var lyricsInGlance = false
    // Weather widget
    var weatherPlace: WeatherPlace?
    var temperatureUnit = TemperatureUnit.system
    // Color picker widget
    var colorFormat = ColorFormat.hex
    // Clipboard
    var clipboardEnabled = true
    var clipboardLimit = 100.0
    var clipboardShortcut = false      // ⇧⌘V is taken by some apps (VS Code's Markdown preview…)
    var clipboardPasteOnClick = false
    var clipboardIgnoredApps = ClipboardStore.defaultIgnoredApps
    // Keep awake
    var keepAwakeDisplay = true
    // Downloads activity
    var downloadsFolder: String?       // nil = ~/Downloads
    // Coding agents activity
    var agentSound = false
    // Media live activity
    var mediaEffect = MediaEffect.spectrograph
    var coloredEffects = true
    var albumCornerRadius = 6.0
    var gifScale = 1.0
    var gifOffsetX = 0.0
    var gifOffsetY = 0.0
    var gifPixelPerfect = false
    // Nook
    var openNotchSize = OpenNotchSize.compact
    var nookEnabled = true
    var showDividers = true
    var widgets = Slot<WidgetKind>.all
    // Tray
    var trayFolder: String?  // nil = default
    var trayMoveOnDrop = false
    var trayAutoClearDays = 0.0

    func isEnabled(_ kind: ActivityKind) -> Bool { activities.contains { $0.kind == kind && $0.enabled } }

    /// Fields that change window geometry and require rebuilding the notch windows.
    var layoutKey: [Double] {
        [notchWidthFineTune, notchHeightFineTune, enableOnNonNotchScreens ? 1 : 0, handleWidth, handleHeight]
    }
}

extension Notification.Name {
    static let notchLayoutChanged = Notification.Name("notchd.layoutChanged")
}

@Observable
final class Settings {
    static let shared = Settings()
    private static let key = "prefs"
    private let defaults: UserDefaults

    var prefs: Prefs {
        didSet {
            guard prefs != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(prefs), forKey: Self.key)
            NotificationCenter.default.post(name: .prefsChanged, object: nil)
            if prefs.layoutKey != oldValue.layoutKey {
                NotificationCenter.default.post(name: .notchLayoutChanged, object: nil)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefs = Self.load(from: defaults)
    }

    /// Stored values are merged over the defaults so newly added fields don't wipe existing prefs.
    private static func load(from defaults: UserDefaults) -> Prefs {
        guard let stored = defaults.data(forKey: key),
              let storedDict = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Prefs())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(storedDict) { $1 }),
              var prefs = try? JSONDecoder().decode(Prefs.self, from: merged) else { return Prefs() }
        prefs.activities = Slot.normalized(prefs.activities)
        prefs.widgets = Slot.normalized(prefs.widgets)
        return prefs
    }

    func reset() {
        var reset = Prefs()
        reset.didShowWelcome = prefs.didShowWelcome
        // Storage is data, not appearance: only Tray's folder controls should move it.
        reset.trayFolder = prefs.trayFolder
        prefs = reset
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("[Settings] launch at login: \(error)")
            }
        }
    }
}

// MARK: - Window

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    enum Pane: Int { case general, gestures, liveActivities, widgets, tray, clipboard, about }
    /// Sub-tab ("General" / "Customize") the next window opens on.
    fileprivate static var subTab = UserDefaults.standard.integer(forKey: "debugSubTab")

    /// Opens Settings on a given pane, e.g. Widgets › Layout from a widget's "Choose…" button.
    func show(pane: Pane, customize: Bool = true) {
        window?.close()
        window = nil
        Self.subTab = customize ? 1 : 0
        show()
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = pane.rawValue
    }

    func show() {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            let panes: [(String, String, AnyView)] = [
                ("General", "gearshape.fill", AnyView(GeneralPane())),
                ("Gestures", "hand.tap.fill", AnyView(GesturesPane())),
                ("Live Activities", "clock.badge.fill", AnyView(LiveActivitiesPane())),
                ("Widgets", "rectangle.topthird.inset.filled", AnyView(NookPane())),
                ("Tray", "tray.fill", AnyView(TrayPane())),
                ("Clipboard", "doc.on.clipboard.fill", AnyView(ClipboardPane())),
                ("About", "ellipsis.circle.fill", AnyView(AboutPane())),
            ]
            for (title, icon, view) in panes {
                let host = NSHostingController(rootView: view.fixedSize())
                host.sizingOptions = .preferredContentSize
                host.title = L(title)  // becomes the window title
                let item = NSTabViewItem(viewController: host)
                item.label = L(title)
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            // Dev: `--args -debugSettingsTab 2 -debugSubTab 1` opens a given pane (launch args land in UserDefaults).
            tabs.selectedTabViewItemIndex = UserDefaults.standard.integer(forKey: "debugSettingsTab")
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Panes

private struct Caption: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Form { content }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(width: 520)
    }
}

private struct GeneralPane: View {
    @Bindable private var settings = Settings.shared
    @Local private var launchAtLogin = Settings.shared.launchAtLogin

    var body: some View {
        Pane {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in settings.launchAtLogin = value }
            Divider().padding(.vertical, 6)

            Picker("Over fullscreen apps:", selection: $settings.prefs.showInFullscreen) {
                ForEach(FullscreenMode.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            LabeledContent("Notch:") {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Pill-shaped buttons", isOn: $settings.prefs.preferRoundButtons)
                        Caption("Turn off for rounded squares.")
                    }
                    Toggle("Frosted glass background (experimental)", isOn: $settings.prefs.translucentBackground)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Open as soon as the pointer reaches it", isOn: $settings.prefs.alwaysOpenOnHover)
                        Caption("No click or swipe needed.")
                    }
                    Toggle("Haptic feedback", isOn: Binding(get: { !settings.prefs.disableHaptics },
                                                           set: { settings.prefs.disableHaptics = !$0 }))
                }
            }
            LabeledContent("While typing:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Stay open when the pointer leaves", isOn: $settings.prefs.preventCloseWhenTyping)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Pin it open", isOn: $settings.prefs.lockWhileTyping)
                        Caption("Typing turns the lock on; click the lock to release it.")
                    }
                }
            }
            LabeledContent("Volume & brightness:") {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Show them in the notch", isOn: $settings.prefs.hudEnabled)
                        Caption("Replaces the macOS overlay while the keys are pressed. Brightness works on the built-in display.")
                    }
                    Group {
                        Toggle("Keyboard backlight too", isOn: $settings.prefs.hudKeyboard)
                        Toggle("On every screen", isOn: $settings.prefs.hudAllScreens)
                        Toggle("Warn near full volume (orange, then red)", isOn: $settings.prefs.hudColoredVolume)
                    }
                    .disabled(!settings.prefs.hudEnabled)
                }
            }
            LabeledContent("Keep awake:") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep the display on too", isOn: $settings.prefs.keepAwakeDisplay)
                    Caption("The cup in the open notch keeps your Mac from sleeping. When this is off, the screen may still turn off.")
                }
            }
            LabeledContent("Inner spacing:") {
                ValueSlider(value: $settings.prefs.contentPadding, range: 4...24)
            }
            LabeledContent("Notch size:") {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Measured automatically. Nudge it if the edges don't line up with your camera housing.")
                    ValueSlider(title: "Width:", value: $settings.prefs.notchWidthFineTune, range: -20...20)
                    ValueSlider(title: "Height:", value: $settings.prefs.notchHeightFineTune, range: -20...20)
                }
            }
            Divider().padding(.vertical, 6)

            LabeledContent("Screens without a notch:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show a handle", isOn: $settings.prefs.enableOnNonNotchScreens)
                    Group {
                        ValueSlider(title: "Width:", value: $settings.prefs.handleWidth, range: 100...300)
                        ValueSlider(title: "Height:", value: $settings.prefs.handleHeight, range: 4...20)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Invisible until hovered", isOn: $settings.prefs.transparentHandle)
                        }
                    }
                    .disabled(!settings.prefs.enableOnNonNotchScreens)
                }
            }
            Divider().padding(.vertical, 6)

            LabeledContent("More:") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Presentation mode", isOn: $settings.prefs.demoMode)
                        Caption("Keeps everything on screen: nothing closes or times out. Handy when recording a demo.")
                    }
                    Button("Show the welcome tour") { WelcomeWindowController.shared.show() }
                    Button("Reset all settings") { settings.reset() }
                    Caption("Your tray folder and files stay where they are.")
                    Button("Quit Notchd") { NSApp.terminate(nil) }
                    Caption("Tip: right-click the notch for Settings and Quit.")
                }
            }
        }
    }
}

/// Continuous slider (no tick marks) that snaps to whole numbers.
private struct ValueSlider: View {
    var title: LocalizedStringKey?
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            if let title { Text(title).frame(width: 50, alignment: .leading) }
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
            Text("\(Int(value))").monospacedDigit().frame(width: 32, alignment: .trailing)
        }
    }
}

private struct GesturesPane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Pane {
            Toggle("Trackpad gestures on the notch", isOn: $settings.prefs.allowGestures)
            Group {
                Toggle("Swipe down to open, up to close", isOn: $settings.prefs.gestureOpenClose)
                Toggle("Swipe sideways to skip tracks", isOn: $settings.prefs.gestureControlMedia)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Reverse skip direction", isOn: $settings.prefs.invertMediaGestures)
                        .disabled(!settings.prefs.gestureControlMedia)
                    Caption("Off: swipe right for the next track. On: swipe left for the next track.")
                }
            }
            .disabled(!settings.prefs.allowGestures)
            .padding(.leading, 20)
        }
    }
}

private struct LiveActivitiesPane: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        SubTabs(customizeTitle: "Activities") {
            Pane {
                Toggle("Show live activities", isOn: $settings.prefs.liveActivitiesEnabled)
                Divider().padding(.vertical, 6)
                LabeledContent("Hide after:") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Slider(value: $settings.prefs.inactivityTimeout, in: 1...30, step: 1)
                            Text("\(Int(settings.prefs.inactivityTimeout))s").monospacedDigit().frame(width: 32)
                        }
                        Caption("How long an activity lingers once it goes idle, e.g. after you pause the music.")
                    }
                }
                LabeledContent("Behavior:") {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Clickable buttons", isOn: $settings.prefs.interactiveActivities)
                            Caption("Join a call or stop a timer right from the notch. When off, a click just opens it.")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Bring hidden activities back", isOn: $settings.prefs.unhideAutomatically)
                            Caption("Swipe up to tuck an activity away. With this on, it returns on its own when there's news (a new song, a new file). Otherwise, swipe down to restore it.")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Only on screens with a notch", isOn: $settings.prefs.hideActivitiesOnPlainScreens)
                        }
                    }
                }
                LabeledContent("Glance:") {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Glance on hover", isOn: $settings.prefs.enableGlance)
                            Caption("Point at an activity and a line of details slides out below it.")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Glance at new songs", isOn: $settings.prefs.peekOnSongChange)
                            Caption("Shows the title for a few seconds whenever the track changes.")
                        }
                        .disabled(!settings.prefs.enableGlance)
                    }
                }
                LabeledContent("Over fullscreen apps:") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ActivityKind.allCases) { kind in
                            Toggle(isOn: fullscreenBinding(kind)) {
                                Label(kind.title, systemImage: kind.icon)
                            }
                        }
                        Caption("Activities that may appear while you watch or work in fullscreen.")
                    }
                }
                .disabled(!settings.prefs.liveActivitiesEnabled)
            }
        } customize: {
            CustomizeActivities()
        }
    }
}

private extension LiveActivitiesPane {
    func fullscreenBinding(_ kind: ActivityKind) -> Binding<Bool> {
        Binding(
            get: { !settings.prefs.hiddenInFullscreen.contains(kind) },
            set: { visible in
                settings.prefs.hiddenInFullscreen.removeAll { $0 == kind }
                if !visible { settings.prefs.hiddenInFullscreen.append(kind) }
            }
        )
    }
}

private struct CustomizeActivities: View {
    @Bindable private var settings = Settings.shared
    // Dev: `-debugActivity agent` opens with that activity selected.
    @Local private var selection: ActivityKind? = UserDefaults.standard.string(forKey: "debugActivity")
        .flatMap(ActivityKind.init(rawValue:)) ?? Settings.shared.prefs.activities.first?.kind

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            SlotList(slots: $settings.prefs.activities, selection: $selection,
                     caption: "Drag to set priority: when several are active, the top one wins.")
            let shown = selection ?? settings.prefs.activities.first?.kind ?? .media
            VStack(spacing: 20) {
                ActivityPreview(kind: shown)
                switch shown {
                case .media: MediaActivityOptions()
                case .calendar: CalendarActivityOptions()
                case .battery: BatteryActivityOptions()
                case .focus: FocusActivityOptions()
                case .download: DownloadsActivityOptions()
                case .agent: AgentActivityOptions()
                case .privacy:
                    Caption("Shows while any app uses your camera or microphone, like the dots in the menu bar. The Mirror widget doesn't count.")
                case .pomodoro:
                    Caption("Shows while a focus session or break runs. Set the lengths in Widgets › Layout › Focus Timer.")
                case .keepAwake:
                    Caption("Shows while your Mac is kept awake, with the time left. Click it to stop.")
                case .tray, .bluetooth, .timerExpired, .updateAvailable: Caption("Nothing to configure here.")
                }
            }
            .frame(width: 380)
        }
        .padding(24)
    }
}

/// Black mini-notch showing what the selected activity looks like, with the current options.
private struct ActivityPreview: View {
    let kind: ActivityKind
    private var prefs: Prefs { Settings.shared.prefs }

    init(kind: ActivityKind) { self.kind = kind }

    var body: some View {
        let info = MediaManager.shared.nowPlaying ?? .sample
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black)
            HStack(spacing: 0) {
                Group {
                    switch kind {
                    case .media: MediaActivityLeading(info: info, cornerRadius: prefs.albumCornerRadius)
                    case .tray: Image(systemName: "tray.fill").foregroundStyle(.white)
                    case .calendar: CalendarActivityLeading(event: .sample)
                    case .bluetooth: BluetoothActivityLeading(event: .sample)
                    case .timerExpired: TimerActivityLeading()
                    case .updateAvailable: UpdateActivityLeading()
                    case .battery: BatteryActivityLeading(percent: 82, state: .plugged)
                    case .focus: FocusActivityLeading(event: .sample)
                    case .download: DownloadActivityLeading(event: .sample)
                    case .agent: AgentActivityLeading(session: .sample)
                    case .privacy: PrivacyActivityLeading(camera: true, microphone: true)
                    case .pomodoro: PomodoroActivityLeading()
                    case .keepAwake: KeepAwakeActivityLeading()
                    }
                }
                .frame(width: NotchModel.activitySide)
                Spacer(minLength: 140)
                Group {
                    switch kind {
                    case .media: MediaEffectView(info: info, effect: prefs.mediaEffect, colored: prefs.coloredEffects)
                    case .tray: Text("3").font(.system(size: 13, weight: .semibold, design: .rounded))
                    case .calendar: CalendarActivityTrailing(event: .sample)
                    case .bluetooth: BluetoothActivityTrailing(event: .sample)
                    case .timerExpired: TimerActivityTrailing()
                    case .updateAvailable: UpdateActivityTrailing()
                    case .battery: BatteryActivityTrailing(percent: 82, state: .plugged)
                    case .focus: FocusActivityTrailing(event: .sample)
                    case .download: DownloadActivityTrailing(event: .sample)
                    case .agent: AgentActivityTrailing(session: .sample)
                    case .privacy: PrivacyActivityTrailing(camera: true, microphone: true)
                    case .pomodoro: PomodoroActivityTrailing()
                    case .keepAwake: Image(systemName: "infinity").foregroundStyle(.orange)
                    }
                }
                .frame(width: NotchModel.activitySide)
            }
            .frame(width: 140 + 2 * NotchModel.activitySide, height: 32)
            .padding(.top, 6)
        }
        .frame(height: 110)
        .environment(\.colorScheme, .dark)
    }
}

private struct MediaActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            LabeledContent("Artwork roundness:") {
                HStack {
                    Slider(value: $settings.prefs.albumCornerRadius, in: 0...20, step: 1)
                    Text("\(Int(settings.prefs.albumCornerRadius))").monospacedDigit().frame(width: 24)
                }
            }
            Picker("Animation:", selection: $settings.prefs.mediaEffect) {
                ForEach(MediaEffect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if settings.prefs.mediaEffect == .gif {
                GIFOptions()
            } else {
                LabeledContent("Match artwork color:") {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("", isOn: $settings.prefs.coloredEffects).labelsHidden()
                        Caption("Tints the animation with the cover's main color instead of white.")
                    }
                }
            }
        }
    }
}

private struct CalendarActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            LabeledContent("Minutes ahead:") {
                HStack {
                    Slider(value: $settings.prefs.calendarMinutesBefore, in: 1...60, step: 1)
                    Text("\(Int(settings.prefs.calendarMinutesBefore))").monospacedDigit().frame(width: 24)
                }
            }
            Toggle("Keep showing during the event", isOn: $settings.prefs.calendarShowDuringEvent)
            Toggle("Count up instead of down during it", isOn: $settings.prefs.calendarShowElapsed)
                .disabled(!settings.prefs.calendarShowDuringEvent)
            Toggle("Video calls only", isOn: $settings.prefs.calendarOnlyMeetings)
            Caption("Events with a Google Meet, Zoom, Teams or Webex link get a green button to join in one click.")
        }
        .onChange(of: settings.prefs) { CalendarStore.shared.refreshUpcoming() }
    }
}

private struct BatteryActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Toggle("Charger connected", isOn: $settings.prefs.batteryShowPlugged)
            Toggle("Charger disconnected", isOn: $settings.prefs.batteryShowUnplugged)
            Toggle("Fully charged", isOn: $settings.prefs.batteryShowFull)
            Toggle("Running low", isOn: $settings.prefs.batteryShowLow)
            LabeledContent("Low means under:") {
                HStack {
                    Slider(value: $settings.prefs.batteryLowThreshold, in: 5...50, step: 5)
                    Text("\(Int(settings.prefs.batteryLowThreshold))%").monospacedDigit().frame(width: 36)
                }
            }
            .disabled(!settings.prefs.batteryShowLow)
        }
    }
}

private struct GIFOptions: View {
    @Bindable private var settings = Settings.shared
    private var gif = GIFStore.shared
    private var hasGIF: Bool { gif.url != nil }

    var body: some View {
        LabeledContent("GIF:") {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Button(hasGIF ? "Change…" : "Choose…", action: choose)
                    if hasGIF { Button("Remove") { gif.remove() } }
                }
                if !hasGIF { Caption("Pick any animated GIF. Until you do, the equalizer is shown.") }
            }
        }
        slider("Scale:", $settings.prefs.gifScale, 0.5...2, step: 0.1) { String(format: "%.1f×", $0) }
        slider("Horizontal offset:", $settings.prefs.gifOffsetX, -10...10, step: 1) { "\(Int($0))" }
        slider("Vertical offset:", $settings.prefs.gifOffsetY, -10...10, step: 1) { "\(Int($0))" }
        Picker("Rendering:", selection: $settings.prefs.gifPixelPerfect) {
            Text("Smooth").tag(false)
            Text("Crisp pixels (for pixel art)").tag(true)
        }
        .pickerStyle(.radioGroup)
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(format(value.wrappedValue)).monospacedDigit().frame(width: 36)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        if panel.runModal() == .OK, let url = panel.url { gif.install(from: url) }
    }
}

private struct NookPane: View {
    @Bindable private var settings = Settings.shared
    /// Settings preview the built-in (notched) screen, where space is tightest.
    static var referenceMaxUnits: Int {
        let screen = NSScreen.screens.first { $0.notchSize != nil } ?? NSScreen.main
        return Grid(prefs: Settings.shared.prefs).maxUnits(screenWidth: screen?.frame.width ?? 1440)
    }
    var body: some View {
        SubTabs(customizeTitle: "Layout") {
            Pane {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Open widgets on click", isOn: $settings.prefs.nookEnabled)
                    Caption("When off, the notch only shows live activities.")
                }
                Divider().padding(.vertical, 6)
                LabeledContent("Open notch size:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Open notch size", selection: $settings.prefs.openNotchSize) {
                            ForEach(OpenNotchSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Caption("Compact fits the controls closely. Roomy adds space for longer lists.")
                    }
                }
                Toggle("Separators between widgets", isOn: $settings.prefs.showDividers)
            }
        } customize: {
            WidgetLayoutEditor(settings: settings, maxUnits: Self.referenceMaxUnits)
        }
    }
}

/// Per-widget settings, under the width stepper in Widgets › Layout.
struct WidgetOptions: View {
    let kind: WidgetKind
    @Bindable private var settings = Settings.shared

    var body: some View {
        switch kind {
        case .timer:
            Toggle("Show seconds", isOn: $settings.prefs.timerShowSeconds)
            Toggle("Chime when done", isOn: $settings.prefs.timerPlaySound)
        case .calendar:
            CalendarWidgetOptions()
        case .todo:
            RemindersListPicker()
            Toggle("Show completed tasks", isOn: $settings.prefs.todoShowCompleted)
            LabeledContent("Remove completed after:") {
                HStack {
                    Slider(value: $settings.prefs.todoClearAfterDays, in: 0...30, step: 1)
                    Text(settings.prefs.todoClearAfterDays == 0 ? "Never" : "\(Int(settings.prefs.todoClearAfterDays))d")
                        .monospacedDigit().frame(width: 44)
                }
            }
            .onChange(of: settings.prefs.todoClearAfterDays) { TodoStore.shared.clearOld() }
            Caption("Star a task to keep it on top.")
        case .notes:
            Toggle("Color code in code notes", isOn: $settings.prefs.notesHighlightCode)
            Caption("The { } button turns a note into code: monospaced, with colors. ⌘B, ⌘I and ⌘U style rich notes.")
        case .shortcuts:
            ShortcutsOptions()
        case .mirror:
            MirrorOptions()
        case .capture:
            Caption("Choose an area or window for a screenshot. Use the macOS recording controls to start and stop a video. Finished captures appear in your tray.")
        case .media:
            if let pinned = settings.prefs.mediaPinnedSource {
                LabeledContent("Pinned to:") {
                    HStack {
                        Text(MediaManager.appName(pinned))
                        Button("Follow the system") { MediaManager.shared.pin(nil) }
                    }
                }
            }
            Caption("When several players are open, their icons show in the widget's corner. Click one to stick to it.")
            Toggle("Synced lyrics", isOn: $settings.prefs.lyricsEnabled)
            Toggle("Sing along in the Glance", isOn: $settings.prefs.lyricsInGlance)
                .disabled(!settings.prefs.lyricsEnabled)
            Caption("The speech-bubble button swaps the song info for lyrics, from the free LRCLIB database. The speaker button picks where sound plays.")
            Caption("Song titles are sent to LRCLIB only while lyrics are shown.")
        case .pomodoro:
            PomodoroOptions()
        case .stats:
            Caption("CPU, graphics, memory, disk and network, every two seconds while it's in the notch. Make it 3U or wider for live graphs. Click it to open Activity Monitor.")
        case .weather:
            WeatherOptions()
        case .colors:
            Picker("Copy as:", selection: $settings.prefs.colorFormat) {
                ForEach(ColorFormat.allCases) { Text($0.title).tag($0) }
            }
            Caption("Click the eyedropper, then any pixel on any screen. Click a swatch to copy it again; right-click for other formats.")
        }
    }
}

private struct PomodoroOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        minutes("Focus:", $settings.prefs.pomodoroWork, 5...90)
        minutes("Short break:", $settings.prefs.pomodoroShortBreak, 1...30)
        minutes("Long break:", $settings.prefs.pomodoroLongBreak, 5...60)
        LabeledContent("Long break after:") {
            Stepper("\(Int(settings.prefs.pomodoroRounds)) sessions", value: $settings.prefs.pomodoroRounds, in: 2...8)
        }
        Toggle("Start the next phase by itself", isOn: $settings.prefs.pomodoroAutoStart)
        Caption("A chime marks the end of each phase when \"Chime when done\" is on in the Timer's options.")
            .onChange(of: settings.prefs) { PomodoroStore.shared.durationsChanged() }
    }

    private func minutes(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 1)
                Text("\(Int(value.wrappedValue)) min").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }
}

/// Keep the widget's own tasks, or sync them with a Reminders list.
private struct RemindersListPicker: View {
    @Bindable private var settings = Settings.shared
    private var reminders = RemindersStore.shared

    var body: some View {
        Picker("Tasks:", selection: $settings.prefs.todoRemindersList) {
            Text("Kept in Notchd").tag(String?.none)
            if !reminders.lists.isEmpty { Divider() }
            ForEach(reminders.lists, id: \.calendarIdentifier) { list in
                Text("Reminders: \(list.title)").tag(String?.some(list.calendarIdentifier))
            }
        }
        .onAppear { reminders.requestAccess() }
        .onChange(of: settings.prefs.todoRemindersList) { reminders.reload() }
        .onChange(of: settings.prefs.todoShowCompleted) { reminders.reload() }
        if reminders.denied {
            Caption("Reminders access needed: allow it in System Settings › Privacy & Security › Reminders.")
        }
    }
}

private struct FocusActivityOptions: View {
    private var focus = FocusMonitor.shared

    var body: some View {
        Form {
            Caption("Flashes the Focus's icon and color when you turn one on or off, like on iPhone.")
            if focus.needsAccess {
                Caption("macOS keeps Focus status in a protected folder: give Notchd Full Disk Access to read it. Notchd reads only the Focus files there.")
                Button("Open Full Disk Access Settings") { FocusMonitor.openFullDiskAccessSettings() }
            } else {
                LabeledContent("Now:") { Text(focus.current?.name ?? L("No Focus")) }
            }
        }
        .onAppear { FocusMonitor.shared.refresh() }
    }
}

private struct DownloadsActivityOptions: View {
    @Bindable private var settings = Settings.shared

    var body: some View {
        Form {
            Caption("When a download finishes, the notch shows it for a few seconds: click its icon to show it in Finder, or the tray button to keep it at hand.")
            LabeledContent("Folder:") {
                VStack(alignment: .leading, spacing: 4) {
                    Text((settings.prefs.downloadsFolder ?? DownloadsMonitor.defaultFolder.path)
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Choose…", action: choose)
                        Button("Reset") { settings.prefs.downloadsFolder = nil }
                            .disabled(settings.prefs.downloadsFolder == nil)
                    }
                }
            }
            Caption("Turn it on in the list. macOS asks once to let Notchd see your Downloads folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = DownloadsMonitor.defaultFolder
        if panel.runModal() == .OK, let url = panel.url { settings.prefs.downloadsFolder = url.path }
    }
}

private struct AgentActivityOptions: View {
    @Bindable private var settings = Settings.shared
    @Local private var claude = AgentHooks.claudeStatus
    @Local private var codex = AgentHooks.codexStatus
    @Local private var error: String?
    @Local private var justConnected = false
    private var monitor = AgentMonitor.shared

    var body: some View {
        Form {
            Caption("See when Claude Code or Codex is working, needs your input, or has finished, without watching the terminal. Click the activity to jump back to it.")
            row("Claude Code:", tool: .claude, status: claude, connect: AgentHooks.connectClaude,
                disconnect: AgentHooks.disconnectClaude)
            row("Codex:", tool: .codex, status: codex, connect: AgentHooks.connectCodex, disconnect: AgentHooks.disconnectCodex)
            if justConnected {
                Caption("Connected. New sessions show up right away; restart sessions that were already open (Claude Code reads its hooks when a session starts).")
                    .foregroundStyle(.green)
            }
            Toggle("Chime when an agent finishes", isOn: $settings.prefs.agentSound)
            if let error { Text(error).font(.callout).foregroundStyle(.orange) }
            Caption("Connect adds a small hook to ~/.claude/settings.json or ~/.codex/config.toml (a backup is kept next to it). It only writes event files into Notchd's own folder, and only while Notchd is running. An existing Codex notify command keeps working.")
        }
        .onAppear {
            claude = AgentHooks.claudeStatus
            codex = AgentHooks.codexStatus
        }
    }

    private func row(_ title: LocalizedStringKey, tool: AgentTool, status: AgentHooks.Status,
                     connect: @escaping () throws -> Void, disconnect: @escaping () throws -> Void) -> some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    switch status {
                    case .unavailable:
                        Text("Not installed").foregroundStyle(.secondary)
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { run(disconnect) }
                    case .notInstalled:
                        Button("Connect") { run(connect, connecting: true) }
                    }
                }
                if status == .connected {
                    Group {
                        if let heard = monitor.lastHeard[tool] {
                            Text("Last heard \(heard.formatted(.relative(presentation: .named)))")
                        } else {
                            Text("Waiting for its first event")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run(_ action: () throws -> Void, connecting: Bool = false) {
        do {
            try action()
            error = nil
            justConnected = connecting
        } catch {
            self.error = error.localizedDescription
            justConnected = false
        }
        claude = AgentHooks.claudeStatus
        codex = AgentHooks.codexStatus
    }
}

private struct ClipboardPane: View {
    @Bindable private var settings = Settings.shared
    @Bindable private var store = ClipboardStore.shared
    @Local private var accessibility = ClipboardStore.canPaste(prompt: false)
    @Local private var newApp = ""

    var body: some View {
        Pane {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Keep a clipboard history", isOn: $settings.prefs.clipboardEnabled)
                Caption("Everything you copy shows up in the notch's Clipboard tab, searchable, images included. It stays on this Mac.")
            }
            Divider().padding(.vertical, 6)
            Group {
                LabeledContent("Remember:") {
                    HStack {
                        Slider(value: $settings.prefs.clipboardLimit, in: 20...500, step: 10)
                        Text("\(Int(settings.prefs.clipboardLimit))").monospacedDigit().frame(width: 36)
                    }
                }
                Caption("Older items go first. Pinned items are always kept.")
                LabeledContent("Shortcut:") {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("⇧⌘V opens the history", isOn: $settings.prefs.clipboardShortcut)
                        Caption("Use ← → to choose, Return to use it, Delete to remove it, Escape to close.")
                    }
                }
                LabeledContent("Clicking an item:") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $settings.prefs.clipboardPasteOnClick) {
                            Text("Copies it").tag(false)
                            Text("Pastes it into the app you were using").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        if settings.prefs.clipboardPasteOnClick, !accessibility {
                            Caption("Pasting needs Accessibility access, so Notchd can press ⌘V for you.")
                            Button("Allow Accessibility…") {
                                accessibility = ClipboardStore.canPaste(prompt: true)
                            }
                        }
                    }
                }
                LabeledContent("Never record from:") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(settings.prefs.clipboardIgnoredApps, id: \.self) { id in
                            HStack {
                                Text(ClipboardStore.appName(id)).lineLimit(1)
                                Spacer()
                                Button {
                                    settings.prefs.clipboardIgnoredApps.removeAll { $0 == id }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                            }
                        }
                        Button("Add App…", action: addApp)
                        Caption("Password managers are skipped by default, and so is anything an app marks as secret.")
                    }
                }
            }
            .disabled(!settings.prefs.clipboardEnabled)
            Divider().padding(.vertical, 6)
            LabeledContent("History:") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(store.items.count) items").foregroundStyle(.secondary)
                    HStack {
                        Button("Clear (keep pinned)") { store.clear() }
                        Button("Clear Everything") { store.clear(includingPinned: true) }
                    }
                    .disabled(store.items.isEmpty)
                }
            }
        }
        .onAppear { accessibility = ClipboardStore.canPaste(prompt: false) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              !settings.prefs.clipboardIgnoredApps.contains(id) else { return }
        settings.prefs.clipboardIgnoredApps.append(id)
    }
}

private struct CalendarWidgetOptions: View {
    @Bindable private var settings = Settings.shared
    private var store = CalendarStore.shared

    var body: some View {
        Toggle("All-day events", isOn: $settings.prefs.calendarShowAllDay)
        Toggle("Today's past events", isOn: $settings.prefs.calendarShowPast)
        LabeledContent("Days around today:") {
            HStack {
                Slider(value: $settings.prefs.calendarDays, in: 1...21, step: 1)
                Text("±\(Int(settings.prefs.calendarDays))").monospacedDigit().frame(width: 32)
            }
        }
        LabeledContent("Calendars:") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if store.denied { Caption("Calendar access needed: allow it in System Settings › Privacy.") }
                    ForEach(store.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: shown(calendar.calendarIdentifier)) {
                            HStack(spacing: 5) {
                                Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 8, height: 8)
                                Text(calendar.title).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
        .onChange(of: settings.prefs.calendarHidden) { store.reload() }
        .onChange(of: settings.prefs.calendarShowAllDay) { store.reload() }
        .onChange(of: settings.prefs.calendarShowPast) { store.reload() }
        .onChange(of: settings.prefs.calendarDays) { store.reload() }
        .onAppear { store.reload() }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { !settings.prefs.calendarHidden.contains(id) },
                set: { on in
                    settings.prefs.calendarHidden.removeAll { $0 == id }
                    if !on { settings.prefs.calendarHidden.append(id) }
                })
    }
}

private struct ShortcutsOptions: View {
    @Bindable private var settings = Settings.shared
    private var store = ShortcutsStore.shared

    var body: some View {
        LabeledContent("Show:") {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if store.available.isEmpty { Caption("No shortcuts found. Make some in the Shortcuts app.") }
                        ForEach(store.available, id: \.self) { name in
                            Toggle(name, isOn: chosen(name))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                Button("Refresh") { store.refresh() }
            }
        }
        .onAppear { store.refresh() }
        Caption("They run in the background. Tick them in the order you want them in the notch.")
    }

    private func chosen(_ name: String) -> Binding<Bool> {
        Binding(get: { settings.prefs.shortcuts.contains(name) },
                set: { on in
                    settings.prefs.shortcuts.removeAll { $0 == name }
                    if on { settings.prefs.shortcuts.append(name) }
                })
    }
}

private struct MirrorOptions: View {
    @Bindable private var settings = Settings.shared
    private let devices = Camera.devices

    var body: some View {
        Picker("Camera:", selection: $settings.prefs.mirrorCamera) {
            Text("Default").tag(String?.none)
            ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag(String?.some($0.uniqueID)) }
        }
        Toggle("Flip like a mirror", isOn: $settings.prefs.mirrorFlip)
        Caption("Click the widget to turn the camera on. It turns off when the notch closes.")
    }
}

private struct TrayPane: View {
    @Bindable private var settings = Settings.shared
    @Bindable private var tray = TrayStore.shared

    var body: some View {
        Pane {
            LabeledContent("Storage folder:") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tray.folder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button("Choose…", action: chooseFolder)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([tray.folder]) }
                        Button("Reset to default") { tray.setFolder(nil) }
                            .disabled(settings.prefs.trayFolder == nil)
                    }
                    Caption("Files already in the tray move to the new folder.")
                }
            }
            Divider().padding(.vertical, 6)

            Picker("When dropping files:", selection: $settings.prefs.trayMoveOnDrop) {
                Text("Copy them (keep originals)").tag(false)
                Text("Move them").tag(true)
            }
            .pickerStyle(.radioGroup)
            Caption("Pasting files always makes a copy and keeps the originals.")
            LabeledContent("Auto-clear:") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Slider(value: $settings.prefs.trayAutoClearDays, in: 0...30, step: 1)
                        Text(settings.prefs.trayAutoClearDays == 0 ? "Never" : "\(Int(settings.prefs.trayAutoClearDays))d")
                            .monospacedDigit().frame(width: 44)
                    }
                    Caption("Files older than this go to the Trash. Set to 0 to keep them forever.")
                }
            }
            .onChange(of: settings.prefs.trayAutoClearDays) { tray.reload() }
            Divider().padding(.vertical, 6)

            LabeledContent("More:") {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Clear tray (\(tray.files.count))") { tray.clear() }
                        .disabled(tray.files.isEmpty)
                    Caption("Removed files go to the Trash.")
                }
            }
        }
        .alert(item: $tray.folderChangeNotice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = tray.folder
        if panel.runModal() == .OK, let url = panel.url { tray.setFolder(url) }
    }
}

// MARK: - Shared settings pieces

/// "General | Customize …" segmented control on top of a pane.
private struct SubTabs<General: View, Customize: View>: View {
    let customizeTitle: LocalizedStringKey
    @ViewBuilder let general: General
    @ViewBuilder let customize: Customize
    @Local private var tab = SettingsWindowController.subTab

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text(customizeTitle).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)
            if tab == 0 { general } else { customize }
        }
    }
}

/// Reorderable list of activities or widgets, each with an on/off switch.
private struct SlotList<Kind: SlotKind>: View {
    @Binding var slots: [Slot<Kind>]
    @Binding var selection: Kind?
    let caption: LocalizedStringKey
    var badge: (Slot<Kind>) -> Text? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach($slots, id: \.kind) { $slot in
                    HStack(spacing: 10) {
                        Image(systemName: slot.kind.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.blue.gradient))
                        Text(slot.kind.title).lineLimit(1)
                        Spacer(minLength: 4)
                        badge(slot)?.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Toggle("", isOn: $slot.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .tag(slot.kind)
                }
                .onMove { slots.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(width: 270, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Caption(caption).frame(width: 270, alignment: .leading)
        }
    }
}

/// "7 of 12 U used" bar, so you see how much room is left in the notch.
struct UnitsGauge: View {
    let layout: NookLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<max(layout.maxUnits, 1), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < layout.usedUnits ? Color.accentColor : .secondary.opacity(0.25))
                        .frame(height: 10)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: layout.usedUnits)
            Text("\(layout.usedUnits) of \(layout.maxUnits) U used on this screen")
                .font(.callout.monospacedDigit())
            Caption("1U = \(Int(Grid(prefs: Settings.shared.prefs).unit)) pt. The notch stops growing at 75% of the screen width; widgets past that stay hidden.")
        }
    }
}

private struct AboutPane: View {
    @Bindable private var settings = Settings.shared
    private var updater = Updater.shared
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("notchd").font(.title.bold())
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "dev") (\(info["CFBundleVersion"] as? String ?? "0"))")
                .foregroundStyle(.secondary)
            Caption("A clean, open-source Dynamic Island–style notch for your Mac.")

            Divider().padding(.vertical, 6)

            HStack {
                Button("Check for Updates") { updater.check() }
                    .disabled(updater.status == .checking || updater.status == .installing)
                Toggle("Check automatically", isOn: $settings.prefs.autoCheckUpdates)
            }
            Group {
                switch updater.status {
                case .idle: Text(" ")
                case .checking: Text("Checking…")
                case .upToDate: Text("You're up to date.")
                case let .available(update):
                    HStack {
                        Text("notchd \(update.version) is available.")
                        Button("Install & Relaunch") { updater.install() }
                        Link("Release notes", destination: update.pageURL)
                    }
                case .installing: Text("Downloading and installing…")
                case let .failed(message): Text(message).foregroundStyle(.orange)
                }
            }
            .font(.callout)

            Link("github.com/\(Updater.repo)", destination: URL(string: "https://github.com/\(Updater.repo)")!)
                .font(.callout)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(width: 520)
    }
}
