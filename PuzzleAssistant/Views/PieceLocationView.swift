import SwiftData
import SwiftUI

/// Where a piece belongs on the full picture, with the probability of each place.
struct PieceLocationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var piece: DetectedPiece
    let puzzle: Puzzle
    var zone: PuzzleZone?

    @State private var reference: UIImage?
    @State private var pieceImage: UIImage?
    @State private var isSearching = false
    @State private var errorMessage: String?

    private var placements: [PlacementCandidate] { piece.placements ?? [] }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact {
                    // Landscape: the picture fills the left side.
                    HStack(spacing: 0) {
                        referenceView.padding(8)
                        ScrollView { details.padding() }.frame(width: 360)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            header
                            referenceView.frame(height: 300)
                            details
                        }
                        .padding()
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Де цей шматок?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
                    if verticalSizeClass == .compact { header }
                    if isSearching {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Шукаю місце на картині…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .card()
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding().card()
                    } else if !placements.isEmpty {
                        confidenceNote
                        ForEach(Array(placements.enumerated()), id: \.element.id) { index, candidate in
                            CandidateRow(index: index, candidate: candidate, reference: reference, puzzle: puzzle)
                        }
                    }
                    actions
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Color(.tertiarySystemFill)
                if let pieceImage {
                    Image(uiImage: pieceImage).resizable().scaledToFit().padding(6)
                        .rotationEffect(.degrees(placements.first?.rotationDegrees ?? 0))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                if let best = placements.first {
                    Text("Рядок \(best.row) · стовпець \(best.column)").font(.title3.bold())
                    HStack {
                        Pill(text: "\(Int((best.probability * 100).rounded())) %", color: Theme.color(probability: best.probability))
                        (placements.count > 1 ? Text("ще \(placements.count - 1) варіант(и)") : Text("єдиний варіант"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Шматок на мініатюрі повернутий так, як він лежить на картині.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Шматок").font(.title3.bold())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card()
    }

    private var referenceView: some View {
        ZStack {
            Color.black
            if let reference {
                ZoomableImage(image: reference) { size, zoom in
                    Canvas { context, _ in
                        if let zone {
                            let r = zone.rect
                            let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                              width: r.width * size.width, height: r.height * size.height)
                            context.stroke(Path(rect), with: .color(.white),
                                           style: StrokeStyle(lineWidth: 2 / zoom, dash: [6 / zoom, 4 / zoom]))
                        }
                        for (index, candidate) in placements.enumerated().reversed() {
                            let color = Theme.candidateColors[index % Theme.candidateColors.count]
                            let path = outlinePath(candidate.outline, in: size)
                            context.fill(path, with: .color(color.opacity(0.35)))
                            context.stroke(path, with: .color(color), lineWidth: 2 / zoom)
                            // A ring so the place is visible on the whole picture.
                            let center = CGPoint(x: candidate.x * size.width, y: candidate.y * size.height)
                            let radius = max(18 / zoom, size.width / CGFloat(puzzle.gridColumns) * 1.6)
                            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                                  width: radius * 2, height: radius * 2)),
                                           with: .color(color), lineWidth: 3 / zoom)
                            let label = Text("\(index + 1)").font(.system(size: 13 / zoom, weight: .heavy)).foregroundColor(.white)
                            let badge = CGRect(x: center.x + radius * 0.75, y: center.y - radius * 1.15, width: 20 / zoom, height: 20 / zoom)
                            context.fill(Path(ellipseIn: badge), with: .color(color))
                            context.draw(label, at: CGPoint(x: badge.midX, y: badge.midY))
                        }
                    }
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var confidenceNote: some View {
        if let best = placements.first, best.probability < 0.3 {
            Label("Метод не впевнений: жодне місце не виділяється. Так буває зі шматками без помітних деталей (небо, вода, листя).",
                  systemImage: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
                .card()
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                piece.isPlaced.toggle()
                Haptics.success()
                if piece.isPlaced { dismiss() }
            } label: {
                Label(piece.isPlaced ? LocalizedStringKey("Повернути в розкидані") : LocalizedStringKey("Поклав(-ла) на місце"),
                      systemImage: piece.isPlaced ? "arrow.uturn.backward" : "checkmark.seal.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            HStack(spacing: 10) {
                Button {
                    Task { await search(force: true) }
                } label: {
                    Label("Шукати знову", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isSearching)
                Button(role: .destructive) {
                    modelContext.delete(piece)
                    dismiss()
                } label: {
                    Label("Це не шматок", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private func load() async {
        let referencePath = puzzle.referenceImagePath
        async let referenceImage = Task.detached { ImageStore.shared.load(relativePath: referencePath) }.value
        if let path = piece.capture?.photoPath {
            pieceImage = await PuzzleEngine.shared.pieceImage(photoPath: path, contour: piece.contour)
        }
        reference = await referenceImage
        if piece.placements == nil { await search(force: false) }
    }

    private func search(force: Bool) async {
        isSearching = true
        errorMessage = await PieceLocator.locate(piece, puzzle: puzzle, force: force)
        isSearching = false
        if let best = placements.first, best.probability >= 0.6 { Haptics.success() }
    }
}

private struct CandidateRow: View {
    let index: Int
    let candidate: PlacementCandidate
    let reference: UIImage?
    let puzzle: Puzzle

    var body: some View {
        let color = Theme.candidateColors[index % Theme.candidateColors.count]
        HStack(spacing: 12) {
            closeup(color: color)
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(color).frame(width: 12, height: 12)
                    Text("Місце \(index + 1)").font(.headline)
                    Spacer()
                    Pill(text: "\(Int((candidate.probability * 100).rounded())) %", color: Theme.color(probability: candidate.probability))
                }
                Text("Рядок \(candidate.row) · стовпець \(candidate.column)").font(.subheadline)
                Text("\(Int((candidate.x * 100).rounded())) % ширини, \(Int((candidate.y * 100).rounded())) % висоти · збіг \(String(format: "%.2f", candidate.score))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .card()
    }

    /// The reference around the place, 3×3 cells.
    @ViewBuilder
    private func closeup(color: Color) -> some View {
        if let cg = reference?.cgImage {
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let half = 1.6 * w / CGFloat(puzzle.gridColumns)
            let crop = CGRect(x: candidate.x * w - half, y: candidate.y * h - half, width: half * 2, height: half * 2)
                .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
            if let part = cg.cropping(to: crop) {
                Image(uiImage: UIImage(cgImage: part))
                    .resizable()
                    .overlay {
                        GeometryReader { proxy in
                            let points = candidate.outline.map {
                                CGPoint(x: ($0.x * w - crop.minX) / crop.width, y: ($0.y * h - crop.minY) / crop.height)
                            }
                            outlinePath(points, in: proxy.size).stroke(color, lineWidth: 2)
                        }
                    }
            }
        } else {
            Color(.tertiarySystemFill)
        }
    }
}
