import Foundation
import MLX

/// The speech engine: owns the model and runs every MLX call on one dedicated serial queue,
/// so GPU waits never block Swift's cooperative thread pool.
public actor ParakeetEngine {
    private let queue = DispatchSerialQueue(label: "ParakeetKit.engine", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var model: ParakeetModel?

    public init() {}

    public var isLoaded: Bool { model != nil }

    /// Loads the snapshot in `directory` and compiles the GPU kernels with a short warm-up pass.
    public func load(directory: URL = ModelFiles.defaultDirectory, precision: Precision = .float16) throws {
        guard model == nil else { return }
        // Keep the idle footprint small: MLX may otherwise hold on to freed buffers.
        Memory.cacheLimit = 256 * 1024 * 1024
        let model = try ParakeetModel(directory: directory, precision: precision)
        _ = model.transcribe([Float](repeating: 0, count: Features.sampleRate))
        _ = model.speechRegions([Float](repeating: 0, count: Features.sampleRate))
        Memory.clearCache()
        self.model = model
    }

    /// Transcribes 16 kHz mono audio. Anything longer than 30 s is cut at the pauses the model's
    /// VAD head finds, and the pieces are joined.
    public func transcribe(_ samples: [Float]) throws -> Transcript {
        guard let model else { throw ParakeetError.notLoaded }
        let started = ContinuousClock.now
        var ranges = [0 ..< samples.count]
        if Double(samples.count) > Segmenter.segmentSeconds * Segmenter.sampleRate {
            ranges = Segmenter.segments(count: samples.count, speech: speech(in: samples, using: model))
        }
        var transcript = Transcript.empty
        for range in ranges {
            let part = model.transcribe(Array(samples[range]))
            transcript.text = [transcript.text, part.text].filter { !$0.isEmpty }.joined(separator: " ")
            transcript.tokenIDs += part.tokenIDs
        }
        transcript.audioSeconds = Double(samples.count) / Segmenter.sampleRate
        let elapsed = ContinuousClock.now - started
        transcript.processingSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        Memory.clearCache()
        return transcript
    }

    /// For a recording in progress: how many of the `pending` samples can be committed as a
    /// finished segment now (cut in a pause), or `nil` to keep waiting.
    public func progressiveCut(_ pending: [Float]) -> Int? {
        guard let model, Double(pending.count) >= Segmenter.progressiveSeconds * Segmenter.sampleRate else { return nil }
        return Segmenter.progressiveCut(count: pending.count, speech: model.speechRegions(pending))
    }

    /// Speech regions for the whole recording, marked in 120 s blocks.
    private func speech(in samples: [Float], using model: ParakeetModel) -> [Segmenter.Span] {
        let block = Int(Segmenter.blockSeconds * Segmenter.sampleRate)
        return stride(from: 0, to: samples.count, by: block).flatMap { start in
            let offset = Double(start) / Segmenter.sampleRate
            return model.speechRegions(Array(samples[start ..< min(samples.count, start + block)]))
                .map { Segmenter.Span(start: $0.start + offset, end: $0.end + offset) }
        }
    }
}
