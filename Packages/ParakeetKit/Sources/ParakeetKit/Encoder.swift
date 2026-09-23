import Foundation
import MLX

/// The 8x convolutional subsampler. Frames past the valid length are zeroed after every strided
/// convolution, like the masked subsampling in NeMo and HF transformers.
struct Subsampling {
    private let conv0Weight, conv0Bias: MLXArray  // [256, 3, 3, 1]
    private let depthwise1Weight, depthwise1Bias: MLXArray  // [256, 3, 3, 1], groups 256
    private let pointwise1: DenseLinear  // 256 -> 256
    private let depthwise2Weight, depthwise2Bias: MLXArray
    private let pointwise2: DenseLinear
    private let linear: DenseLinear  // channels * 16 -> hidden
    private let channels: Int

    init(_ weights: WeightStore, channels: Int) throws {
        let dtype = weights.dtype
        func conv(_ index: Int) throws -> (MLXArray, MLXArray) {
            // PyTorch [out, in, kh, kw] -> MLX [out, kh, kw, in]
            (
                try weights.take("encoder.subsampling.layers.\(index).weight", as: dtype).transposed(0, 2, 3, 1),
                try weights.take("encoder.subsampling.layers.\(index).bias", as: dtype)
            )
        }
        func pointwise(_ index: Int) throws -> DenseLinear {
            let weight = try weights.take("encoder.subsampling.layers.\(index).weight", as: dtype)
            return DenseLinear(
                weight: weight.reshaped(weight.dim(0), weight.dim(1)),
                bias: try weights.take("encoder.subsampling.layers.\(index).bias", as: dtype))
        }
        (conv0Weight, conv0Bias) = try conv(0)
        (depthwise1Weight, depthwise1Bias) = try conv(2)
        pointwise1 = try pointwise(3)
        (depthwise2Weight, depthwise2Bias) = try conv(5)
        pointwise2 = try pointwise(6)
        linear = try weights.dense("encoder.subsampling.linear")
        self.channels = channels
    }

    /// `features` is `[frames, mel]`; returns `[1, frames', hidden]` and how many leading frames are valid.
    func callAsFunction(_ features: MLXArray, validFrames: Int, dtype: DType) -> (MLXArray, Int) {
        var x = features.asType(dtype).reshaped(1, features.dim(0), features.dim(1), 1)
        var length = validFrames

        x = conv2d(x, conv0Weight, stride: 2, padding: 1) + conv0Bias
        length = Self.strided(length)
        x = relu(Self.mask(x, length))

        x = conv2d(x, depthwise1Weight, stride: 2, padding: 1, groups: channels) + depthwise1Bias
        length = Self.strided(length)
        x = relu(pointwise1(Self.mask(x, length)))

        x = conv2d(x, depthwise2Weight, stride: 2, padding: 1, groups: channels) + depthwise2Bias
        length = Self.strided(length)
        x = relu(pointwise2(Self.mask(x, length)))

        // [1, time, freq, channels] -> [1, time, channels * freq], channel-major like PyTorch's flatten.
        let (_, time, frequency, _) = x.shape4
        x = x.transposed(0, 1, 3, 2).reshaped(1, time, channels * frequency)
        return (linear(x), length)
    }

    private static func strided(_ length: Int) -> Int { (length - 1) / 2 + 1 }

    private static func mask(_ x: MLXArray, _ length: Int) -> MLXArray {
        let frames = x.dim(1)
        guard length < frames else { return x }
        let keep = (MLXArray.arange(frames) .< length).asType(x.dtype).reshaped(1, frames, 1, 1)
        return x * keep
    }
}

/// One FastConformer block: ½ FF, relative-position MHSA, convolution, ½ FF, LayerNorm.
struct ConformerLayer {
    private let normFeedForward1, normSelfAttention, normConv, normFeedForward2, normOut: LayerNormWeights
    private let feedForward1: (TernaryLinear, TernaryLinear)
    private let feedForward2: (TernaryLinear, TernaryLinear)
    private let qkv: TernaryLinear
    private let output: TernaryLinear
    private let biasU, biasV: MLXArray  // [heads, headDim]
    private let pointwise1: TernaryLinear
    private let depthwiseWeight, depthwiseBias: MLXArray  // BatchNorm folded in
    private let pointwise2: TernaryLinear
    private let heads: Int
    private let headDim: Int
    private let kernelSize: Int

