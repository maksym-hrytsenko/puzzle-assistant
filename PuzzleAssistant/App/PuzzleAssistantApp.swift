import SwiftUI
import SwiftData

@main
struct PuzzleAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            PuzzleListView()
        }
        .modelContainer(for: [Puzzle.self, Zone.self, PieceCapture.self, PieceCandidate.self, SessionEvent.self])
    }
}
