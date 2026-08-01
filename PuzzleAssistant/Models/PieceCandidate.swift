import Foundation
import SwiftData
import CoreGraphics

enum PieceStatus: String, Codable {
    case unplaced, placed, lowConfidence
}

struct MatchCandidate: Codable, Identifiable {
    var id = UUID()
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double
    var confidence: Double

    var normalizedRect: CGRect {
        CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
    }
}

@Model
final class PieceCandidate {
    static let lowConfidenceThreshold = 0.35

    var id: UUID
    var croppedImagePath: String
    var thumbnailPath: String
    var boundingBoxX: Double
    var boundingBoxY: Double
    var boundingBoxWidth: Double
    var boundingBoxHeight: Double
    var estimatedRotationDegrees: Double
    var statusRaw: String
    var matchesData: Data?
    var capture: PieceCapture?

    var status: PieceStatus {
        get { PieceStatus(rawValue: statusRaw) ?? .unplaced }
        set { statusRaw = newValue.rawValue }
    }

    var matches: [MatchCandidate] {
        guard let matchesData else { return [] }
        return (try? JSONDecoder().decode([MatchCandidate].self, from: matchesData)) ?? []
    }

    /// Encodes the ranked matches and demotes status to `.lowConfidence` when even the
    /// best candidate falls under the threshold — this is an uncalibrated heuristic
    /// (see ReferenceIndex) until validated against real puzzle photos.
    func applyMatches(_ matches: [MatchCandidate]) {
        matchesData = try? JSONEncoder().encode(matches)
        if let best = matches.max(by: { $0.confidence < $1.confidence }) {
            status = best.confidence < PieceCandidate.lowConfidenceThreshold ? .lowConfidence : .unplaced
        }
    }

    init(croppedImagePath: String, thumbnailPath: String, boundingBox: CGRect, estimatedRotationDegrees: Double) {
        self.id = UUID()
        self.croppedImagePath = croppedImagePath
        self.thumbnailPath = thumbnailPath
        self.boundingBoxX = boundingBox.origin.x
        self.boundingBoxY = boundingBox.origin.y
        self.boundingBoxWidth = boundingBox.width
        self.boundingBoxHeight = boundingBox.height
        self.estimatedRotationDegrees = estimatedRotationDegrees
        self.statusRaw = PieceStatus.unplaced.rawValue
    }
}
