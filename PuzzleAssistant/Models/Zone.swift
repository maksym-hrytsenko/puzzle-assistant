import Foundation
import SwiftData
import CoreGraphics

enum ZoneStatus: String, Codable {
    case notStarted, inProgress, done
}

@Model
final class Zone {
    var id: UUID
    var label: String
    var normalizedX: Double
    var normalizedY: Double
    var normalizedWidth: Double
    var normalizedHeight: Double
    var statusRaw: String
    var createdAt: Date
    var puzzle: Puzzle?

    var status: ZoneStatus {
        get { ZoneStatus(rawValue: statusRaw) ?? .notStarted }
        set { statusRaw = newValue.rawValue }
    }

    var normalizedRect: CGRect {
        CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
    }

    init(label: String, normalizedRect: CGRect) {
        self.id = UUID()
        self.label = label
        self.normalizedX = normalizedRect.origin.x
        self.normalizedY = normalizedRect.origin.y
        self.normalizedWidth = normalizedRect.width
        self.normalizedHeight = normalizedRect.height
        self.statusRaw = ZoneStatus.notStarted.rawValue
        self.createdAt = Date()
    }
}
