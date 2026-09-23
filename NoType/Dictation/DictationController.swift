import AppKit
import Observation
import ParakeetKit

/// Hold-to-talk and tap-to-toggle on one key, and the record -> transcribe -> insert pipeline.
@MainActor
@Observable
final class DictationController {
    enum Mode: Equatable {
        case idle
        /// Recording while the trigger is held; a short tap turns into hands-free.
        case holding(since: ContinuousClock.Instant)
        case handsFree
    }

    /// Holding longer than this is push-to-talk; a shorter tap keeps listening hands-free.
    static let holdThreshold: Duration = .milliseconds(300)
    static let maximumDuration: Duration = .seconds(600)
    /// Anything shorter than 0.3 s is an accidental tap, not dictation.
    static let minimumSamples = SpeechAudio.sampleRate * 3 / 10

    private(set) var mode: Mode = .idle
    /// Number of recordings still being transcribed or inserted.
    private(set) var pending = 0

    var isRecording: Bool { mode != .idle }
    var meter: LevelMeter { recorder.meter }
    @ObservationIgnored var onTranscript: ((String) -> Void)?

    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let modelStore: ModelStore
    @ObservationIgnored private let hud: HUDController
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var sessionCount = 0
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    init(settings: AppSettings, permissions: Permissions, modelStore: ModelStore, hud: HUDController, meter: LevelMeter) {
        self.settings = settings
        self.permissions = permissions
        self.modelStore = modelStore
        self.hud = hud
        recorder = AudioRecorder(meter: meter)
        recorder.onInterruption = { [weak self] in self?.finish() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func handle(_ event: HotkeyMonitor.Event) {
        switch (event, mode) {
        case (.pressed, .idle):
            start(handsFree: false)
        case (.pressed, .handsFree):
            finish()
        case (.released, .holding(let since)):
            if ContinuousClock.now - since >= Self.holdThreshold {
                finish()
            } else {
                mode = .handsFree
                hud.show(.recording(handsFree: true))
            }
        case (.interrupted, .holding), (.escape, .holding), (.escape, .handsFree):
            cancel()
        default:
            break
        }
    }

    /// Menu item: start hands-free, or finish the current recording.
    func toggle() {
        if mode == .idle { start(handsFree: true) } else { finish() }
    }

    // MARK: - Recording

    private func start(handsFree: Bool) {
        guard permissions.microphoneGranted else {
            if permissions.microphone == .notDetermined {
                Task { await permissions.requestMicrophone() }
            } else {
                hud.flash(.message(String(localized: "Allow microphone access in System Settings"), symbol: "mic.slash"))
                permissions.open(.microphone)
            }
            return
        }
        if modelStore.isFailed { modelStore.prepare() }

        do {
            try recorder.start(deviceUID: settings.microphoneUID)
        } catch {
            Log.audio.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            hud.flash(.message(error.localizedDescription, symbol: "mic.slash"))
            return
        }
        sessionCount += 1
        session = Session(id: sessionCount, engine: modelStore.engine)
        mode = handsFree ? .handsFree : .holding(since: .now)
        hud.show(.recording(handsFree: handsFree))
        if settings.playSounds { Sounds.play(.start) }

        watchdog = Task { [weak self] in
            var elapsed: Duration = .zero
            while !Task.isCancelled, elapsed < Self.maximumDuration {
                try? await Task.sleep(for: .seconds(1))
                elapsed += .seconds(1)
                guard let self, !Task.isCancelled else { return }
                // Long dictation: hand finished stretches to the engine while the user keeps talking.
                if self.modelStore.isReady { await self.session?.commitReadySegments(from: self.recorder) }
            }
            if !Task.isCancelled { self?.finish() }
        }
    }

    private func finish() {
        guard let session else { return }
        watchdog?.cancel()
        let samples = recorder.stop()
        self.session = nil
        mode = .idle
        if settings.playSounds { Sounds.play(.stop) }

        guard samples.count >= Self.minimumSamples else {
            session.discard()
            hud.hide()
            return
        }
        guard samples.contains(where: { abs($0) > 1e-4 }) else {
            session.discard()
            hud.flash(.message(String(localized: "The microphone is silent"), symbol: "mic.slash"))
            return
        }

        hud.show(.processing)
        pending += 1
        Task {
            defer { pending -= 1 }
            guard await modelStore.waitUntilReady() else {
                showIfCurrent(session, .message(String(localized: "The speech model is not available"), symbol: "exclamationmark.triangle"))
                return
            }
            do {
                let text = try await session.finish(with: samples)
                guard !text.isEmpty else {
                    showIfCurrent(session, .message(String(localized: "No speech recognized"), symbol: "waveform.slash"))
                    return
                }
                let outcome = await TextInserter.insert(
                    text, smartSpacing: settings.smartSpacing, restoreClipboard: settings.restoreClipboard)
                onTranscript?(text)
                switch outcome {
                case .pasted: showIfCurrent(session, .success)
                case .copiedOnly:
                    showIfCurrent(session, .message(String(localized: "Copied - press ⌘V to paste"), symbol: "doc.on.clipboard"))
                }
            } catch {
                Log.model.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                showIfCurrent(session, .message(error.localizedDescription, symbol: "exclamationmark.triangle"))
            }
        }
    }

    private func cancel() {
        guard let session else { return }
        watchdog?.cancel()
        _ = recorder.stop()
        session.discard()
        self.session = nil
        mode = .idle
        hud.hide()
    }

    /// Results of an older recording must not cover the HUD of a newer one.
    private func showIfCurrent(_ session: Session, _ state: HUDState) {
        guard session.id == sessionCount, mode == .idle else { return }
        hud.flash(state)
    }
}

/// One recording's transcription: segments committed while recording, plus the tail at the end.
@MainActor
private final class Session {
    let id: Int
    private let engine: ParakeetEngine
    private var committed = 0
    private var parts: [Task<String, Error>] = []
    private var isFinishing = false

    /// Pending audio is only worth a look once it could hold a segment.
    private static let progressiveSamples = SpeechAudio.sampleRate * 20

    init(id: Int, engine: ParakeetEngine) {
        self.id = id
        self.engine = engine
    }

    func commitReadySegments(from recorder: AudioRecorder) async {
        guard !isFinishing, recorder.sampleCount - committed >= Self.progressiveSamples else { return }
        let pending = recorder.samples(from: committed)
        guard let cut = await engine.progressiveCut(pending), !isFinishing else { return }
        let segment = Array(pending[..<cut])
        committed += cut
        let engine = engine
        parts.append(Task { try await engine.transcribe(segment).text })
    }

    func finish(with samples: [Float]) async throws -> String {
        // From here on a late progressive cut is ignored; its audio is part of the tail.
        isFinishing = true
        let tail = committed < samples.count ? Array(samples[committed...]) : []
        var texts: [String] = []
        for part in parts { texts.append(try await part.value) }
        if tail.count >= SpeechAudio.minimumSamples { texts.append(try await engine.transcribe(tail).text) }
        return texts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func discard() {
        isFinishing = true
        parts.forEach { $0.cancel() }
        parts.removeAll()
    }
}
