import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

// MARK: - System volume

/// Output volume of the default device, pushed by CoreAudio (no polling, no permission).
@Observable
final class AudioVolume {
    static let shared = AudioVolume()

    /// 0...1, nil when the device has no software volume (some HDMI/USB outputs).
    private(set) var level: Double?
    private(set) var muted = false
    /// Effective loudness for visuals: 0 when muted.
    var loudness: Double { muted ? 0 : level ?? 1 }

    /// Called on user-visible changes (not on device switches).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var device = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var deviceSwitchedAt = Date.distantPast
    @ObservationIgnored private let queue = DispatchQueue.main

    @ObservationIgnored private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rebind()
    }
    @ObservationIgnored private lazy var valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.read(notify: true)
    }

    init() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, deviceListener)
        rebind()
    }

    private func rebind() {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, valueListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        device = id
        deviceSwitchedAt = Date()
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(device, &address, queue, valueListener)
        }
        read(notify: false)
    }

    private func read(notify: Bool) {
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        let newLevel = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? Double(volume) : nil
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = Self.address(kAudioDevicePropertyMute)
        let newMuted = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute != 0
        guard newLevel != level || newMuted != muted else { return }
        level = newLevel
        muted = newMuted
        // A new device reports its own volume: that's not the user pressing a key.
        if notify, Date().timeIntervalSince(deviceSwitchedAt) > 1 { onChange?() }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

// MARK: - Display brightness

/// Built-in display brightness through the private DisplayServices framework, loaded at runtime.
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let get: Get? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Get.self)
    }()

    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let set: Set? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(symbol, to: Set.self)
    }()

    /// Sets the built-in display's brightness; false when that isn't possible here.
    @discardableResult
    static func setCurrent(_ level: Double) -> Bool {
        guard let set, let display = builtInDisplay else { return false }
        return set(display, Float(min(max(level, 0), 1))) == 0
    }

    /// 0...1, nil when there's no built-in display (or the API went away).
    static func current() -> Double? {
        guard let get, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? Double(value) : nil
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        NSScreen.screens.map(\.displayID).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

// MARK: - Keyboard backlight

/// Keyboard backlight level through the private CoreBrightness KeyboardBrightnessClient, loaded at runtime.
enum KeyboardBacklight {
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = type.init()
        let needed = ["brightnessForKeyboard:", "copyKeyboardBacklightIDs"].map(NSSelectorFromString)
        return needed.allSatisfy(client.responds(to:)) ? client : nil
    }()

    private static let keyboard: UInt64? = {
        guard let client, let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?
            .takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }()

    /// 0...1, nil on Macs without a backlit keyboard (or if the API went away).
    static func current() -> Double? {
        guard let client, let keyboard else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        let get = unsafeBitCast(client.method(for: selector), to: Get.self)
        return Double(get(client, selector, keyboard))
    }
}

// MARK: - HUD

struct HUDState: Equatable {
    enum Kind { case volume, brightness, keyboard }
    var kind: Kind
    var level: Double
    var muted = false
}

/// Shows volume, brightness and keyboard backlight changes growing out of the notch.
/// Volume changes come from CoreAudio; brightness is sampled (there's no public change notification).
/// Optionally the system overlay (OSDUIHelper) is paused with SIGSTOP meanwhile, and resumed when that's off.
@Observable
final class HUDCenter {
    static let shared = HUDCenter()
    private(set) var state: HUDState?

