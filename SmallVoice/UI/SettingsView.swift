import KeyboardShortcuts
import ParakeetKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let app: AppModel

    @State private var devices = AudioDevices.inputDevices()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Shortcut", selection: $settings.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                if settings.trigger == .custom {
                    KeyboardShortcuts.Recorder("Custom shortcut", name: .dictation)
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Hold the key while you speak and release it to insert the text. Tap it once to keep listening hands-free, and tap again to finish. Press Esc to cancel.")
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input", selection: $settings.microphoneUID) {
                    Text("System Default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
            }

            Section("Text") {
                Toggle("Add a space when continuing a sentence", isOn: $settings.smartSpacing)
                Toggle("Restore the clipboard after inserting", isOn: $settings.restoreClipboard)
            }

            Section("General") {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone", symbol: "mic", granted: app.permissions.microphoneGranted
                ) {
                    Task { await app.permissions.requestMicrophone() }
                }
                PermissionRow(
                    title: "Accessibility", symbol: "accessibility", granted: app.permissions.accessibility
                ) {
                    app.permissions.requestAccessibility()
                }
            }

            Section {
                LabeledContent("Speech model") {
                    ModelStatusLabel(status: app.modelStore.status)
                }
                if app.modelStore.isFailed {
                    Button("Try Again") { app.modelStore.prepare() }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Parakeet Redux by Moondream, based on NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0). Speech is recognized entirely on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            devices = AudioDevices.inputDevices()
            app.permissions.refresh()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: request)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct ModelStatusLabel: View {
    let status: ModelStore.Status

    var body: some View {
        switch status {
        case .checking, .loading:
            Text("Loading…").foregroundStyle(.secondary)
        case .downloading(let progress):
            ProgressView(value: progress) {
                Text("Downloading \(Int(progress * 100))%")
            }
            .frame(width: 160)
        case .verifying:
            Text("Checking…").foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Text(reason).foregroundStyle(.red).lineLimit(2)
        }
    }
}
