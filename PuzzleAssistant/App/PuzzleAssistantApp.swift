import SwiftData
import SwiftUI

@main
struct PuzzleAssistantApp: App {
    let container: ModelContainer = {
        let schema = Schema([Puzzle.self, PuzzleZone.self, PieceCapture.self, DetectedPiece.self])
        // New store file: the schema is not compatible with the first MVP's store.
        let url = URL.applicationSupportDirectory.appending(path: "PuzzleAssistant-v2.store")
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        } catch {
            fatalError("Не вдалося відкрити базу даних: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            PuzzleListView()
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
