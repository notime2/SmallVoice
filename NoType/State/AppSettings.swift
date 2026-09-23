import AppKit
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    static let dictation = Self("dictation")
}

/// The key that starts and stops dictation.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, function, custom

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .function: "Fn (🌐)"
        case .custom: "Custom Shortcut"
        }
    }

    /// Short name for hints such as "Hold Right ⌥ to dictate".
    @MainActor var shortName: String {
        switch self {
        case .rightOption: String(localized: "Right ⌥")
        case .rightCommand: String(localized: "Right ⌘")
        case .function: "Fn"
        case .custom: KeyboardShortcuts.getShortcut(for: .dictation)?.description ?? String(localized: "your shortcut")
        }
    }

    /// Virtual key code of the modifier (`kVK_RightOption`, `kVK_RightCommand`, `kVK_Function`).
    var keyCode: UInt16? {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .function: 63
        case .custom: nil
        }
    }

    /// Whether the trigger is down in a `flagsChanged` event, using the device-dependent side bits.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: flags.rawValue & 0x40 != 0  // NX_DEVICERALTKEYMASK
        case .rightCommand: flags.rawValue & 0x10 != 0  // NX_DEVICERCMDKEYMASK
        case .function: flags.contains(.function)
        case .custom: false
        }
    }

    /// True when nothing but the trigger itself is held, so ⌘⌥-style chords never start dictation.
    func isAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        let others: NSEvent.ModifierFlags
        switch self {
        case .rightOption:
            others = [.command, .control, .shift]
            if flags.rawValue & 0x20 != 0 { return false }  // left Option too
        case .rightCommand:
            others = [.option, .control, .shift]
            if flags.rawValue & 0x08 != 0 { return false }  // left Command too
        case .function:
            others = [.command, .option, .control, .shift]
        case .custom:
            return false
        }
        return flags.intersection(others).isEmpty
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let trigger = "trigger"
        static let playSounds = "playSounds"
        static let smartSpacing = "smartSpacing"
        static let restoreClipboard = "restoreClipboard"
        static let microphoneUID = "microphoneUID"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onTriggerChange: ((TriggerKey) -> Void)?

    var trigger: TriggerKey {
        didSet {
            defaults.set(trigger.rawValue, forKey: Key.trigger)
            onTriggerChange?(trigger)
        }
    }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: Key.smartSpacing) } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    /// `nil` follows the system default input.
    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.playSounds: true, Key.smartSpacing: true, Key.restoreClipboard: true,
        ])
        trigger = defaults.string(forKey: Key.trigger).flatMap(TriggerKey.init(rawValue:)) ?? .rightOption
        playSounds = defaults.bool(forKey: Key.playSounds)
        smartSpacing = defaults.bool(forKey: Key.smartSpacing)
        restoreClipboard = defaults.bool(forKey: Key.restoreClipboard)
        microphoneUID = defaults.string(forKey: Key.microphoneUID)
    }
}
