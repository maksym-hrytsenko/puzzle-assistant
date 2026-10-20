import Accelerate
import CoreML
import CoreGraphics

enum SAMError: LocalizedError {
    case modelsMissing
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            return "Моделі SAM 2.1 не знайдено в застосунку. Запустіть scripts/download_sam_models.sh і зберіть застосунок знову."
        case .predictionFailed(let message):
            return "Помилка нейромережі: \(message)"
        }
    }
}

/// Segment Anything 2.1 (Apple's Core ML conversion, "small"): outlines the
/// object under a prompt point. The image encoder runs once per 1024×1024 tile;
/// the prompt encoder + mask decoder are cheap and run once per point.
final class SAMSegmenter {
    static let inputSize = 1024
    static let maskSize = 256

    struct TileEmbedding {
        fileprivate let features: [String: MLFeatureValue]
    }

    struct Mask {
        /// 256×256 logits for a 1024×1024 tile; > 0 = object.
        let logits: [Float]
        let score: Float
    }

    private let imageEncoder: MLModel
    private let promptEncoder: MLModel
    private let maskDecoder: MLModel
    private let imageConstraint: MLImageConstraint

    static let shared: Result<SAMSegmenter, Error> = Result { try SAMSegmenter() }

    private init() throws {
        func load(_ name: String) throws -> MLModel {
            var url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
            #if os(macOS)
            // Command-line test harness: compiled models in $SAM_MODELS_DIR.
            if url == nil, let dir = ProcessInfo.processInfo.environment["SAM_MODELS_DIR"] {
                url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).mlmodelc")
            }
            #endif
            guard let url else {
                throw SAMError.modelsMissing
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        imageEncoder = try load("SAM2_1SmallImageEncoderFLOAT16")
        promptEncoder = try load("SAM2_1SmallPromptEncoderFLOAT16")
        maskDecoder = try load("SAM2_1SmallMaskDecoderFLOAT16")
        guard let constraint = imageEncoder.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw SAMError.predictionFailed("encoder has no image input")
        }
        imageConstraint = constraint
    }

    /// `tile` must be 1024×1024 (smaller tiles are stretched, which distorts shapes).
    func encode(_ tile: CGImage) throws -> TileEmbedding {
        let value = try MLFeatureValue(cgImage: tile, constraint: imageConstraint, options: nil)
        let output = try imageEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": value]))
        var features: [String: MLFeatureValue] = [:]
        for name in ["image_embedding", "feats_s0", "feats_s1"] {
            guard let feature = output.featureValue(for: name) else {
                throw SAMError.predictionFailed("missing \(name)")
            }
            features[name] = feature
        }
        return TileEmbedding(features: features)
    }

    /// Masks for one positive point (tile pixel coordinates), best score first.
    func masks(for point: CGPoint, in embedding: TileEmbedding) throws -> [Mask] {
        let points = try MLMultiArray(shape: [1, 1, 2], dataType: .float16)
        points[[0, 0, 0]] = NSNumber(value: Float(point.x))
        points[[0, 0, 1]] = NSNumber(value: Float(point.y))
        let labels = try MLMultiArray(shape: [1, 1], dataType: .float16)
        labels[[0, 0]] = 1
        let prompt = try promptEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: points),
            "labels": MLFeatureValue(multiArray: labels),
        ]))
        guard let sparse = prompt.featureValue(for: "sparse_embeddings"),
              let dense = prompt.featureValue(for: "dense_embeddings") else {
            throw SAMError.predictionFailed("prompt encoder output")
        }
        var inputs = embedding.features
        inputs["sparse_embedding"] = sparse
        inputs["dense_embedding"] = dense
        let decoded = try maskDecoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = decoded.featureValue(for: "scores")?.multiArrayValue else {
            throw SAMError.predictionFailed("mask decoder output")
        }
        let count = masks.shape[1].intValue
        var result: [Mask] = []
        for m in 0..<count {
            result.append(Mask(logits: SAMSegmenter.floats(masks, plane: m), score: scores[[0, m] as [NSNumber]].floatValue))
        }
        return result.sorted { $0.score > $1.score }
    }

    /// Reads one 256×256 plane of a [1, M, 256, 256] array (Float16 or Float32).
    /// Outputs may be backed by a pixel buffer, so memory is only touched inside
    /// `withUnsafeBytes`, with the strides it reports.
    private static func floats(_ array: MLMultiArray, plane: Int) -> [Float] {
        let size = maskSize
        var out = [Float](repeating: 0, count: size * size)
        let dataType = array.dataType
        array.withUnsafeBytes { raw in
            let strides = array.strides.map(\.intValue)
            switch dataType {
            case .float16:
                let base = raw.bindMemory(to: UInt16.self)
                var row = [UInt16](repeating: 0, count: size)
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<size {
                        for x in 0..<size {
                            row[x] = base[plane * strides[1] + y * strides[2] + x * strides[3]]
                        }
                        row.withUnsafeMutableBytes { rowBytes in
                            var src = vImage_Buffer(data: rowBytes.baseAddress, height: 1,
                                                    width: vImagePixelCount(size), rowBytes: size * 2)
                            var dstRow = vImage_Buffer(data: dst.baseAddress! + y * size, height: 1,
                                                       width: vImagePixelCount(size), rowBytes: size * 4)
                            vImageConvert_Planar16FtoPlanarF(&src, &dstRow, 0)
                        }
                    }
                }
            case .float32:
                let base = raw.bindMemory(to: Float.self)
                for y in 0..<size {
                    for x in 0..<size {
                        out[y * size + x] = base[plane * strides[1] + y * strides[2] + x * strides[3]]
                    }
                }
            case .double:
                let base = raw.bindMemory(to: Double.self)
                for y in 0..<size {
                    for x in 0..<size {
                        out[y * size + x] = Float(base[plane * strides[1] + y * strides[2] + x * strides[3]])
                    }
                }
            default:
                break
            }
        }
        return out
    }
}
