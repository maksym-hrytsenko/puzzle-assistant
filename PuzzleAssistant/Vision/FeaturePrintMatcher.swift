import Vision

enum FeaturePrintError: Error {
    case noObservation
}

struct FeaturePrintMatcher {
    static func featurePrint(for cgImage: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FeaturePrintError.noObservation
        }
        return observation
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) throws -> Float {
        var distance: Float = 0
        try a.computeDistance(&distance, to: b)
        return distance
    }
}
