import CoreGraphics
import Foundation

/// One piece found on a photo.
struct DetectedOutline: Sendable {
    /// Outline in normalized photo coordinates (0...1, y down).
    var contour: [CGPoint]
    /// Area in pixels of the full-resolution photo.
    var area: Double
    /// SAM's own confidence for the mask.
    var score: Double
}

/// Lab colour statistics of the pieces on a photo (for colour transfer to the reference).
struct ColorStats: Codable, Sendable {
    var mean: [Float]
    var std: [Float]
}

struct DetectionResult: Sendable {
    var pieces: [DetectedOutline]
    var colorStats: ColorStats?
    /// Typical piece area on this photo, full-resolution pixels.
    var typicalArea: Double
}

/// Finds every loose piece on a photo:
/// 1. a grid of prompt points (~2 per piece width) on non-background pixels;
/// 2. SAM 2.1 turns each point into a mask (one image encoding per 1024 px tile);
/// 3. masks that do not look like a single classic piece are dropped (shape,
///    background share, size, already assembled area, duplicates).
final class PieceDetector {
    /// Pieces should be ~100–150 px at this resolution (48 MP photo halved, 12 MP as is).
    static let workLongSide: CGFloat = 4032
    static let tile = SAMSegmenter.inputSize
    static let stride = 700
    static let gridStep = 70
    static let tileMargin: CGFloat = 60

    private let sam: SAMSegmenter

    init(sam: SAMSegmenter) {
        self.sam = sam
    }

    private struct Candidate {
        var score: Float
        var area: Int                 // mask pixels (1 mask px = 4×4 work px)
        var pixels: [Int]             // indices in the global mask-resolution grid
        var contour: [CGPoint]        // work-image pixels
    }

    private struct Work {
        let image: CGImage
        let rgba: RGBAImage
        let scale: CGFloat            // work px per photo px
        let background: BackgroundModel // at half work resolution
        var width: Int { rgba.width }
        var height: Int { rgba.height }
        var gridWidth: Int { (width + 3) / 4 }
        var gridHeight: Int { (height + 3) / 4 }
    }

    // MARK: - Public

    func detect(in photo: CGImage, isCancelled: () -> Bool = { false },
                progress: (Double, String) -> Void) throws -> DetectionResult {
        progress(0, String(localized: "Готую фото…"))
        let work = try prepare(photo)
        let tiles = tileOrigins(width: work.width, height: work.height)

        var points: [CGPoint] = []
        for y in Swift.stride(from: PieceDetector.gridStep / 2, to: work.height, by: PieceDetector.gridStep) {
            for x in Swift.stride(from: PieceDetector.gridStep / 2, to: work.width, by: PieceDetector.gridStep)
            where !work.background.background(atX: x / 2, y: y / 2) {
                points.append(CGPoint(x: x, y: y))
            }
        }

        var candidates: [Candidate] = []
        var largestPerPoint: [Double] = []
        var covered = [Bool](repeating: false, count: work.gridWidth * work.gridHeight)
        for (index, origin) in tiles.enumerated() {
            if isCancelled() { throw CancellationError() }
            progress(Double(index) / Double(tiles.count) * 0.95, String(localized: "Шукаю шматки… фрагмент \(index + 1) з \(tiles.count)"))
            guard let tileImage = work.image.cropping(to: CGRect(origin: origin, size: CGSize(width: PieceDetector.tile, height: PieceDetector.tile))) else { continue }
            let embedding = try sam.encode(tileImage)
            let tileWidth = CGFloat(tileImage.width), tileHeight = CGFloat(tileImage.height)
            for point in points {
                let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                guard local.x > PieceDetector.tileMargin, local.y > PieceDetector.tileMargin,
                      local.x < tileWidth - PieceDetector.tileMargin, local.y < tileHeight - PieceDetector.tileMargin else { continue }
                // A confident piece already covers this point: no need to ask again.
                if covered[Int(point.y) / 4 * work.gridWidth + Int(point.x) / 4] { continue }
                let masks = try pieceMasks(at: local, tileOrigin: origin, embedding: embedding,
                                           work: work, requireShape: true)
                if let confident = masks.max(by: { $0.score < $1.score }), confident.score > 0.85 {
                    for p in confident.pixels { covered[p] = true }
                }
                candidates.append(contentsOf: masks)
                if let largest = masks.map(\.area).max() { largestPerPoint.append(Double(largest)) }
            }
        }

        progress(0.96, String(localized: "Відбираю цілі шматки…"))
        // Typical piece size: per prompt point the largest piece-like mask (a detail
        // printed on a piece is smaller than the piece). Many points land on such
        // details, so the upper quartile is used rather than the median.
        let typical = percentile(largestPerPoint, 0.75)
        let background = work.background.withAssembledRegion(pieceSide: sqrt(typical * 16) / 2)
        let kept = select(candidates, typical: typical, work: work, background: background)
        let pieces = kept.map { outline(from: $0, work: work) }
        progress(1, String(localized: "Готово"))
        return DetectionResult(pieces: pieces, colorStats: colorStats(of: kept, work: work),
                               typicalArea: typical * 16 / Double(work.scale * work.scale))
    }

