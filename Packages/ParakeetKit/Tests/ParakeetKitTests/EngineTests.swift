import MLX
import XCTest

@testable import ParakeetKit

/// `PARAKEET_TEST_DEVICE=cpu` runs everything on MLX's CPU backend (CI machines without a usable GPU).
enum TestDevice {
    static let configure: Void = {
        if ProcessInfo.processInfo.environment["PARAKEET_TEST_DEVICE"] == "cpu" {
            Device.setDefault(device: .cpu)
        }
    }()
}

final class TernaryPackingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestDevice.configure
    }

    /// The checkpoint's base-3 rows, repacked for MLX, must dequantize to exactly `s · (code - 1)`.
    func testPackedTernaryDequantizesExactly() {
        let rows = 6, inFeatures = 384, groups = inFeatures / 128
        let codes = (0 ..< rows * inFeatures).map { _ in UInt8.random(in: 0 ... 2) }
        let scales = (0 ..< rows * groups).map { _ in Float.random(in: 0.001 ... 0.2) }

        // thrush-ternary-v2: element i of a row is base-3 digit i % 5 of byte i / 5, LSD first.
        let rowBytes = (inFeatures + 4) / 5
        var packed = [UInt8](repeating: 0, count: rows * rowBytes)
        for row in 0 ..< rows {
            for column in 0 ..< inFeatures {
                let power = [1, 3, 9, 27, 81][column % 5]
                packed[row * rowBytes + column / 5] += UInt8(Int(codes[row * inFeatures + column]) * power)
            }
        }

        let words = TernaryLinear.packMLX(MLXArray(packed, [rows, rowBytes]), inFeatures: inFeatures)
        let s = MLXArray(scales, [rows, groups])
        let weights = dequantized(words, scales: s, biases: -s, groupSize: 128, bits: 2)

        let expected = (0 ..< rows * inFeatures).map { index in
            let row = index / inFeatures, column = index % inFeatures
            return scales[row * groups + column / 128] * (Float(codes[index]) - 1)
        }
        XCTAssertEqual(weights.asArray(Float.self), expected)
    }

    func testRelativeShiftMatchesDefinition() {
        let heads = 2, length = 5, width = 2 * length - 1
        let values = (0 ..< heads * length * width).map { Float($0) }
        let scores = MLXArray(values, [1, heads, length, width])
        let shifted = ConformerLayer.relativeShift(scores, length: length).asArray(Float.self)
        var expected: [Float] = []
        for h in 0 ..< heads {
            for i in 0 ..< length {
                for j in 0 ..< length {
                    expected.append(values[(h * length + i) * width + (length - 1 - i + j)])
                }
            }
        }
        XCTAssertEqual(shifted, expected)
    }
}

final class FeatureTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestDevice.configure
    }

    /// Log-mel features against an independent librosa computation (`scripts/reference/features.py`).
    func testLogMelMatchesReference() throws {
        let samples = try AudioFile.samples(at: fixture("en", "wav"))
        let referenceURL = fixture("en.features", "bin")
        let reference = try Data(contentsOf: referenceURL).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let (features, valid) = Features()(samples)
        XCTAssertEqual(features.shape, [1 + samples.count / 160, 128])
        XCTAssertEqual(valid, samples.count / 160)
        let ours = features.asArray(Float.self)
        XCTAssertEqual(ours.count, reference.count)
        let worst = zip(ours, reference).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(worst, 1e-3, "max abs difference \(worst)")
    }

    func testSegmenterCutsLongAudioAtPauses() {
        // 50 s of speech with 0.7 s pauses; the last pause inside the first 30 s is 23.9-24.6 s.
        let speech: [Segmenter.Span] = [
            (0.2, 2.9), (3.6, 8.9), (9.6, 14.9), (15.6, 23.9), (24.6, 32.9), (33.6, 40.9), (41.6, 49.8),
        ].map { Segmenter.Span(start: $0.0, end: $0.1) }
        let ranges = Segmenter.segments(count: 50 * 16_000, speech: speech)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Double(ranges[0].upperBound) / 16_000, 24.25, accuracy: 0.001)
        XCTAssertEqual(ranges.last?.upperBound, 50 * 16_000)
    }

    func testSpeechRegionsBridgeShortGapsAndDropBlips() {
        // Frames are 80 ms: a one-frame dip is bridged (gap 0.08 s < 0.1 s), a one-frame blip is kept
        // (0.08 s < 0.1 s is dropped), a two-frame gap splits.
        let p: [Float] = [0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0]
        let regions = Segmenter.speechRegions(p, duration: 18 * 0.08)
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].start, 0.08, accuracy: 1e-9)
        XCTAssertEqual(regions[0].end, 0.48, accuracy: 1e-9)
        XCTAssertEqual(regions[1].start, 0.64, accuracy: 1e-9)
        XCTAssertEqual(regions[1].end, 0.88, accuracy: 1e-9)
    }
}

