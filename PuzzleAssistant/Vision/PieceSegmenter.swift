import Vision
import UIKit

struct DetectedPiece {
    /// Normalized bounding box in the source photo, Vision's bottom-left-origin space.
    let normalizedBoundingBox: CGRect
    let croppedImage: CGImage
    let estimatedRotationDegrees: Double
}

enum PieceSegmenterError: Error {
    case invalidImage
    case noPiecesDetected
}

/// Segments individual pieces out of a photo of loose pieces. Works best against a
/// plain, contrasting background (recommended to the user in the capture UI) with
/// pieces laid out without touching or overlapping — accuracy degrades sharply
/// otherwise, since this uses classical contour detection, not a learned model.
struct PieceSegmenter {
    static func segmentPieces(in image: UIImage, minimumAreaFraction: CGFloat = 0.0006) throws -> [DetectedPiece] {
        guard let cgImage = image.cgImage else { throw PieceSegmenterError.invalidImage }

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.6
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNContoursObservation else {
            throw PieceSegmenterError.noPiecesDetected
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        var pieces: [DetectedPiece] = []

        for contour in observation.topLevelContours {
            let box = contour.normalizedPath.boundingBoxOfPath
            let areaFraction = box.width * box.height
            guard areaFraction > minimumAreaFraction, areaFraction < 0.5 else { continue }

            let pixelRect = CGRect(
                x: box.origin.x * imageWidth,
                y: (1 - box.origin.y - box.height) * imageHeight,
                width: box.width * imageWidth,
                height: box.height * imageHeight
            ).insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

            guard !pixelRect.isEmpty, let cropped = cgImage.cropping(to: pixelRect) else { continue }

            let rotation = RotationEstimator.estimateRotationDegrees(of: contour.normalizedPath)
            pieces.append(DetectedPiece(normalizedBoundingBox: box, croppedImage: cropped, estimatedRotationDegrees: rotation))
        }

        guard !pieces.isEmpty else { throw PieceSegmenterError.noPiecesDetected }
        return pieces
    }
}