    /// Outlines the single piece under a tapped point (normalized photo coordinates).
    /// `typicalArea` (photo px) — size of the other pieces on this photo, if known.
    func segmentPiece(at normalizedPoint: CGPoint, in photo: CGImage, typicalArea: Double? = nil) throws -> DetectedOutline? {
        let work = try prepare(photo)
        let point = CGPoint(x: normalizedPoint.x * CGFloat(work.width), y: normalizedPoint.y * CGFloat(work.height))
        let size = CGFloat(PieceDetector.tile)
        let origin = CGPoint(x: min(max(0, point.x - size / 2), max(0, CGFloat(work.width) - size)).rounded(),
                             y: min(max(0, point.y - size / 2), max(0, CGFloat(work.height) - size)).rounded())
        guard let tileImage = work.image.cropping(to: CGRect(origin: origin, size: CGSize(width: size, height: size))) else { return nil }
        let embedding = try sam.encode(tileImage)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let typical = typicalArea.map { $0 * Double(work.scale * work.scale) / 16 }
        let masks = try pieceMasks(at: local, tileOrigin: origin, embedding: embedding, work: work, requireShape: false)
        guard let best = masks.max(by: { PieceDetector.rank($0, typical: typical) < PieceDetector.rank($1, typical: typical) }) else {
            return nil
        }
        return outline(from: best, work: work)
    }

    // MARK: - Steps

    private func prepare(_ photo: CGImage) throws -> Work {
        let long = CGFloat(max(photo.width, photo.height)), short = CGFloat(min(photo.width, photo.height))
        var scale = min(1, PieceDetector.workLongSide / long)
        if short * scale < CGFloat(PieceDetector.tile) { scale = CGFloat(PieceDetector.tile) / short }
        let width = Int((CGFloat(photo.width) * scale).rounded()), height = Int((CGFloat(photo.height) * scale).rounded())
        guard let rgba = RGBAImage(cgImage: photo, width: width, height: height),
              let image = rgba.cgImage(),
              let half = RGBAImage(cgImage: image, width: width / 2, height: height / 2) else {
            throw SAMError.predictionFailed(String(localized: "не вдалося підготувати фото"))
        }
        return Work(image: image, rgba: rgba, scale: scale, background: BackgroundModel(image: half))
    }

    private func tileOrigins(width: Int, height: Int) -> [CGPoint] {
        let t = PieceDetector.tile
        let xs = Set(Swift.stride(from: 0, to: width, by: PieceDetector.stride).map { min($0, max(width - t, 0)) }).sorted()
        let ys = Set(Swift.stride(from: 0, to: height, by: PieceDetector.stride).map { min($0, max(height - t, 0)) }).sorted()
        return ys.flatMap { y in xs.map { CGPoint(x: $0, y: y) } }
    }

    /// SAM returns up to 3 masks per point: a detail printed on the piece, the
    /// piece itself, or a group. All plausible ones are returned; the choice is
    /// made by size (see `rank`), because the whole piece often scores lower than
    /// a striking detail on it.
    private func pieceMasks(at local: CGPoint, tileOrigin: CGPoint, embedding: SAMSegmenter.TileEmbedding,
                            work: Work, requireShape: Bool) throws -> [Candidate] {
        var valid: [(candidate: Candidate, pieceLike: Bool)] = []
        for mask in try sam.masks(for: local, in: embedding) {
            if let evaluated = evaluate(mask, at: local, tileOrigin: tileOrigin, work: work) {
                valid.append(evaluated)
            }
        }
        let plausible = valid.filter { $0.pieceLike && $0.candidate.score >= 0.5 }.map(\.candidate)
        if !plausible.isEmpty || requireShape { return plausible }
        return valid.max { $0.candidate.score < $1.candidate.score }.map { [$0.candidate] } ?? []
    }

    /// Higher is better. Within 0.5–1.5× the typical piece size the largest mask
    /// wins (a printed detail is smaller than its piece; two pieces do not fit
    /// the window); outside the window only SAM confidence counts.
    private static func rank(_ candidate: Candidate, typical: Double?) -> Double {
        let score = Double(candidate.score)
        guard let typical, typical > 0 else { return Double(candidate.area) + score }
        let ratio = Double(candidate.area) / typical
        return (0.5...1.5).contains(ratio) ? ratio + 0.3 * score : -2 + score
    }