final class TranscriptionTests: XCTestCase {
    private static let engine = ParakeetEngine()

    override class func setUp() {
        super.setUp()
        TestDevice.configure
    }

    private func loadedEngine() async throws -> ParakeetEngine {
        try XCTSkipUnless(ModelFiles.isComplete(), "model is not downloaded to \(ModelFiles.defaultDirectory.path)")
        let started = ContinuousClock.now
        try await Self.engine.load()
        print("[load] \(ContinuousClock.now - started)")
        return Self.engine
    }

    // Common Voice clips (CC0, see Fixtures/SOURCES.md): the word error rate is checked against the
    // spoken sentence, and `<name>.expected.txt` pins the exact output.
    func testEnglish() async throws { try await check("en", maximumWER: 0.1) }
    func testRussian() async throws { try await check("ru", maximumWER: 0.1) }
    /// 41.9 s, three English then three Russian clips: cut at pauses the VAD head finds.
    func testLongForm() async throws { try await check("long", maximumWER: 0.1) }

    func testHalfPrecisionMatchesFloat32() async throws {
        try XCTSkipUnless(ModelFiles.isComplete())
        let samples = try AudioFile.samples(at: fixture("en", "wav"))
        let full = try await Self.transcribe(samples, precision: .float32)
        let half = try await Self.transcribe(samples, precision: .float16)
        XCTAssertEqual(full.text, half.text)
    }

    private static func transcribe(_ samples: [Float], precision: Precision) async throws -> Transcript {
        let engine = ParakeetEngine()
        try await engine.load(precision: precision)
        return try await engine.transcribe(samples)
    }

    private func check(_ name: String, maximumWER: Double) async throws {
        let engine = try await loadedEngine()
        let samples = try AudioFile.samples(at: fixture(name, "wav"))
        let transcript = try await engine.transcribe(samples)
        let expected = try String(contentsOf: fixture(name, "txt"), encoding: .utf8)
        let wer = wordErrorRate(reference: expected, hypothesis: transcript.text)
        print("[\(name)] \(String(format: "%.0f", transcript.processingSeconds * 1000)) ms for "
            + "\(String(format: "%.1f", transcript.audioSeconds)) s: \(transcript.text)")
        XCTAssertLessThanOrEqual(wer, maximumWER, "WER \(wer): \(transcript.text)")

        if let url = Bundle.module.url(forResource: "\(name).expected", withExtension: "txt", subdirectory: "Fixtures"),
            let snapshot = try? String(contentsOf: url, encoding: .utf8)
        {
            XCTAssertEqual(transcript.text, snapshot.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

func fixture(_ name: String, _ ext: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
}

/// Word error rate after lower-casing and dropping punctuation.
func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
    let r = words(reference), h = words(hypothesis)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    var previous = Array(0 ... h.count)
    for i in 1 ... r.count {
        var current = [i] + [Int](repeating: 0, count: h.count)
        for j in stride(from: 1, through: h.count, by: 1) {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return Double(previous[h.count]) / Double(r.count)
}