    init(_ weights: WeightStore, index: Int, config: ParakeetConfig.Encoder) throws {
        let p = "encoder.layers.\(index)"
        let dtype = weights.dtype
        normFeedForward1 = try weights.layerNorm("\(p).norm_feed_forward1")
        normSelfAttention = try weights.layerNorm("\(p).norm_self_att")
        normConv = try weights.layerNorm("\(p).norm_conv")
        normFeedForward2 = try weights.layerNorm("\(p).norm_feed_forward2")
        normOut = try weights.layerNorm("\(p).norm_out")
        feedForward1 = (try weights.ternary("\(p).feed_forward1.linear1"), try weights.ternary("\(p).feed_forward1.linear2"))
        feedForward2 = (try weights.ternary("\(p).feed_forward2.linear1"), try weights.ternary("\(p).feed_forward2.linear2"))
        qkv = TernaryLinear.stacked([
            try weights.ternary("\(p).self_attn.q_proj"),
            try weights.ternary("\(p).self_attn.k_proj"),
            try weights.ternary("\(p).self_attn.v_proj"),
        ])
        output = try weights.ternary("\(p).self_attn.o_proj")
        biasU = try weights.take("\(p).self_attn.bias_u", as: dtype)
        biasV = try weights.take("\(p).self_attn.bias_v", as: dtype)
        pointwise1 = try weights.ternary("\(p).conv.pointwise_conv1")
        pointwise2 = try weights.ternary("\(p).conv.pointwise_conv2")

        // Eval-mode BatchNorm folded into the depthwise kernel: w' = w·γ/√(σ²+ε), b' = β - μ·γ/√(σ²+ε).
        let kernel = try weights.take("\(p).conv.depthwise_conv.weight", as: .float32)  // [C, 1, k]
        let mean = try weights.take("\(p).conv.norm.running_mean", as: .float32)
        let variance = try weights.take("\(p).conv.norm.running_var", as: .float32)
        let gamma = try weights.take("\(p).conv.norm.weight", as: .float32)
        let beta = try weights.take("\(p).conv.norm.bias", as: .float32)
        _ = try? weights.take("\(p).conv.norm.num_batches_tracked")
        let scale = gamma * rsqrt(variance + 1e-5)
        depthwiseWeight = (kernel * scale.reshaped(-1, 1, 1)).transposed(0, 2, 1).asType(dtype)  // [C, k, 1]
        depthwiseBias = (beta - mean * scale).asType(dtype)

        heads = config.numAttentionHeads
        headDim = config.hiddenSize / config.numAttentionHeads
        kernelSize = config.convKernelSize
    }

    /// `x` is `[1, L, C]`; `positions` is this layer's projected table `[1, heads, 2L - 1, headDim]`.
    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        var hidden = x
        hidden = hidden + 0.5 * feedForward(feedForward1, normFeedForward1(hidden))
        hidden = hidden + attention(normSelfAttention(hidden), positions: positions)
        hidden = hidden + convolution(normConv(hidden))
        hidden = hidden + 0.5 * feedForward(feedForward2, normFeedForward2(hidden))
        return normOut(hidden)
    }

    private func feedForward(_ layers: (TernaryLinear, TernaryLinear), _ x: MLXArray) -> MLXArray {
        layers.1(silu(layers.0(x)))
    }

    private func attention(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        let length = x.dim(1)
        let projected = qkv(x).reshaped(1, length, 3, heads, headDim)
        let query = projected[0..., 0..., 0]  // [1, L, H, D]
        let key = projected[0..., 0..., 1].transposed(0, 2, 1, 3)
        let value = projected[0..., 0..., 2].transposed(0, 2, 1, 3)
        let queryU = (query + biasU).transposed(0, 2, 1, 3)
        let queryV = (query + biasV).transposed(0, 2, 1, 3)

        let scale = 1 / Float(headDim).squareRoot()
        let positional = Self.relativeShift(matmul(queryV, positions.transposed(0, 1, 3, 2)), length: length)
        let attended = scaledDotProductAttention(
            queries: queryU, keys: key, values: value, scale: scale, mask: positional * scale)
        return output(attended.transposed(0, 2, 1, 3).reshaped(1, length, heads * headDim))
    }

    /// Transformer-XL relative shift: `out[h, i, j] = scores[h, i, L - 1 - i + j]`.
    static func relativeShift(_ scores: MLXArray, length: Int) -> MLXArray {
        let heads = scores.dim(1)
        let width = 2 * length - 1
        return asStrided(
            scores, [1, heads, length, length],
            strides: [heads * length * width, length * width, width - 1, 1],
            offset: length - 1)
    }

    private func convolution(_ x: MLXArray) -> MLXArray {
        let gated = pointwise1(x)
        let halves = split(gated, parts: 2, axis: -1)
        var hidden = halves[0] * sigmoid(halves[1])
        hidden = conv1d(hidden, depthwiseWeight, padding: (kernelSize - 1) / 2, groups: hidden.dim(-1)) + depthwiseBias
        return pointwise2(silu(hidden))
    }
}

