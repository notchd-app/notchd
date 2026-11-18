import AudioToolbox
import CoreAudio
import SwiftUI

struct AudioOutput: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var icon: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("homepod") { return "homepod.fill" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// CoreAudio device list and the default output, which the media widget lets you switch.
enum AudioDevices {
    static func all() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func name(_ device: AudioObjectID) -> String {
        var address = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }

    static func transport(_ device: AudioObjectID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    /// Devices you can play sound through, hiding the ones apps create for themselves (Zoom, Teams…).
    static func outputs() -> [AudioOutput] {
        all()
            .filter { streamCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
            .map { AudioOutput(id: $0, name: name($0), transport: transport($0)) }
            .filter { output in !output.name.isEmpty && !hiddenNames.contains { output.name.contains($0) } }
    }

    private static let hiddenNames = ["ZoomAudioDevice", "Microsoft Teams Audio", "CADefaultDeviceAggregate"]

    static var defaultOutput: AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// Sends sound and alerts to `device`, like picking it in Control Center.
    static func setDefaultOutput(_ device: AudioObjectID) {
        var id = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = address(selector, scope: kAudioObjectPropertyScopeGlobal)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id)
        }
    }

    /// 0...1 on the default output, when the device has a software volume.
    static func setVolume(_ level: Double) {
        var volume = Float32(min(max(level, 0), 1))
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        let device = defaultOutput
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if volume > 0 {
            var mute = UInt32(0)
            var muteAddress = self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        }
    }

    /// Whether the default output has a volume we can set (HDMI and some USB outputs don't).
    static var canSetVolume: Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(defaultOutput, &address, &settable) == noErr && settable.boolValue
    }

    static func setMuted(_ muted: Bool) {
        var mute = UInt32(muted ? 1 : 0)
        var address = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectSetPropertyData(defaultOutput, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

/// Speaker button in the media widget: pick where sound goes and set the volume.
struct AudioOutputButton: View {
    @Local private var showing = false

    var body: some View {
        Button {
            showing.toggle()
            Haptics.tap()
        } label: {
            Image(systemName: current?.icon ?? "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(BouncyButtonStyle())
        .help(Text("Sound output"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            AudioOutputPicker()
        }
    }

    private var current: AudioOutput? {
        let id = AudioDevices.defaultOutput
        return AudioDevices.outputs().first { $0.id == id }
    }
}

private struct AudioOutputPicker: View {
    private var volume = AudioVolume.shared
    @Local private var outputs = AudioDevices.outputs()
    @Local private var selected = AudioDevices.defaultOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let level = volume.level {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { volume.muted ? 0 : level }, set: { AudioDevices.setVolume($0) }), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Divider()
            }
            Text("Output").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(outputs) { output in
                Button {
                    AudioDevices.setDefaultOutput(output.id)
                    selected = output.id
                    Haptics.tap()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: output.icon)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(selected == output.id ? Color.accentColor : .secondary.opacity(0.2)))
                            .foregroundStyle(selected == output.id ? .white : .primary)
                        Text(output.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 240)
        .onAppear {
            outputs = AudioDevices.outputs()
            selected = AudioDevices.defaultOutput
        }
    }
}