    private var hideWork: DispatchWorkItem?
    private var brightnessTimer: Timer?
    private var lastBrightness: Double?
    private var lastKeyboard: Double?
    private var suppressTimer: Timer?
    private var keyMonitor: Any?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        AudioVolume.shared.onChange = { [weak self] in self?.volumeChanged() }
        // Volume keys at the top or bottom of the range change nothing, so CoreAudio stays silent:
        // watch the keys themselves too, so the notch still answers the press.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let key = Self.volumeKey(subtype: Int(event.subtype.rawValue), data1: event.data1), key.down else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.volumeChanged() }
        }
        // A crash while it was on would leave the system overlay paused for good: resume it at launch.
        if !hidesSystemOverlay { Self.systemOverlay(paused: false) }
        apply()
        askForAccessibilityOnce()
        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.apply() }
    }

    // MARK: Handling the keys ourselves

    /// What a volume key does: 16 steps like macOS (64 with ⌥⇧). Volume up while muted just unmutes.
    static func volumeAfterKey(_ code: Int, level: Double, muted: Bool, fine: Bool) -> (level: Double, muted: Bool) {
        if code == 7 { return (level, !muted) }
        let steps = fine ? 64.0 : 16.0
        let position = (min(max(level, 0), 1) * steps).rounded()
        if code == 0 { return muted ? (level, false) : (min(position + 1, steps) / steps, false) }
        let next = max(position - 1, 0) / steps
        return (next, muted && next > 0)
    }

    /// Called by the key tap. Returns true when the key was handled here, so macOS never sees it
    /// (and never shows its own pop-up); false hands it back to the system.
    func handleKey(code: Int, down: Bool, fine: Bool) -> Bool {
        switch code {
        case 0, 1, 7:
            guard AudioDevices.canSetVolume, let level = AudioVolume.shared.level else { return false }
            guard down else { return true }
            let next = Self.volumeAfterKey(code, level: level, muted: AudioVolume.shared.muted, fine: fine)
            if next.muted != AudioVolume.shared.muted { AudioDevices.setMuted(next.muted) }
            if next.level != level { AudioDevices.setVolume(next.level) }
            if next.muted { AudioDevices.setMuted(true) }  // setting a volume unmutes
            show(HUDState(kind: .volume, level: next.level, muted: next.muted))
            return true
        case 2, 3:
            guard let level = Brightness.current() else { return false }
            guard down else { return true }
            let steps = fine ? 64.0 : 16.0
            let next = min(max(((level * steps).rounded() + (code == 2 ? 1 : -1)) / steps, 0), 1)
            guard Brightness.setCurrent(next) else { return false }
            lastBrightness = next
            show(HUDState(kind: .brightness, level: next))
            return true
        default:
            return false
        }
    }

    /// Hiding the system pop-up is on by default and needs Accessibility access: ask for it, once.
    /// After that the button in Settings › General is the way to grant it.
    private func askForAccessibilityOnce() {
        let asked = "askedAccessibilityForOverlay"
        guard hidesSystemOverlay, needsAccessibility, !UserDefaults.standard.bool(forKey: asked) else { return }
        UserDefaults.standard.set(true, forKey: asked)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }

    private var loggedTap: Bool?
    private var tapRetry: Timer?
    /// Hiding is on but Accessibility access hasn't been given yet (Settings shows a button for it).
    private(set) var needsAccessibility = false

    private var enabled = false
    private var hiding = false
    private var hidesSystemOverlay: Bool { Settings.shared.prefs.volumeInNotch && Settings.shared.prefs.hideSystemOverlay }

    /// Media keys arrive as "system defined" events: subtype 8, key code in the high word of data1,
    /// 0x0A in the next byte while the key is down. 0 = volume up, 1 = volume down, 7 = mute.
    static func volumeKey(subtype: Int, data1: Int) -> (code: Int, down: Bool)? {
        guard subtype == 8 else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16
        guard [0, 1, 7].contains(code) else { return nil }
        return (code, (data1 & 0xFF00) >> 8 == 0x0A)
    }

    /// Follows the settings: starts or stops sampling, and pauses or resumes the system overlay.
    private func apply() {
        let on = Settings.shared.prefs.volumeInNotch
        let wantsHide = hidesSystemOverlay
        // Best way to hide the system pop-up: take the keys before macOS does (needs Accessibility).
        // It's the only way on macOS 26, where the pop-up no longer comes from a helper we can pause.
        if wantsHide {
            let tapped = MediaKeyTap.shared.start()
            if tapped != loggedTap {
                loggedTap = tapped
                NSLog("[Keys] handling the volume and brightness keys: %@ (Accessibility access: %@)", tapped ? "yes" : "no",
                      AXIsProcessTrusted() ? "granted" : "not granted")
            }
            needsAccessibility = !tapped
            if !tapped, tapRetry == nil {
                // Access is granted in System Settings, outside the app: keep looking for it.
                tapRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.apply() }
            } else if tapped {
                tapRetry?.invalidate()
                tapRetry = nil
            }
        } else {
            MediaKeyTap.shared.stop()
            needsAccessibility = false
            tapRetry?.invalidate()
            tapRetry = nil
        }
        // Without the tap, fall back to pausing the system's overlay helper (works up to macOS 15).
        let hide = wantsHide && !MediaKeyTap.shared.isActive
        if hide {
            if !hiding { Self.systemOverlay(paused: true) }
            // macOS relaunches the overlay helper now and then: pause it again.
            if suppressTimer == nil {
                suppressTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                    Self.systemOverlay(paused: true)
                }
            }
        } else if hiding {
            suppressTimer?.invalidate()
            suppressTimer = nil
            Self.systemOverlay(paused: false)
        }
        hiding = hide
        if on {
            if brightnessTimer == nil {
                lastBrightness = Brightness.current()
                lastKeyboard = KeyboardBacklight.current()
                // ponytail: 5 Hz sampling; swap for a key event tap if it ever costs anything measurable.
                brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.sample()
                }
            }
        } else if enabled {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
        }
        enabled = on
    }

    /// On quit: never leave the system overlay paused behind us.
    func stop() {
        MediaKeyTap.shared.stop()
        if hiding { Self.systemOverlay(paused: false, wait: true) }
    }

    private func volumeChanged() {
        guard enabled, let level = AudioVolume.shared.level else { return }
        show(HUDState(kind: .volume, level: level, muted: AudioVolume.shared.muted))
    }

    private static let sampleQueue = DispatchQueue(label: "notchd.hud.sample", qos: .utility)
    private var sampling = false

    /// The readings ask system services, which can stall (around wake, or while they restart):
    /// take them off the main thread, and skip a turn while the last one is still out.
    private func sample() {
        guard !sampling else { return }
        sampling = true
        let keyboard = Settings.shared.prefs.hudKeyboard
        Self.sampleQueue.async { [weak self] in
            let brightness = Brightness.current()
            let backlight = keyboard ? KeyboardBacklight.current() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                guard self.enabled else { return }
                self.sampleBrightness(brightness)
                self.sampleKeyboard(backlight)
            }
        }
    }

    private func sampleBrightness(_ reading: Double?) {
        guard let value = reading else { return }
        defer { lastBrightness = value }
        guard let last = lastBrightness else { return }
        // Keys move brightness in big steps; auto-brightness drifts slowly. Only show the former.
        if abs(value - last) >= 0.02 || (state?.kind == .brightness && abs(value - last) > 0.001) {
            show(HUDState(kind: .brightness, level: value))
        }
    }

    /// The system overlay is paused while ours is on, so the keyboard backlight needs its own too.
    private func sampleKeyboard(_ reading: Double?) {
        guard Settings.shared.prefs.hudKeyboard, let value = reading else { return }
        defer { lastKeyboard = value }
        guard let last = lastKeyboard else { return }
        // The backlight also fades out by itself when you stop typing: only show changes you just made.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 2 else { return }
        // Ambient light dims it slowly on its own; key presses move it in steps.
        if abs(value - last) >= 0.03 || (state?.kind == .keyboard && abs(value - last) > 0.001) {
            show(HUDState(kind: .keyboard, level: value))
        }
    }

    func show(_ new: HUDState) {
        withAnimation(state == nil ? .notchOpen : .spring(response: 0.25, dampingFraction: 0.8)) { state = new }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(.notchClose) { self?.state = nil } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// One at a time and in order, off the main thread: these tools can take a moment.
    private static let overlayQueue = DispatchQueue(label: "notchd.overlay")

    /// Pauses (SIGSTOP) or resumes the process that draws the system overlay.
    private static func systemOverlay(paused: Bool, wait: Bool = false) {
        let work = {
            if paused {
                // It only runs once it has shown something: start it so there is a process to pause.
                run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.OSDUIHelper"])
                run("/usr/bin/killall", ["-STOP", "OSDUIHelper"])
            } else {
                run("/usr/bin/killall", ["-CONT", "OSDUIHelper"])
            }
        }
        if wait { overlayQueue.sync(execute: work) } else { overlayQueue.async(execute: work) }
    }

    private static func run(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }  // waiting on a process that never started throws
        process.waitUntilExit()
    }
}

