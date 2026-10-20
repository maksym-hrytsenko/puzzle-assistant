import SwiftData
import SwiftUI

struct PuzzleListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Puzzle.createdAt, order: .reverse) private var puzzles: [Puzzle]
    @State private var showNewPuzzle = false
    @State private var path: [Puzzle] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if puzzles.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(puzzles) { puzzle in
                                NavigationLink(value: puzzle) {
                                    PuzzleCard(puzzle: puzzle)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Видалити", systemImage: "trash", role: .destructive) { delete(puzzle) }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Мої пазли")
            .navigationDestination(for: Puzzle.self) { PuzzleHomeView(puzzle: $0) }
            .toolbar {
                if !puzzles.isEmpty {
                    Button { showNewPuzzle = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showNewPuzzle) { NewPuzzleView() }
            #if DEBUG
            .task { seedDemoIfRequested() }
            #endif
        }
    }

    #if DEBUG
    /// Screenshots/demo: `-demoReference <image path> [-demoRotate] [-demoOpen]`.
    private func seedDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-demoReference"), index + 1 < args.count else { return }
        if puzzles.isEmpty, let image = UIImage(contentsOfFile: args[index + 1]),
           let prepared = ReferencePreparer.prepare(image) {
            var picture = prepared.rectified ?? prepared.original
            if args.contains("-demoRotate"), let rotated = ReferencePreparer.rotatedLeft(picture) { picture = rotated }
            let id = UUID()
            let ui = UIImage(cgImage: picture)
            guard let path = try? ImageStore.shared.save(ui, named: "reference.jpg", in: id),
                  let thumb = try? ImageStore.shared.save(ImageStore.shared.makeThumbnail(of: ui, maxDimension: 800),
                                                          named: "reference_thumb.jpg", in: id) else { return }
            let puzzle = Puzzle(id: id, name: "Чарівний ліс", referenceImagePath: path, referenceThumbnailPath: thumb,
                                referenceWidth: picture.width, referenceHeight: picture.height, pieceCount: 4000)
            modelContext.insert(puzzle)
            puzzle.zones.append(PuzzleZone(label: "Сова", rect: CGRect(x: 0.8, y: 0.0, width: 0.12, height: 0.17)))
        }
        if args.contains("-demoOpen"), let first = puzzles.first { path = [first] }
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.accentGradient)
            Text("Почнімо збирати")
                .font(.title.bold())
            Text("Завантажте готову картинку пазла й вкажіть кількість шматків. Потім фотографуйте розкидані шматки — застосунок покаже, де кожен з них лежить на картині.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button { showNewPuzzle = true } label: {
                Label("Новий пазл", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
            Spacer()
        }
        .padding()
    }

    private func delete(_ puzzle: Puzzle) {
        ImageStore.shared.deleteAll(for: puzzle.id)
        modelContext.delete(puzzle)
    }
}

private struct PuzzleCard: View {
    let puzzle: Puzzle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(.tertiarySystemFill)
                if let image = ImageStore.shared.load(relativePath: puzzle.referenceThumbnailPath) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(height: 170)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(puzzle.name).font(.headline)
                HStack(spacing: 12) {
                    Label("\(puzzle.pieceCount) шматків", systemImage: "puzzlepiece")
                    Label("\(puzzle.captures.count) фото", systemImage: "camera")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ProgressView(value: Double(puzzle.placedCount), total: Double(max(puzzle.pieceCount, 1)))
                    .tint(Theme.good)
                Text("Покладено \(puzzle.placedCount) з \(puzzle.pieceCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
