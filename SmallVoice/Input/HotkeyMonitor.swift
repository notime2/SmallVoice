import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

/// Turns the chosen trigger into press/release events.
///
/// Modifier-only triggers (right ⌥, right ⌘, Fn) are watched through `NSEvent` monitors, which
/// need Accessibility access; a custom chord goes through KeyboardShortcuts (Carbon hot keys).
@MainActor
final class HotkeyMonitor {
    enum Event {
        case pressed, released
        /// Another key joined while the trigger was held, i.e. the user is typing a shortcut.
        case interrupted
        case escape
    }

    var onEvent: ((Event) -> Void)?

    private var monitors: [Any] = []
    private var trigger: TriggerKey = .rightOption
    private var isHeld = false

    func start(trigger: TriggerKey) {
        stop()
        self.trigger = trigger
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }

        if trigger == .custom {
            KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
                MainActor.assumeIsolated { self?.onEvent?(.pressed) }
            }
            KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
                MainActor.assumeIsolated { self?.onEvent?(.released) }
            }
        }
        Log.hotkey.info("Listening for \(trigger.rawValue, privacy: .public)")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        KeyboardShortcuts.removeHandler(for: .dictation)
        isHeld = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) {
                onEvent?(.escape)
            } else if isHeld {
                onEvent?(.interrupted)
            }
        case .flagsChanged:
            guard let keyCode = trigger.keyCode else { return }
            if event.keyCode == keyCode {
                let down = trigger.isDown(event.modifierFlags)
                if down, !isHeld, trigger.isAlone(event.modifierFlags) {
                    isHeld = true
                    onEvent?(.pressed)
                } else if !down, isHeld {
                    isHeld = false
                    onEvent?(.released)
                }
            } else if isHeld {
                onEvent?(.interrupted)
            }
        default:
            break
        }
    }
}
