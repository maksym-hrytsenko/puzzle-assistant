import Foundation
import SwiftData

@Model
final class Puzzle {
    var id: UUID
    var name: String
    var createdAt: Date
    var referenceImagePath: String?
    var referenceImageWidth: Int
    var referenceImageHeight: Int
    var estimatedPieceCount: Int

    @Relationship(deleteRule: .cascade, inverse: \Zone.puzzle)
    var zones: [Zone] = []

    @Relationship(deleteRule: .cascade, inverse: \PieceCapture.puzzle)
    var pieceCaptures: [PieceCapture] = []

    @Relationship(deleteRule: .cascade, inverse: \SessionEvent.puzzle)
    var sessionEvents: [SessionEvent] = []

    init(name: String, estimatedPieceCount: Int = 1000) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.referenceImageWidth = 0
        self.referenceImageHeight = 0
        self.estimatedPieceCount = estimatedPieceCount
    }
}
