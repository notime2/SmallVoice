import Foundation
import MLX

/// The LSTM prediction network and the joint head of the token-duration transducer.
struct TDTDecoder {
    private let embedding: MLXArray  // [vocab, hidden]
    private let cellWeights: [MLXArray]  // per layer: [4·hidden, 2·hidden] = [W_ih | W_hh]
    private let cellBiases: [MLXArray]  // per layer: b_ih + b_hh
    private let projector: DenseLinear  // decoder -> joint width
    private let head: DenseLinear  // joint width -> vocab + durations
    private let hiddenSize: Int
    private let vocabSize: Int
    private let blank: Int
    private let durations: [Int]
    private let maxSymbolsPerStep: Int

    /// Joint rows evaluated per GPU round trip while the decoder state stays fixed.
    private static let window = 16

    init(_ weights: WeightStore, config: ParakeetConfig) throws {
        let dtype = weights.dtype
        embedding = try weights.take("decoder.embedding.weight", as: dtype)
        var cellWeights: [MLXArray] = []
        var cellBiases: [MLXArray] = []
        for layer in 0 ..< config.numDecoderLayers {
            let inputWeight = try weights.take("decoder.lstm.weight_ih_l\(layer)", as: dtype)
            let hiddenWeight = try weights.take("decoder.lstm.weight_hh_l\(layer)", as: dtype)
            cellWeights.append(concatenated([inputWeight, hiddenWeight], axis: 1))
            let inputBias = try weights.take("decoder.lstm.bias_ih_l\(layer)", as: .float32)
            let hiddenBias = try weights.take("decoder.lstm.bias_hh_l\(layer)", as: .float32)
            cellBiases.append((inputBias + hiddenBias).asType(dtype))
        }
        self.cellWeights = cellWeights
        self.cellBiases = cellBiases
        projector = try weights.dense("decoder.decoder_projector")
        head = try weights.dense("joint.head")
        hiddenSize = config.decoderHiddenSize
        vocabSize = config.vocabSize
        blank = config.blankTokenId
        durations = config.durations
        maxSymbolsPerStep = config.maxSymbolsPerStep
    }

    private struct State {
        var hidden: [MLXArray]
        var cell: [MLXArray]
    }

    /// One prediction-network step: embeds `token`, runs the LSTM cells, projects for the joint.
    private func predict(_ token: Int, _ state: State?) -> (MLXArray, State) {
        var value = embedding[token].reshaped(1, hiddenSize)
        let zero = MLXArray.zeros([1, hiddenSize], dtype: value.dtype)
        var next = State(hidden: [], cell: [])
        for layer in cellWeights.indices {
            let previousHidden = state?.hidden[layer] ?? zero
            let previousCell = state?.cell[layer] ?? zero
            let gates = addMM(cellBiases[layer], concatenated([value, previousHidden], axis: 1), cellWeights[layer].T)
            let parts = split(gates, parts: 4, axis: -1)  // i, f, g, o
            let cell = sigmoid(parts[1]) * previousCell + sigmoid(parts[0]) * tanh(parts[2])
            value = sigmoid(parts[3]) * tanh(cell)
            next.hidden.append(value)
            next.cell.append(cell)
        }
        return (projector(value), next)
    }

    /// Greedy TDT decoding (as in NeMo's greedy TDT inference): blank with duration 0
    /// advances one frame, at most `maxSymbolsPerStep · frames` steps, and the LSTM only moves
    /// on emitted tokens. Rows of the joint are computed a window at a time while the decoder
    /// state is unchanged, which gives the same result with one GPU round trip per token.
    func decode(_ encoded: MLXArray) -> [Int] {
        let frames = encoded.dim(0)
        var (decoderOutput, state) = predict(blank, nil)
        var tokens: [Int] = []
        var frame = 0
        var stepsRemaining = maxSymbolsPerStep * frames

        while frame < frames, stepsRemaining > 0 {
            let start = frame
            let end = min(frames, start + Self.window)
            let logits = head(relu(encoded[start ..< end] + decoderOutput))
            let tokenIDs = argMax(logits[0..., ..<vocabSize], axis: -1)
            let durationIDs = argMax(logits[0..., vocabSize...], axis: -1)
            eval(tokenIDs, durationIDs)
            let rowTokens = tokenIDs.asArray(UInt32.self)
            let rowDurations = durationIDs.asArray(UInt32.self)

            while frame < end, stepsRemaining > 0 {
                let token = Int(rowTokens[frame - start])
                var duration = durations[Int(rowDurations[frame - start])]
                if token == blank, duration == 0 { duration = 1 }
                stepsRemaining -= 1
                frame += duration
                if token != blank {
                    tokens.append(token)
                    (decoderOutput, state) = predict(token, state)
                    break
                }
            }
        }
        return tokens
    }
}
