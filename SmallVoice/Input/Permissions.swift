import AVFoundation
import AppKit
import ApplicationServices
import Observation

/// Microphone and Accessibility access, kept current while anything is still missing.
@MainActor
@Observable
final class Permissions {
    enum Pane {
        case microphone, accessibility

        var url: URL {
            switch self {
            case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }
    }

    private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibility = AXIsProcessTrusted()

    /// Called when Accessibility access arrives; event monitors have to be installed again then.
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var microphoneGranted: Bool { microphone == .authorized }
    var allGranted: Bool { microphoneGranted && accessibility }

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust database is updated a moment after this notification is posted.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                self?.refresh()
            }
        }
        pollWhileMissing()
    }

    func refresh() {
        check()
        pollWhileMissing()
    }

    private func check() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != microphone { microphone = status }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility {
            accessibility = trusted
            if trusted { onAccessibilityGranted?() }
        }
    }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        } else if !microphoneGranted {
            open(.microphone)
        }
    }

    func requestAccessibility() {
        // Shows the system prompt the first time; System Settings is where the switch lives.
        let prompted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !prompted { open(.accessibility) }
        pollWhileMissing()
    }

    func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    /// Accessibility has no reliable change callback, so check every 1.5 s until everything is granted.
    private func pollWhileMissing() {
        guard !allGranted else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.check()
                if self.allGranted {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
