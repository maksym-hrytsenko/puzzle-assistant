import SwiftUI
import SwiftData

struct PuzzleListView: View {
    @Query(sort: \Puzzle.createdAt, order: .reverse) private var puzzles: [Puzzle]
    @Environment(\.modelContext) private var modelContext
    @State private var isPresentingCreate = false

    var body: some View {
        NavigationStack {
            Group {
                if puzzles.isEmpty {
                    ContentUnavailableView(
                        "No puzzles yet",
                        systemImage: "puzzlepiece",
                        description: Text("Create a puzzle project and photograph its reference image to get started.")
                    )
                } else {
                    List {
                        ForEach(puzzles, id: \.id) { puzzle in
                            NavigationLink(value: puzzle) {
                                PuzzleRow(puzzle: puzzle)
                            }
                        }
                        .onDelete(perform: deletePuzzles)
                    }
                }
            }
            .navigationTitle("My Puzzles")
            .navigationDestination(for: Puzzle.self) { puzzle in
                PuzzleDetailView(puzzle: puzzle)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingCreate = true
                    } label: {
                        Label("New Puzzle", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingCreate) {
                CreatePuzzleView()
            }
        }
    }

    private func deletePuzzles(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(puzzles[index])
        }
    }
}

private struct PuzzleRow: View {
    let puzzle: Puzzle

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(puzzle.name).font(.headline)
                Text("\(puzzle.estimatedPieceCount) pieces \u{00b7} \(puzzle.zones.count) zones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = puzzle.referenceImagePath, let image = ImageStore.shared.load(relativePath: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.2))
                .overlay(Image(systemName: "photo"))
        }
    }
}
