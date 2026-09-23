import Foundation
import MLX

/// A linear layer whose weight is exactly `scale[row, col / 128] * (code - 1)`, `code ∈ {0, 1, 2}`.
///
/// That is MLX's 2-bit affine quantization with `q = code`, `scales = s` and `biases = -s`,
/// so the checkpoint's ternary rows run through `quantizedMM` without any loss.
struct TernaryLinear {
    static let groupSize = 128
    static let bits = 2

    let weight: MLXArray  // uint32 [out, in / 16]
    let scales: MLXArray  // [out, in / 128]
    let biases: MLXArray  // [out, in / 128]

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        quantizedMM(
            x, weight, scales: scales, biases: biases, transpose: true,
            groupSize: Self.groupSize, bits: Self.bits)
    }

    /// Stacks several layers along the output dimension, so one matmul serves all of them.
    static func stacked(_ layers: [TernaryLinear]) -> TernaryLinear {
        TernaryLinear(
            weight: concatenated(layers.map(\.weight), axis: 0),
            scales: concatenated(layers.map(\.scales), axis: 0),
            biases: concatenated(layers.map(\.biases), axis: 0))
    }

    /// Converts the checkpoint's packed base-3 rows (five codes per byte, least significant digit
    /// first, `ceil(in / 5)` bytes per row) into MLX's 2-bit layout: sixteen codes per `UInt32`,
    /// element `i` at bits `2i`. Runs as a handful of vectorized GPU ops.
    static func packMLX(_ packed: MLXArray, inFeatures: Int) -> MLXArray {
        precondition(inFeatures % 16 == 0, "ternary in-features must be a multiple of 16")
        let rows = packed.dim(0)
        precondition(packed.dim(1) == (inFeatures + 4) / 5, "ternary codes do not match the layer shape")
        let powers = MLXArray([1, 3, 9, 27, 81] as [UInt32])
        let digits = remainder(floorDivide(packed.asType(.uint32).expandedDimensions(axis: -1), powers), 3)
        let codes = digits.reshaped(rows, -1)[0..., ..<inFeatures].reshaped(rows, inFeatures / 16, 16)
        let shifts = MLXArray((0 ..< 16).map { UInt32(2 * $0) })
        return leftShift(codes, shifts).sum(axis: -1).asType(.uint32)
    }
}

/// A dense linear layer `x @ W^T + b`.
struct DenseLinear {
    let weight: MLXArray  // [out, in]
    let bias: MLXArray?

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        guard x.ndim > 2 else { return linear2D(x) }
        let shape = x.shape
        let flat = linear2D(x.reshaped(-1, shape[shape.count - 1]))
        return flat.reshaped(Array(shape.dropLast()) + [weight.dim(0)])
    }

    private func linear2D(_ x: MLXArray) -> MLXArray {
        if let bias { return addMM(bias, x, weight.T) }
        return matmul(x, weight.T)
    }
}

struct LayerNormWeights {
    let weight: MLXArray
    let bias: MLXArray

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        layerNorm(x, weight: weight, bias: bias, eps: 1e-5)
    }
}

/// Tensors from `model.safetensors`, converted to the engine's layouts on the way out.
final class WeightStore {
    private var tensors: [String: MLXArray]
    let dtype: DType

    init(url: URL, dtype: DType) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ParakeetError.missingFile(url.lastPathComponent)
        }
        tensors = try loadArrays(url: url)
        self.dtype = dtype
    }

    /// Returns a tensor and forgets it, so the raw checkpoint copy can be released as we go.
    func take(_ name: String) throws -> MLXArray {
        guard let tensor = tensors.removeValue(forKey: name) else { throw ParakeetError.missingTensor(name) }
        return tensor
    }

    func take(_ name: String, as dtype: DType) throws -> MLXArray {
        try take(name).asType(dtype)
    }

    func dense(_ prefix: String, bias: Bool = true) throws -> DenseLinear {
        DenseLinear(
            weight: try take("\(prefix).weight", as: dtype),
            bias: bias ? try take("\(prefix).bias", as: dtype) : nil)
    }

    func layerNorm(_ prefix: String) throws -> LayerNormWeights {
        LayerNormWeights(weight: try take("\(prefix).weight", as: dtype), bias: try take("\(prefix).bias", as: dtype))
    }

    func ternary(_ prefix: String) throws -> TernaryLinear {
        let scales = try take("\(prefix).scales", as: dtype)
        let weight = TernaryLinear.packMLX(try take("\(prefix).qweight"), inFeatures: scales.dim(1) * TernaryLinear.groupSize)
        let layer = TernaryLinear(weight: weight, scales: scales, biases: -scales)
        // Materialize now so the unpacking intermediates of one layer never pile up.
        eval(layer.weight, layer.scales, layer.biases)
        return layer
    }

    var remainingNames: [String] { tensors.keys.sorted() }
}
