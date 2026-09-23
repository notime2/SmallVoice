import SwiftUI

/// First-run setup: the two permissions and the model download, with live status.
struct OnboardingView: View {
    let app: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 68, height: 68)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.15)), in: .circle)
                Text("Welcome to NoType")
                    .font(.title2.weight(.semibold))
                Text("Dictate into any app. Your voice is recognized on this Mac and never leaves it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    SetupStep(
                        symbol: "mic.fill", title: "Microphone",
                        detail: "So NoType can hear you while you dictate.",
                        state: app.permissions.microphoneGranted ? .done : .action("Allow") {
                            Task { await app.permissions.requestMicrophone() }
                        })
                    SetupStep(
                        symbol: "accessibility", title: "Accessibility",
                        detail: "For the shortcut and for typing the text where your cursor is.",
                        state: app.permissions.accessibility ? .done : .action("Open Settings") {
                            app.permissions.requestAccessibility()
                        })
                    SetupStep(
                        symbol: "cpu", title: "Speech model",
                        detail: "Parakeet Redux, 178 MB, downloaded once.",
                        state: modelState)
                }
            }

            VStack(spacing: 12) {
                if app.permissions.allGranted && app.modelStore.isReady {
                    Text("All set. Hold \(app.settings.trigger.shortName) and speak, then release to insert the text.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                Button(action: close) {
                    Text(app.permissions.allGranted && app.modelStore.isReady ? "Start Dictating" : "Continue Later")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 460)
        .animation(.smooth, value: app.permissions.allGranted)
        .animation(.smooth, value: app.modelStore.status)
        .onAppear { app.permissions.refresh() }
    }

    private var modelState: SetupStep.State {
        switch app.modelStore.status {
        case .ready: .done
        case .downloading(let progress): .progress(progress)
        case .checking, .loading, .verifying: .progress(nil)
        case .failed: .action("Retry") { app.modelStore.prepare() }
        }
    }
}

private struct SetupStep: View {
    enum State {
        case done
        case progress(Double?)
        case action(LocalizedStringKey, () -> Void)
    }

    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let state: State

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .progress(let value):
            if let value {
                ProgressView(value: value).frame(width: 70)
            } else {
                ProgressView().controlSize(.small)
            }
        case .action(let label, let perform):
            Button(label, action: perform)
                .buttonStyle(.glass)
        }
    }
}
