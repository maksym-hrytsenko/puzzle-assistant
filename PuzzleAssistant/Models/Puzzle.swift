import Foundation
import SwiftData

@Model
final class Puzzle {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Rectified full picture, relative to ImageStore.
    var referenceImagePath: String
    var referenceThumbnailPath: String
    var referenceWidth: Int
    var referenceHeight: Int
    var pieceCount: Int
    var gridColumns: Int
    var gridRows: Int

    @Relationship(deleteRule: .cascade, inverse: \PuzzleZone.puzzle)
    var zones: [PuzzleZone] = []

    @Relationship(deleteRule: .cascade, inverse: \PieceCapture.puzzle)
    var captures: [PieceCapture] = []

    init(id: UUID = UUID(), name: String, referenceImagePath: String, referenceThumbnailPath: String,
         referenceWidth: Int, referenceHeight: Int, pieceCount: Int) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.referenceImagePath = referenceImagePath
        self.referenceThumbnailPath = referenceThumbnailPath
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
        self.pieceCount = pieceCount
        let grid = PuzzleGrid(pieceCount: pieceCount, width: referenceWidth, height: referenceHeight)
        self.gridColumns = grid.columns
        self.gridRows = grid.rows
    }

    var grid: PuzzleGrid { PuzzleGrid(columns: gridColumns, rows: gridRows) }

    var placedCount: Int {
        captures.reduce(0) { $0 + $1.pieces.filter(\.isPlaced).count }
    }
}

@Model
final class PuzzleZone {
    var id: UUID
    var label: String
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double
    var createdAt: Date
    var puzzle: Puzzle?

    var rect: CGRect {
        CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
    }

    init(label: String, rect: CGRect) {
        self.id = UUID()
        self.label = label
        self.normalizedX = rect.minX
        self.normalizedY = rect.minY
        self.normalizedWidth = rect.width
        self.normalizedHeight = rect.height
        self.createdAt = Date()
    }
}

/// One photo of loose pieces.
@Model
final class PieceCapture {
    var id: UUID
    var photoPath: String
    var capturedAt: Date
    /// Set when the photo was taken while assembling a zone.
    var zoneID: UUID?
    var colorStatsData: Data?
    /// Scale multiplier learned from confident matches on this photo.
    var scaleHint: Double?
    var detectionFinished: Bool = false
    /// Typical piece area on this photo (full-resolution px), from detection.
    var typicalPieceArea: Double?
    var thumbnailPath: String?
    var puzzle: Puzzle?

    @Relationship(deleteRule: .cascade, inverse: \DetectedPiece.capture)
    var pieces: [DetectedPiece] = []

    init(photoPath: String, zoneID: UUID?) {
        self.id = UUID()
        self.photoPath = photoPath
        self.capturedAt = Date()
        self.zoneID = zoneID
    }

    var colorStats: ColorStats? {
        get { colorStatsData.flatMap { try? JSONDecoder().decode(ColorStats.self, from: $0) } }
        set { colorStatsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

@Model
final class DetectedPiece {
    var id: UUID
    var contourData: Data
    var area: Double
    var samScore: Double
    var isPlaced: Bool
    var placementsData: Data?
    var capture: PieceCapture?

    init(outline: DetectedOutline) {
        self.id = UUID()
        self.contourData = DetectedPiece.encode(outline.contour)
        self.area = outline.area
        self.samScore = outline.score
        self.isPlaced = false
    }

    /// Outline in normalized photo coordinates.
    var contour: [CGPoint] {
        contourData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float32.self)
            return Swift.stride(from: 0, to: floats.count - 1, by: 2).map {
                CGPoint(x: CGFloat(floats[$0]), y: CGFloat(floats[$0 + 1]))
            }
        }
    }

    /// Cached result of the location search (nil = not searched yet).
    var placements: [PlacementCandidate]? {
        get { placementsData.flatMap { try? JSONDecoder().decode([PlacementCandidate].self, from: $0) } }
        set { placementsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var bestPlacement: PlacementCandidate? { placements?.first }

    /// How this piece relates to a zone being assembled.
    func fit(in zone: PuzzleZone, grid: PuzzleGrid) -> ZoneFit {
        guard let placements else { return .unknown }
        // Half a cell of tolerance around the zone.
        let area = zone.rect.insetBy(dx: -0.5 / CGFloat(grid.columns), dy: -0.5 / CGFloat(grid.rows))
        func inside(_ c: PlacementCandidate) -> Bool { area.contains(CGPoint(x: c.x, y: c.y)) }
        if let best = placements.first, inside(best), best.probability >= 0.3 { return .fits(best) }
        if let possible = placements.first(where: { inside($0) && $0.probability >= 0.1 }) { return .maybe(possible) }
        return .no
    }

    private static func encode(_ points: [CGPoint]) -> Data {
        var floats: [Float32] = []
        floats.reserveCapacity(points.count * 2)
        for p in points {
            floats.append(Float32(p.x))
            floats.append(Float32(p.y))
        }
        return floats.withUnsafeBytes { Data($0) }
    }
}

enum ZoneFit {
    case unknown
    case fits(PlacementCandidate)
    case maybe(PlacementCandidate)
    case no
}
