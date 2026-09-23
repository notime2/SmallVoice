import AppKit
import CoreAudio
import Synchronization
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "NoType"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let insert = Logger(subsystem: subsystem, category: "insert")
    static let model = Logger(subsystem: subsystem, category: "model")
}

/// The latest input level in 0…1, written by the audio thread and read by the HUD every frame.
final class LevelMeter: Sendable {
    private let bits = Atomic<UInt32>(0)

    var level: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }

    func update(_ value: Float) { bits.store(value.bitPattern, ordering: .relaxed) }

    /// Maps an RMS amplitude to 0…1 on a -55…-12 dBFS scale, which is where speech lives.
    static func normalized(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 55) / 43, 0), 1)
    }
}

@MainActor
enum Sounds {
    enum Cue { case start, stop }

    private static let start = NSSound(named: "Tink")
    private static let stop = NSSound(named: "Pop")

    static func play(_ cue: Cue) {
        guard let sound = cue == .start ? start : stop else { return }
        sound.stop()
        sound.volume = 0.22
        sound.play()
    }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Core Audio input device lookup.
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