/// The FastConformer encoder plus the joint's encoder projection.
struct Encoder {
    private let subsampling: Subsampling
    private let layers: [ConformerLayer]
    private let relativePositions: TernaryLinear  // every layer's relative_k_proj, stacked
    private let projector: DenseLinear  // hidden -> joint width
    private let inverseFrequency: MLXArray
    private let hiddenSize: Int
    private let heads: Int
    let dtype: DType

    init(_ weights: WeightStore, config: ParakeetConfig.Encoder) throws {
        dtype = weights.dtype
        subsampling = try Subsampling(weights, channels: config.subsamplingConvChannels)
        layers = try (0 ..< config.numHiddenLayers).map { try ConformerLayer(weights, index: $0, config: config) }
        relativePositions = TernaryLinear.stacked(
            try (0 ..< config.numHiddenLayers).map { try weights.ternary("encoder.layers.\($0).self_attn.relative_k_proj") })
        projector = try weights.dense("encoder_projector")
        hiddenSize = config.hiddenSize
        heads = config.numAttentionHeads
        let exponents = stride(from: 0, to: config.hiddenSize, by: 2).map {
            Float(1 / pow(10_000, Double($0) / Double(config.hiddenSize)))
        }
        inverseFrequency = MLXArray(exponents)
    }

    /// The subsampler's output for every frame and the number of valid ones (the VAD head reads this).
    func subsample(_ features: MLXArray, validFrames: Int) -> (MLXArray, Int) {
        subsampling(features, validFrames: validFrames, dtype: dtype)
    }

    /// Features `[frames, mel]` -> encoder output projected for the joint, `[L, joint]`.
    func callAsFunction(_ features: MLXArray, validFrames: Int) -> MLXArray? {
        let (frames, length) = subsample(features, validFrames: validFrames)
        guard length > 0 else { return nil }

        // Relative positions L-1 … -(L-1), sin/cos interleaved, projected for all layers at once.
        let offsets = MLXArray.arange(length - 1, -length, step: -1, dtype: .float32)
        let phase = outer(offsets, inverseFrequency)
        let table = stacked([sin(phase), cos(phase)], axis: -1).reshaped(2 * length - 1, hiddenSize).asType(dtype)
        let headDim = hiddenSize / heads
        let projected = relativePositions(table)
            .reshaped(2 * length - 1, layers.count, heads, headDim)
            .transposed(1, 2, 0, 3)  // [layers, H, 2L-1, D]

        // Batch of one: dropping the padded tail is the same as masking it in attention and convolution.
        var hidden = frames[0..., ..<length]
        for (index, layer) in layers.enumerated() {
            hidden = layer(hidden, positions: projected[index].expandedDimensions(axis: 0))
        }
        return projector(hidden[0])
    }
}

/// The speech head this checkpoint carries on the subsampler: per-frame speech probability
/// (80 ms frames) from three small convolutions with SiLU activations.
struct VoiceActivityHead {
    private let projection: DenseLinear  // hidden -> 128, a 1-wide convolution
    private let contextWeight, contextBias: MLXArray  // 128 -> 128, kernel 5
    private let output: DenseLinear  // 128 -> 1

    init(_ weights: WeightStore) throws {
        let dtype = weights.dtype
        let projection = try weights.take("vad_head.proj.weight", as: dtype)  // [128, hidden, 1]
        self.projection = DenseLinear(
            weight: projection.reshaped(projection.dim(0), projection.dim(1)),
            bias: try weights.take("vad_head.proj.bias", as: dtype))
        contextWeight = try weights.take("vad_head.ctx.weight", as: dtype).transposed(0, 2, 1)  // [out, k, in]
        contextBias = try weights.take("vad_head.ctx.bias", as: dtype)
        let output = try weights.take("vad_head.out.weight", as: dtype)  // [1, 128, 1]
        self.output = DenseLinear(
            weight: output.reshaped(1, output.dim(1)), bias: try weights.take("vad_head.out.bias", as: dtype))
    }

    /// `hidden` is the subsampler output `[1, T, hidden]`; returns `[T]` probabilities (float32).
    func callAsFunction(_ hidden: MLXArray) -> MLXArray {
        var x = silu(projection(hidden))
        x = silu(conv1d(x, contextWeight, padding: (contextWeight.dim(1) - 1) / 2) + contextBias)
        return sigmoid(output(x).asType(.float32)).reshaped(-1)
    }
}

func relu(_ x: MLXArray) -> MLXArray { maximum(x, 0) }
func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }
