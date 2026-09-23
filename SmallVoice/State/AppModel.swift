import AppKit
import Observation
import ParakeetKit
import SwiftUI

struct HistoryItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date

    var preview: String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }
}

/// Owns every part of the app and wires them together.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let permissions = Permissions()
    let modelStore = ModelStore()
    let dictation: DictationController
    @ObservationIgnored let hud: HUDController
    private(set) var history: [HistoryItem] = []

    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private var onboardingWindow: NSWindow?

    init() {
        let meter = LevelMeter()
        hud = HUDController(meter: meter)
        dictation = DictationController(
            settings: settings, permissions: permissions, modelStore: modelStore, hud: hud, meter: meter)
        dictation.onTranscript = { [weak self] text in self?.remember(text) }
    }

    func start() {
        modelStore.prepare()
        hotkeys.onEvent = { [weak self] event in self?.dictation.handle(event) }
        hotkeys.start(trigger: settings.trigger)
        settings.onTriggerChange = { [weak self] trigger in self?.hotkeys.start(trigger: trigger) }
        // Global key monitors only start delivering once the app is trusted, so install them again then.
        permissions.onAccessibilityGranted = { [weak self] in
            guard let self else { return }
            self.hotkeys.start(trigger: self.settings.trigger)
        }
        if !permissions.allGranted || !ModelFiles.isComplete() { showOnboarding() }
    }

    // MARK: - Menu

    var menuBarSymbol: String {
        if dictation.isRecording { return "waveform.circle.fill" }
        if dictation.pending > 0 { return "ellipsis.circle" }
        switch modelStore.status {
        case .downloading, .verifying: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "waveform"
        }
    }

    var statusLine: String {
        if dictation.isRecording { return String(localized: "Listening…") }
        switch modelStore.status {
        case .checking, .loading: return String(localized: "Loading the speech model…")
        case .downloading(let progress):
            return String(localized: "Downloading the speech model… \(Int(progress * 100))%")
        case .verifying: return String(localized: "Checking the speech model…")
        case .failed: return String(localized: "The speech model is not available")
        case .ready:
            if !permissions.accessibility { return String(localized: "Needs Accessibility access") }
            if !permissions.microphoneGranted { return String(localized: "Needs microphone access") }
            return String(localized: "Hold \(settings.trigger.shortName) to dictate")
        }
    }

    var needsSetup: Bool { !permissions.allGranted || !modelStore.isReady }

    func copy(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    func clearHistory() { history.removeAll() }

    private func remember(_ text: String) {
        history.insert(HistoryItem(text: text, date: .now), at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }
    }

    // MARK: - Windows

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            let controller = NSHostingController(rootView: OnboardingView(app: self) { [weak window] in window?.close() })
            window.contentViewController = controller
            window.setContentSize(controller.view.fittingSize)
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        // Launched from Finder the app is already active; from elsewhere, still come to the front.
        onboardingWindow?.orderFrontRegardless()
    }

    func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: String(localized: "Speech recognition runs entirely on this Mac.\nModel: Parakeet Redux by Moondream, based on NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0)."),
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: - HUD demo (`--hud-demo [recording|hands-free|processing|success|message]`)

    /// Shows the HUD states without recording, for design checks. With a state name it stays on
    /// that state; without one it cycles through all of them.
    func runHUDDemo(_ name: String?) {
        let states: [String: HUDState] = [
            "recording": .recording(handsFree: false), "hands-free": .recording(handsFree: true),
            "processing": .processing, "success": .success,
            "message": .message(String(localized: "No speech recognized"), symbol: "waveform.slash"),
        ]
        let meter = dictation.meter
        Task {
            // A fake voice for the level bars.
            let started = ContinuousClock.now
            while !Task.isCancelled {
                let t = (ContinuousClock.now - started) / .seconds(1)
                meter.update(Float(0.45 + 0.35 * sin(t * 2.3) * sin(t * 0.7 + 1)))
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        Task {
            if let name, let state = states[name] {
                hud.show(state)
                return
            }
            for name in ["recording", "hands-free", "processing", "success", "message"] {
                hud.show(states[name]!)
                try? await Task.sleep(for: .seconds(2.2))
            }
            hud.hide()
        }
    }
}
