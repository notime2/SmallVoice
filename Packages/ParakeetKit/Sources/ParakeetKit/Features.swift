import Foundation
import MLX

/// Parakeet's log-mel front end, with the settings of NeMo's `AudioToMelSpectrogramPreprocessor`
/// for this model family.
///
/// Pre-emphasis 0.97, a centred 512-point STFT (hop 160, symmetric 400-point Hann window,
/// zero padding), power spectrum, 128 Slaney mel filters, `log(x + 2^-24)`, then per-bin
/// normalization over the `n / 160` valid frames; the one extra centred frame is zeroed.
struct Features {
    static let sampleRate = 16_000
    static let fftSize = 512
    static let hopLength = 160
    static let windowLength = 400
    static let melBins = 128
    /// The per-bin standard deviation needs at least two valid frames.
    static let minimumSamples = 320

    private let window: MLXArray  // [512] float32
    private let filters: MLXArray  // [257, 128] float32

    init() {
        let offset = (Self.fftSize - Self.windowLength) / 2
        var window = [Float](repeating: 0, count: Self.fftSize)
        for n in 0 ..< Self.windowLength {
            window[offset + n] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.windowLength - 1)))
        }
        self.window = MLXArray(window)
        filters = MLXArray(Self.melFilterBank(), [Self.fftSize / 2 + 1, Self.melBins])
    }

    /// Normalized features `[frames, 128]` (float32) and the number of valid frames.
    func callAsFunction(_ samples: [Float]) -> (features: MLXArray, validFrames: Int) {
        let count = samples.count
        precondition(count >= Self.minimumSamples, "audio is too short for Parakeet features")

        let waveform = MLXArray(samples)
        let emphasised = concatenated([waveform[..<1], waveform[1...] - 0.97 * waveform[..<(count - 1)]])
        let centred = padded(emphasised, width: IntOrPair((Self.fftSize / 2, Self.fftSize / 2)))
        let frames = 1 + count / Self.hopLength
        let framed = asStrided(centred, [frames, Self.fftSize], strides: [Self.hopLength, 1])

        let spectrum = rfft(framed * window, n: Self.fftSize, axis: -1)
        let power = square(spectrum.realPart()) + square(spectrum.imaginaryPart())
        let logMel = log(matmul(power, filters) + Float(pow(2.0, -24.0)))

        let valid = count / Self.hopLength
        let head = logMel[..<valid]
        let mean = head.mean(axis: 0, keepDims: true)
        let deviation = std(head, axis: 0, keepDims: true, ddof: 1)
        let normalized = (head - mean) / (deviation + 1e-5)
        let features = concatenated([normalized, zeros([frames - valid, Self.melBins], dtype: .float32)], axis: 0)
        return (features, valid)
    }

    /// Slaney-scale, Slaney-normalized mel filters (librosa's defaults) as `[257, 128]`, row-major.
    static func melFilterBank() -> [Float] {
        let bins = fftSize / 2 + 1
        let nyquist = Double(sampleRate) / 2
        let lowMel = hzToMel(0), highMel = hzToMel(nyquist)
        let edges = (0 ..< melBins + 2).map { i in
            melToHz(lowMel + (highMel - lowMel) * Double(i) / Double(melBins + 1))
        }
        var filters = [Float](repeating: 0, count: bins * melBins)
        for bin in 0 ..< bins {
            let frequency = nyquist * Double(bin) / Double(bins - 1)
            for mel in 0 ..< melBins {
                let lower = (frequency - edges[mel]) / (edges[mel + 1] - edges[mel])
                let upper = (edges[mel + 2] - frequency) / (edges[mel + 2] - edges[mel + 1])
                let weight = max(0, min(lower, upper)) * 2 / (edges[mel + 2] - edges[mel])
                filters[bin * melBins + mel] = Float(weight)
            }
        }
        return filters
    }

    private static func hzToMel(_ frequency: Double) -> Double {
        frequency >= 1_000 ? 15 + log(frequency / 1_000) * (27 / log(6.4)) : 3 * frequency / 200
    }

    private static func melToHz(_ mel: Double) -> Double {
        mel >= 15 ? 1_000 * exp((mel - 15) * (log(6.4) / 27)) : 200 * mel / 3
    }
}
