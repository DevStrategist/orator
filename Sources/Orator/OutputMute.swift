import CoreAudio
import Foundation
import OratorCore

/// Mutes the default output while dictating, only when something is playing, and always restores
/// what it changed, including after a crash (the marker file is replayed on the next launch).
final class OutputMute {
    private let queue = DispatchQueue(label: "orator.output-mute")
    private var owed: AudioDeviceID?
    private var owedRate: Double?
    private static var marker: URL { OratorPaths.support.appendingPathComponent("muted-output.json") }

    func mute() {
        queue.async {
            guard self.owed == nil, let device = Self.defaultOutput(), Self.isRunning(device),
                  Self.muted(device) == false, Self.setMute(device, true) else { return }
            self.owed = device; self.owedRate = Self.sampleRate(device)
            if let uid = Self.uid(device) { try? JSONEncoder().encode(["uid": uid]).write(to: Self.marker, options: .atomic) }
        }
    }
    func restore() {
        queue.async {
            guard let device = self.owed else { return }
            self.owed = nil
            // A Bluetooth headset drops to its call codec while its mic is open; unmuting mid-switch is
            // lost, so wait (up to 5 s) for the output sample rate to return first.
            if let rate = self.owedRate {
                let deadline = Date().addingTimeInterval(5)
                while Self.sampleRate(device) != rate && Date() < deadline { usleep(50_000) }
            }
            // Only undo our own change; a user who unmuted meanwhile keeps their choice.
            if Self.muted(device) == true { _ = Self.setMute(device, false) }
            try? FileManager.default.removeItem(at: Self.marker)
        }
    }
    func recoverAfterCrash() {
        queue.async {
            guard let data = try? Data(contentsOf: Self.marker),
                  let uid = try? JSONDecoder().decode([String: String].self, from: data)["uid"] else { return }
            if let device = Self.device(uid), Self.muted(device) == true { _ = Self.setMute(device, false) }
            try? FileManager.default.removeItem(at: Self.marker)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func defaultOutput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }
    private static func isRunning(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
    private static func muted(_ device: AudioDeviceID) -> Bool? {
        var address = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
    private static func setMute(_ device: AudioDeviceID, _ mute: Bool) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = UInt32(mute ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
    private static func sampleRate(_ device: AudioDeviceID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(0), size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func uid(_ device: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    private static func device(_ uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { Self.uid($0) == uid }
    }
}
