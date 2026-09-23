import AppKit
import ParakeetKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--transcribe") { CommandLineTranscriber.run() }
        NoTypeApp.main()
    }
}

struct NoTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: delegate.app)
        } label: {
            Image(systemName: delegate.app.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(app: delegate.app)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
        let arguments = CommandLine.arguments
        if arguments.contains("--onboarding") { app.showOnboarding() }
        if let index = arguments.firstIndex(of: "--hud-demo") {
            app.runHUDDemo(arguments.indices.contains(index + 1) ? arguments[index + 1] : nil)
        }
    }
}

/// `NoType --transcribe a.wav b.m4a …`: runs the engine on files and reports speed.
enum CommandLineTranscriber {
    static func run() -> Never {
        let files = Array(CommandLine.arguments.drop { $0 != "--transcribe" }.dropFirst())
        Task {
            let engine = ParakeetEngine()
            let started = ContinuousClock.now
            do {
                try await engine.load()
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
            print("model ready in \(milliseconds(ContinuousClock.now - started)) ms")
            for path in files {
                do {
                    let samples = try AudioFile.samples(at: URL(filePath: path))
                    for run in 1 ... 2 {
                        let transcript = try await engine.transcribe(samples)
                        let speed = transcript.audioSeconds / max(transcript.processingSeconds, 1e-6)
                        print(String(
                            format: "%@ [run %d] %.1f s audio in %.0f ms (%.0fx real time)",
                            (path as NSString).lastPathComponent, run, transcript.audioSeconds,
                            transcript.processingSeconds * 1000, speed))
                        if run == 2 { print(transcript.text) }
                    }
                } catch {
                    print("\(path): \(error.localizedDescription)")
                }
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
