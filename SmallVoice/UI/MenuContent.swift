import SwiftUI

struct MenuContent: View {
    let app: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(app.statusLine)

        Button(app.dictation.isRecording ? "Stop Dictation" : "Start Dictation") {
            app.dictation.toggle()
        }

        if !app.history.isEmpty {
            Menu("Recent Dictations") {
                ForEach(app.history) { item in
                    Button(item.preview) { app.copy(item) }
                }
                Divider()
                Button("Clear Recent") { app.clearHistory() }
            }
        }

        Divider()

        if app.needsSetup {
            Button("Finish Setup…") { app.showOnboarding() }
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("About SmallVoice") { app.showAbout() }

        Divider()

        Button("Quit SmallVoice") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
