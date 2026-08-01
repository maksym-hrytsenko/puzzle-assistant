import Foundation
import SwiftData

enum SessionEventKind: String, Codable {
    case referenceMapCreated
    case piecesCaptured
    case matchRunCompleted
    case pieceMarkedPlaced
    case zoneCreated
}

@Model
final class SessionEvent {
    var id: UUID
    var timestamp: Date
    var kindRaw: String
    var summary: String
    var puzzle: Puzzle?

    var kind: SessionEventKind {
        get { SessionEventKind(rawValue: kindRaw) ?? .matchRunCompleted }
        set { kindRaw = newValue.rawValue }
    }

    init(kind: SessionEventKind, summary: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.kindRaw = kind.rawValue
        self.summary = summary
    }
}
