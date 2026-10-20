import CoreGraphics
import Foundation
import UIKit

/// What the engine needs to know about a puzzle (plain values, safe off the main thread).
struct ReferenceInfo: Sendable {
    let puzzleID: UUID
    let imagePath: String
    let columns: Int
    let rows: Int
}

/// Thread-safe flag for stopping long work.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Runs all heavy vision work on one background queue and caches the expensive
/// parts (SAM models, prepared reference textures, the last decoded photos).
final class PuzzleEngine: @unchecked Sendable {
    static let shared = PuzzleEngine()

    private let queue = DispatchQueue(label: "PuzzleEngine", qos: .userInitiated)
    // Accessed only on `queue`.
    private var matcher: (key: String, value: ReferenceMatcher)?
    private var photoCache: [(path: String, image: CGImage)] = []

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func detector() throws -> PieceDetector {
        PieceDetector(sam: try SAMSegmenter.shared.get())
    }

    private func photo(_ path: String) throws -> CGImage {
        if let cached = photoCache.first(where: { $0.path == path }) { return cached.image }
        guard let image = ImageStore.shared.load(relativePath: path)?.uprightCGImage() else {
            throw MatchError.referenceUnavailable
        }
        photoCache.append((path, image))
        if photoCache.count > 2 { photoCache.removeFirst() }
        return image
    }

    private func referenceMatcher(_ info: ReferenceInfo) throws -> ReferenceMatcher {
        let key = "\(info.puzzleID)-\(info.columns)x\(info.rows)"
        if let matcher, matcher.key == key { return matcher.value }
        matcher = nil // free the previous puzzle's textures first
        guard let image = ImageStore.shared.load(relativePath: info.imagePath)?.uprightCGImage() else {
            throw MatchError.referenceUnavailable
        }
        let value = try ReferenceMatcher(reference: image, columns: info.columns, rows: info.rows)
        matcher = (key, value)
        return value
    }

    // MARK: - API

    func detectPieces(photoPath: String, cancel: CancellationFlag,
                      progress: @escaping @Sendable (Double, String) -> Void) async throws -> DetectionResult {
        try await perform { [self] in
            let image = try photo(photoPath)
            return try detector().detect(in: image, isCancelled: { cancel.isCancelled }, progress: progress)
        }
    }

    func segmentPiece(at point: CGPoint, photoPath: String, typicalArea: Double?) async throws -> DetectedOutline? {
        try await perform { [self] in
            try detector().segmentPiece(at: point, in: try photo(photoPath), typicalArea: typicalArea)
        }
    }

    /// Prepares the reference textures ahead of time (first search is then fast).
    func warmUp(_ info: ReferenceInfo) async {
        _ = try? await perform { [self] in try referenceMatcher(info) }
    }

    func locate(_ info: ReferenceInfo, photoPath: String, contour: [CGPoint], area: Double,
                colorStats: ColorStats?, scaleHint: Double?) async throws -> [PlacementCandidate] {
        try await perform { [self] in
            try referenceMatcher(info).locate(contour: contour, area: area, in: try photo(photoPath),
                                              photoStats: colorStats, scaleHint: scaleHint)
        }
    }

    /// Cut-out of a piece for display (upright as photographed).
    func pieceImage(photoPath: String, contour: [CGPoint]) async -> UIImage? {
        try? await perform { [self] in
            let image = try photo(photoPath)
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let points = contour.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -6, dy: -6).integral
                .intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard let cropped = image.cropping(to: box) else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return UIGraphicsImageRenderer(size: box.size, format: format).image { context in
                let path = UIBezierPath()
                for (i, p) in points.enumerated() {
                    let q = CGPoint(x: p.x - box.minX, y: p.y - box.minY)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                path.close()
                path.addClip()
                UIImage(cgImage: cropped).draw(at: .zero)
                _ = context
            }
        }
    }
}