// MARK: - Key tap

/// Sees the volume and brightness keys before macOS does and lets `HUDCenter` act on them instead.
/// Changing key events needs Accessibility access; without it `start()` returns false and nothing changes.
final class MediaKeyTap {
    static let shared = MediaKeyTap()
    fileprivate var port: CFMachPort?
    private var source: CFRunLoopSource?
    var isActive: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        if port != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1) << 14  // NX_SYSDEFINED: media keys
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: nil) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // macOS switches a tap off if it ever answers slowly: switch it back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = MediaKeyTap.shared.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }
    let code = (key.data1 & 0xFFFF_0000) >> 16
    let down = (key.data1 & 0xFF00) >> 8 == 0x0A
    let fine = key.modifierFlags.contains([.option, .shift])
    return HUDCenter.shared.handleKey(code: code, down: down, fine: fine) ? nil : Unmanaged.passUnretained(event)
}

extension Notification.Name {
    static let prefsChanged = Notification.Name("notchd.prefsChanged")
}

// MARK: - Views

struct HUDLeading: View {
    let state: HUDState

    var body: some View {
        // The waves fill in with the level, and the icon gives a little bounce on every step.
        Image(systemName: icon, variableValue: state.level)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: Int((state.level * 16).rounded()))
            .frame(width: 24)
    }

    private var icon: String {
        switch state.kind {
        case .brightness: state.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboard: state.level == 0 ? "light.min" : "light.max"
        case .volume: state.muted || state.level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        }
    }
}

struct HUDTrailing: View {
    let state: HUDState

    var body: some View {
        Text("\(Int((state.muted ? 0 : state.level) * 100))")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: state.level))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: state.level)
    }
}

/// The level bar under the HUD row, in 16 steps like the keyboard keys.
struct HUDBar: View {
    let state: HUDState

    var body: some View {
        let level = state.muted ? 0 : state.level
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [color(level).opacity(0.75), color(level)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(max(level, 0), 1)))
                    .shadow(color: color(level).opacity(0.6), radius: 4)
                    .opacity(level > 0 ? 1 : 0)
            }
        }
        .frame(height: 6)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: level)
    }

    private func color(_ level: Double) -> Color {
        if state.kind == .brightness { return .yellow }
        if state.kind == .keyboard { return .cyan }
        guard Settings.shared.prefs.hudColoredVolume else { return .white }
        return level > 0.9 ? .red : level > 0.7 ? .orange : .white
    }
}