    private func evaluate(_ mask: SAMSegmenter.Mask, at local: CGPoint, tileOrigin: CGPoint,
                          work: Work) -> (candidate: Candidate, pieceLike: Bool)? {
        let n = SAMSegmenter.maskSize
        let px = Int(local.x) / 4, py = Int(local.y) / 4
        let binary = BinaryMask(width: n, height: n, pixels: mask.logits.map { $0 > 0 })
        guard let component = binary.component(containing: px, py),
              let box = component.boundingBox else { return nil }
        // Cut by the tile border: another tile sees the piece whole.
        if box.minX <= 1 || box.minY <= 1 || box.maxX >= CGFloat(n - 1) || box.maxY >= CGFloat(n - 1) { return nil }
        let area = component.area
        guard area >= 30 else { return nil }

        var pixels: [Int] = []
        pixels.reserveCapacity(area)
        var foreground = 0
        let gx0 = Int(tileOrigin.x) / 4, gy0 = Int(tileOrigin.y) / 4
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) where component[x, y] {
                let gx = gx0 + x, gy = gy0 + y
                guard gx < work.gridWidth, gy < work.gridHeight else { continue }
                pixels.append(gy * work.gridWidth + gx)
                if !work.background.background(atX: gx * 2 + 1, y: gy * 2 + 1) { foreground += 1 }
            }
        }
        let hull = Geometry.convexHull(component.rowExtremes)
        let solidity = Double(area) / max(Double(Geometry.polygonArea(hull)), 1)
        let sides = Geometry.minAreaRectSides(hull)
        let aspect = sides.long / max(sides.short, 1)
        let foregroundShare = Double(foreground) / Double(max(pixels.count, 1))
        // Classic piece: not convex (tabs/blanks), not elongated, lying on the table.
        let pieceLike = solidity > 0.55 && solidity < 0.97 && aspect < 1.8 && foregroundShare > 0.85
        let contour = component.outerContour().map {
            CGPoint(x: tileOrigin.x + $0.x * 4, y: tileOrigin.y + $0.y * 4)
        }
        return (Candidate(score: mask.score, area: area, pixels: pixels, contour: contour), pieceLike)
    }

    private func select(_ candidates: [Candidate], typical: Double, work: Work, background: BackgroundModel) -> [Candidate] {
        var occupied = [Bool](repeating: false, count: work.gridWidth * work.gridHeight)
        var kept: [Candidate] = []
        for candidate in candidates.sorted(by: { PieceDetector.rank($0, typical: typical) > PieceDetector.rank($1, typical: typical) }) {
            let area = Double(candidate.area)
            guard area > 0.5 * typical, area < 1.5 * typical else { continue }
            var inAssembled = 0, overlap = 0
            for p in candidate.pixels {
                if background.assembled(atX: (p % work.gridWidth) * 2 + 1, y: (p / work.gridWidth) * 2 + 1) { inAssembled += 1 }
                if occupied[p] { overlap += 1 }
            }
            let count = Double(max(candidate.pixels.count, 1))
            guard Double(inAssembled) / count <= 0.5, Double(overlap) / count <= 0.25 else { continue }
            for p in candidate.pixels { occupied[p] = true }
            kept.append(candidate)
        }
        return kept
    }

    private func outline(from candidate: Candidate, work: Work) -> DetectedOutline {
        let w = CGFloat(work.width), h = CGFloat(work.height)
        let smooth = Geometry.smooth(candidate.contour, iterations: 2)
        let normalized = smooth.map { CGPoint(x: $0.x / w, y: $0.y / h) }
        let photoArea = Double(candidate.area) * 16 / Double(work.scale * work.scale)
        return DetectedOutline(contour: normalized, area: photoArea, score: Double(candidate.score))
    }

    private func colorStats(of pieces: [Candidate], work: Work) -> ColorStats? {
        var sum = [Double](repeating: 0, count: 3), sumSq = [Double](repeating: 0, count: 3)
        var count = 0.0
        for piece in pieces {
            for p in piece.pixels {
                let x = min((p % work.gridWidth) * 4 + 2, work.width - 1)
                let y = min((p / work.gridWidth) * 4 + 2, work.height - 1)
                let (r, g, b) = work.rgba.rgb(x, y)
                let lab = LabColor.fromRGB(r, g, b)
                for (c, v) in [lab.0, lab.1, lab.2].enumerated() {
                    sum[c] += Double(v); sumSq[c] += Double(v * v)
                }
                count += 1
            }
        }
        guard count > 100 else { return nil }
        let mean = sum.map { $0 / count }
        let std = (0..<3).map { sqrt(max(sumSq[$0] / count - mean[$0] * mean[$0], 1)) }
        return ColorStats(mean: mean.map(Float.init), std: std.map(Float.init))
    }

    private func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }
}
