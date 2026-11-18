import AVFoundation
import CoreAudio
import CoreMediaIO
import SwiftUI

/// Which capture devices some app is using right now, from CoreAudio and CoreMediaIO's
/// "running somewhere" flags. No permission needed: it never touches the devices themselves.
@Observable
final class PrivacyMonitor {
    static let shared = PrivacyMonitor()
    private(set) var camera = false
    private(set) var microphone = false
    private var timer: Timer?

    var inUse: Bool { camera || microphone }

    /// Follows the activity's switch: polls once a second while it's on.
    func apply() {
        let prefs = Settings.shared.prefs
        let wanted = prefs.isEnabled(.privacy) && prefs.liveActivitiesEnabled
        if wanted, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            refresh()
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
            camera = false
            microphone = false
        }
    }

    private static let queue = DispatchQueue(label: "notchd.privacy", qos: .utility)
    private var checking = false

    /// Asks the audio and camera services off the main thread: they can stall while a device is being
    /// plugged in or after wake, and the notch shouldn't freeze with them.
    private func refresh() {
        guard !checking else { return }
        checking = true
        // The Mirror widget is us: don't warn about our own camera.
        let mirror = Camera.shared.session.isRunning
        Self.queue.async { [weak self] in
            let cam = Self.cameraRunning() && !mirror
            let mic = Self.microphoneRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                guard self.timer != nil, cam != self.camera || mic != self.microphone else { return }
                withAnimation(cam || mic ? .notchOpen : .notchClose) {
                    self.camera = cam
                    self.microphone = mic
                }
            }
        }
    }

    // MARK: Microphone

    static func microphoneRunning() -> Bool {
        inputDevices().contains { device in
            var running = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
        }
    }

    /// Every audio device with at least one input stream.
    static func inputDevices() -> [AudioObjectID] {
        AudioDevices.all().filter { AudioDevices.streamCount($0, scope: kAudioObjectPropertyScopeInput) > 0 }
    }

    // MARK: Camera

    static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        return devices.contains { device in
            var running = UInt32(0)
            let runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningUsed: UInt32 = 0
            var prop = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            return CMIOObjectGetPropertyData(device, &prop, 0, nil, runningSize, &runningUsed, &running) == noErr
                && running != 0
        }
    }
}

// MARK: - Live activity

struct PrivacyActivityLeading: View {
    let camera: Bool
    let microphone: Bool

    var body: some View {
        Image(systemName: camera ? "video.fill" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(camera ? .green : .orange)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// The other device's icon when both are in use, otherwise the menu bar's dot.
struct PrivacyActivityTrailing: View {
    let camera: Bool
    let microphone: Bool

    var body: some View {
        if camera && microphone {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                Circle()
                    .fill(camera ? Color.green : .orange)
                    .frame(width: 8, height: 8)
                    .opacity(0.65 + 0.35 * sin(timeline.date.timeIntervalSinceReferenceDate * 3))
            }
        }
    }
}
