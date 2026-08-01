import Foundation
import SwiftData

@Model
final class PieceCapture {
    var id: UUID
    var photoPath: String
    var capturedAt: Date
    var puzzle: Puzzle?

    @Relationship(deleteRule: .cascade, inverse: \PieceCandidate.capture)
    var pieceCandidates: [PieceCandidate] = []

    init(photoPath: String) {
        self.id = UUID()
        self.photoPath = photoPath
        self.capturedAt = Date()
    }
}
