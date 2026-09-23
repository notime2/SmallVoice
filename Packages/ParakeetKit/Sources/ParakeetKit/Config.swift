import Foundation

/// The subset of `config.json` the inference path needs.
struct ParakeetConfig: Decodable {
    struct Encoder: Decodable {
        let hiddenSize: Int
        let intermediateSize: Int
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let numMelBins: Int
        let convKernelSize: Int
        let subsamplingConvChannels: Int
        let subsamplingFactor: Int
    }

    let encoderConfig: Encoder
    let blankTokenId: Int
    let decoderHiddenSize: Int
    let durations: [Int]
    let maxSymbolsPerStep: Int
    let numDecoderLayers: Int
    let vocabSize: Int
    let ternaryGroupSize: Int

    static func load(from url: URL) throws -> ParakeetConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(ParakeetConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    private func validate() throws {
        let e = encoderConfig
        guard e.hiddenSize % e.numAttentionHeads == 0,
            e.subsamplingFactor == 8,
            e.numMelBins == Features.melBins,
            durations.first == 0,
            blankTokenId == vocabSize - 1,
            ternaryGroupSize == TernaryLinear.groupSize
        else { throw ParakeetError.unsupportedModel("unexpected Parakeet geometry in config.json") }
    }
}

public enum ParakeetError: LocalizedError {
    case missingFile(String)
    case missingTensor(String)
    case unsupportedModel(String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .missingFile(let name): "Model file is missing: \(name)"
        case .missingTensor(let name): "Model weights are missing tensor \(name)"
        case .unsupportedModel(let reason): "Unsupported model: \(reason)"
        case .notLoaded: "The speech model is not loaded yet"
        }
    }
}
