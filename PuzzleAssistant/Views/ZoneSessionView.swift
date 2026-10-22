import SwiftData
import SwiftUI

/// Assembling one area: take photos of loose pieces, see which of them belong here.
struct ZoneSessionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var zone: PuzzleZone
    let puzzle: Puzzle

    @State private var reference: UIImage?
    @State private var showNewCapture = false
    @State private var openedCapture: PieceCapture?
    @State private var selectedPiece: DetectedPiece?
    @State private var errorMessage: String?
    @State private var showAssembly = false

    private var captures: [PieceCapture] {
        puzzle.captures.filter { $0.zoneID == zone.id }.sorted { $0.capturedAt > $1.capturedAt }
    }

    private var fitting: [(DetectedPiece, PlacementCandidate)] {
        captures.flatMap(\.pieces).compactMap { piece in
            guard !piece.isPlaced else { return nil }
            switch piece.fit(in: zone, grid: puzzle.grid) {
            case .fits(let c), .maybe(let c): return (piece, c)
            default: return nil
            }
        }
        .sorted { $0.1.probability > $1.1.probability }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    ZoneThumbnail(reference: reference, rect: zone.rect)
                        .aspectRatio(zoneAspect, contentMode: .fit)
                        .frame(maxHeight: 280)
                        .overlay {
                            GridOverlay(grid: PuzzleGrid(columns: max(1, Int((zone.rect.width * CGFloat(puzzle.gridColumns)).rounded())),
                                                         rows: max(1, Int((zone.rect.height * CGFloat(puzzle.gridRows)).rounded()))))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("Рядки \(rowRange) · стовпці \(columnRange)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .card()

                Button { showNewCapture = true } label: {
                    Label(captures.isEmpty ? LocalizedStringKey("Сфотографувати шматки для ділянки") : LocalizedStringKey("Ще одне фото шматків"), systemImage: "camera.fill")
                }
                .buttonStyle(fitting.isEmpty ? PrimaryButtonStyle() : PrimaryButtonStyle(enabled: true))

                if !fitting.isEmpty {
                    Button { showAssembly = true } label: {
                        Label("Збирати крок за кроком (\(fitting.count))", systemImage: "list.number")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Підходять до ділянки").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                            ForEach(fitting, id: \.0.id) { piece, candidate in
                                Button { selectedPiece = piece } label: {
                                    FittingPieceCell(piece: piece, candidate: candidate)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !captures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Фото для цієї ділянки").font(.title3.bold())
                        ForEach(captures) { capture in
                            Button { openedCapture = capture } label: { CaptureRow(capture: capture) }
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("Сфотографуйте купку шматків — я перевірю кожен і підсвічу ті, що належать до цієї ділянки. Можна зробити кілька фото.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(zone.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { reference = ImageStore.shared.load(relativePath: puzzle.referenceImagePath) }
        .sheet(isPresented: $showNewCapture) {
            NewCaptureSheet(title: "Шматки для «\(zone.label)»") { image in
                do {
                    openedCapture = try CaptureFactory.makeCapture(from: image, puzzle: puzzle, zone: zone, context: modelContext)
                } catch {
                    errorMessage = String(localized: "Не вдалося зберегти фото.")
                }
            }
        }
        .sheet(item: $selectedPiece) { PieceLocationView(piece: $0, puzzle: puzzle, zone: zone) }
        .navigationDestination(item: $openedCapture) { DetectionView(capture: $0, puzzle: puzzle) }
        .navigationDestination(isPresented: $showAssembly) { ZoneAssemblyView(zone: zone, puzzle: puzzle) }
        .alert("Помилка", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var zoneAspect: CGFloat {
        (zone.rect.width * CGFloat(puzzle.referenceWidth)) / max(zone.rect.height * CGFloat(puzzle.referenceHeight), 1)
    }

    private var rowRange: String {
        let g = puzzle.grid
        let a = g.cell(at: CGPoint(x: zone.rect.minX, y: zone.rect.minY + 0.0001))
        let b = g.cell(at: CGPoint(x: zone.rect.maxX - 0.0001, y: zone.rect.maxY - 0.0001))
        return "\(a.row)–\(b.row)"
    }

    private var columnRange: String {
        let g = puzzle.grid
        let a = g.cell(at: CGPoint(x: zone.rect.minX + 0.0001, y: zone.rect.minY))
        let b = g.cell(at: CGPoint(x: zone.rect.maxX - 0.0001, y: zone.rect.maxY - 0.0001))
        return "\(a.column)–\(b.column)"
    }
}

private struct FittingPieceCell: View {
    let piece: DetectedPiece
    let candidate: PlacementCandidate
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(.tertiarySystemFill)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(6)
                        .rotationEffect(.degrees(candidate.rotationDegrees))
                }
            }
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Pill(text: "\(Int((candidate.probability * 100).rounded())) %", color: Theme.color(probability: candidate.probability))
            Text("р. \(candidate.row) · ст. \(candidate.column)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .card()
        .task {
            if let path = piece.capture?.photoPath {
                image = await PuzzleEngine.shared.pieceImage(photoPath: path, contour: piece.contour)
            }
        }
    }
}
