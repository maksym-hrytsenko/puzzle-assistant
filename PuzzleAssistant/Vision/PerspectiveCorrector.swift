import Vision
import CoreImage
import UIKit

enum PerspectiveCorrectionResult {
    /// A rectangle was detected and perspective correction applied.
    case corrected(CIImage)
    /// No confident rectangle was found; the original image is returned uncropped
    /// so the user isn't blocked, but the caller should flag this to the user.
    case fallbackUncorrected(CIImage)
}

struct PerspectiveCorrector {
    static func correct(_ inputImage: UIImage) -> PerspectiveCorrectionResult {
        guard let cgImage = inputImage.cgImage else {
            return .fallbackUncorrected(CIImage(image: inputImage) ?? CIImage())
        }
        let ciImage = CIImage(cgImage: cgImage)

        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.2
        request.maximumObservations = 1
        request.quadratureTolerance = 20

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .fallbackUncorrected(ciImage)
        }

        guard let observation = request.results?.first else {
            return .fallbackUncorrected(ciImage)
        }

        // Vision's normalized points share Core Image's bottom-left origin, so a
        // direct scale by image size (no y-flip) is correct here.
        let imageSize = ciImage.extent.size
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return .fallbackUncorrected(ciImage)
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: point(observation.topLeft)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: point(observation.topRight)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: point(observation.bottomRight)), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: point(observation.bottomLeft)), forKey: "inputBottomLeft")

        guard let output = filter.outputImage else {
            return .fallbackUncorrected(ciImage)
        }
        return .corrected(output)
    }
}
