import Vision
import CoreImage
import UIKit

struct ReferenceWindow {
    /// Normalized rect in top-left-origin space (matches SwiftUI / the stored Zone rects).
    let normalizedRect: CGRect
    let featurePrint: VNFeaturePrintObservation
}

enum ReferenceIndexError: Error {
    case invalidImage
}

/// Builds an in-memory index of overlapping window embeddings over the reference
/// image, and matches piece crops against it. Rebuilt each time it's needed (not
/// persisted to disk) — computing a few hundred feature prints takes a few seconds,
/// which is an acceptable one-time cost per session rather than a solved problem
/// of persisting VNFeaturePrintObservation across launches.
final class ReferenceIndex {
    private(set) var windows: [ReferenceWindow] = []

    func build(from image: UIImage, windowFraction: CGFloat = 0.12, strideFraction: CGFloat = 0.06) throws {
        guard let cgImage = image.cgImage else { throw ReferenceIndexError.invalidImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let windowSize = min(width, height) * windowFraction
        let strideLength = min(width, height) * strideFraction
        guard windowSize > 1, strideLength > 1 else { throw ReferenceIndexError.invalidImage }

        var built: [ReferenceWindow] = []
        var y: CGFloat = 0
        while y + windowSize <= height {
            var x: CGFloat = 0
            while x + windowSize <= width {
                let pixelRect = CGRect(x: x, y: y, width: windowSize, height: windowSize)
                if let cropped = cgImage.cropping(to: pixelRect),
                   let featurePrint = try? FeaturePrintMatcher.featurePrint(for: cropped) {
                    let normalizedRect = CGRect(x: x / width, y: y / height, width: windowSize / width, height: windowSize / height)
                    built.append(ReferenceWindow(normalizedRect: normalizedRect, featurePrint: featurePrint))
                }
                x += strideLength
            }
            y += strideLength
        }
        windows = built
    }

    func topMatches(
        for pieceImage: CGImage,
        rotationsDegrees: [Double] = [0, 45, 90, 135, 180, 225, 270, 315],
        restrictedTo zoneNormalizedRect: CGRect? = nil,
        limit: Int = 5
    ) -> [MatchCandidate] {
        guard !windows.isEmpty else { return [] }

        var bestDistanceByWindow: [Int: Float] = [:]
        for rotation in rotationsDegrees {
            guard let rotated = ImageRotator.rotate(pieceImage, degrees: rotation),
                  let piecePrint = try? FeaturePrintMatcher.featurePrint(for: rotated) else { continue }

            for (index, window) in windows.enumerated() {
                if let zoneRect = zoneNormalizedRect, !zoneRect.intersects(window.normalizedRect) { continue }
                guard let distance = try? FeaturePrintMatcher.distance(piecePrint, window.featurePrint) else { continue }
                bestDistanceByWindow[index] = min(bestDistanceByWindow[index] ?? .greatestFiniteMagnitude, distance)
            }
        }

        let ranked = bestDistanceByWindow.sorted { $0.value < $1.value }.prefix(limit)
        guard let maxDistance = ranked.map(\.value).max(), maxDistance > 0 else {
            return ranked.map { entry in
                let window = windows[entry.key]
                return MatchCandidate(normalizedX: window.normalizedRect.origin.x, normalizedY: window.normalizedRect.origin.y, normalizedWidth: window.normalizedRect.width, normalizedHeight: window.normalizedRect.height, confidence: ranked.count <= 1 ? 1.0 : 0.5)
            }
        }

        // Uncalibrated heuristic: linearly maps distance-within-this-batch to a
        // 0.1-1.0 confidence band. This has not been validated against real puzzle
        // photos and must be recalibrated once test data exists — see project ADRs.
        return ranked.map { entry in
            let window = windows[entry.key]
            let confidence = max(0, min(1, 1.0 - Double(entry.value / maxDistance) * 0.9))
            return MatchCandidate(
                normalizedX: window.normalizedRect.origin.x,
                normalizedY: window.normalizedRect.origin.y,
                normalizedWidth: window.normalizedRect.width,
                normalizedHeight: window.normalizedRect.height,
                confidence: confidence
            )
        }
    }
}
