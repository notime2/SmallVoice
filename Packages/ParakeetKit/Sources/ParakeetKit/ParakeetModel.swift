import Foundation
import MLX
import os

/// Compute precision for activations and the non-ternary weights.
public enum Precision: String, Sendable, CaseIterable {
    case float16, bfloat16, float32

    var dtype: DType {
        switch self {
        case .float16: .float16
        case .bfloat16: .bfloat16
        case .float32: .float32
        }
    }
}

public struct Transcript: Sendable, Equatable {
    public var text: String
    public var tokenIDs: [Int]
    public var audioSeconds: Double
    public var processingSeconds: Double

    public static let empty = Transcript(text: "", tokenIDs: [], audioSeconds: 0, processingSeconds: 0)
}

/// Parakeet TDT with a ternary encoder, loaded from a `moondream/parakeet-redux` snapshot.
/// Not thread-safe: use it from one isolation domain (``ParakeetEngine`` does that).
final class ParakeetModel {
    private let features = Features()
    private let encoder: Encoder
    private let decoder: TDTDecoder
    private let voiceActivity: VoiceActivityHead
    private let tokenizer: Tokenizer
    private static let signposter = OSSignposter(subsystem: "ParakeetKit", category: "Parakeet")

    init(directory: URL, precision: Precision) throws {
        for file in ModelFiles.files
        where !FileManager.default.fileExists(atPath: directory.appending(path: file.name).path(percentEncoded: false)) {
            throw ParakeetError.missingFile(file.name)
        }
        let config = try ParakeetConfig.load(from: directory.appending(path: "config.json"))
        tokenizer = try Tokenizer(url: directory.appending(path: "tokenizer.json"))
        let weights = try WeightStore(url: directory.appending(path: "model.safetensors"), dtype: precision.dtype)
        encoder = try Encoder(weights, config: config.encoderConfig)
        decoder = try TDTDecoder(weights, config: config)
        voiceActivity = try VoiceActivityHead(weights)
        let leftovers = weights.remainingNames
        guard leftovers.isEmpty else {
            throw ParakeetError.unsupportedModel("unused tensors: \(leftovers.prefix(3).joined(separator: ", "))")
        }
    }

    /// Speech regions from the checkpoint's own VAD head, in seconds.
    func speechRegions(_ samples: [Float]) -> [Segmenter.Span] {
        let duration = Double(samples.count) / Double(Features.sampleRate)
        guard samples.count >= Features.minimumSamples else { return [Segmenter.Span(start: 0, end: duration)] }
        let (melFeatures, validFrames) = features(samples)
        let (hidden, length) = encoder.subsample(melFeatures, validFrames: validFrames)
        guard length > 0 else { return [] }
        let probabilities = voiceActivity(hidden)[..<length].asArray(Float.self)
        return Segmenter.speechRegions(probabilities, duration: duration)
    }

    /// Transcribes one segment of 16 kHz mono audio (up to 30 s, see `Segmenter`).
    func transcribe(_ samples: [Float]) -> Transcript {
        let started = ContinuousClock.now
        let audioSeconds = Double(samples.count) / Double(Features.sampleRate)
        guard samples.count >= Features.minimumSamples else { return .empty }

        let state = Self.signposter.beginInterval("transcribe", "\(audioSeconds, format: .fixed(precision: 2)) s")
        defer { Self.signposter.endInterval("transcribe", state) }

        let (melFeatures, validFrames) = features(samples)
        guard let encoded = encoder(melFeatures, validFrames: validFrames) else { return .empty }
        eval(encoded)
        let tokens = decoder.decode(encoded)
        let elapsed = ContinuousClock.now - started
        return Transcript(
            text: tokenizer.decode(tokens),
            tokenIDs: tokens,
            audioSeconds: audioSeconds,
            processingSeconds: Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
    }
}
