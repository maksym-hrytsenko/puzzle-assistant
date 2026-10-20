import SwiftData
import SwiftUI

/// A photo of loose pieces with every found piece outlined.
/// Tap a piece to see where it belongs, delete badly found ones, or add missed ones.
struct DetectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var capture: PieceCapture
    let puzzle: Puzzle

    enum Mode: String, CaseIterable, Identifiable {
        case locate = "Де місце?"
        case delete = "Видалити"
        case add = "Додати"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .locate: return "scope"
            case .delete: return "trash"
            case .add: return "plus.viewfinder"
            }
        }
        var hint: String {
            switch self {
            case .locate: return "Торкніться шматка — покажу, де він на картині"
            case .delete: return "Торкніться погано обведеного шматка, щоб прибрати його"
            case .add: return "Торкніться пропущеного шматка, щоб обвести його"
            }
        }
    }

    @State private var photo: UIImage?
    @State private var mode: Mode = .locate
    @State private var selectedPiece: DetectedPiece?
    @State private var progress: Double = 0
    @State private var progressText = ""
    @State private var isDetecting = false
    @State private var isMatchingZone = false
    @State private var matchedCount = 0
    @State private var isAdding = false
    @State private var cancelFlag = CancellationFlag()
    @State private var errorMessage: String?
    @State private var toast: String?

    private var zone: PuzzleZone? {
        guard let id = capture.zoneID else { return nil }
        return puzzle.zones.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isDetecting {
                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            ZStack {
                Color.black
                if let photo {
                    ZoomableImage(image: photo, onTap: handleTap) { size, zoom in
                        outlines(size: size, zoom: zoom)
                    }
                }
                if isDetecting { detectionOverlay }
                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            bottomBar
        }
        .navigationTitle(zone.map { "Ділянка «\($0.label)»" } ?? "Шматки на фото")
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear { cancelFlag.cancel() }
        .sheet(item: $selectedPiece) { piece in
            PieceLocationView(piece: piece, puzzle: puzzle, zone: zone)
        }
        .alert("Помилка", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Drawing

    private func outlines(size: CGSize, zoom: CGFloat) -> some View {
        let pieces = capture.pieces
        return Canvas { context, _ in
            for piece in pieces {
                let path = outlinePath(piece.contour, in: size)
                let color = outlineColor(piece)
                if case .fits = zone.map({ piece.fit(in: $0, grid: puzzle.grid) }) ?? .unknown {
                    context.fill(path, with: .color(Theme.good.opacity(0.25)))
                }
                if piece.isPlaced {
                    context.fill(path, with: .color(.black.opacity(0.55)))
                }
                context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4 / zoom)
                context.stroke(path, with: .color(color), lineWidth: 2.2 / zoom)
            }
        }
    }

    private func outlineColor(_ piece: DetectedPiece) -> Color {
        if piece.isPlaced { return .gray }
        if let zone {
            switch piece.fit(in: zone, grid: puzzle.grid) {
            case .fits: return Theme.good
            case .maybe: return Theme.maybe
            case .no: return .white.opacity(0.35)
            case .unknown: return .white
            }
        }
        guard let best = piece.bestPlacement else { return Theme.neutral }
        return Theme.color(probability: best.probability)
    }

    private var detectionOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
                .tint(.white)
                .frame(width: 220)
            Text(progressText).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
            Text("Нейромережа обводить кожен шматок окремо").font(.caption).foregroundStyle(.secondary)
            Button("Зупинити") { cancelFlag.cancel() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if isMatchingZone {
                ProgressView(value: Double(matchedCount), total: Double(max(capture.pieces.count, 1))) {
                    Text("Перевіряю шматки для ділянки: \(matchedCount) з \(capture.pieces.count)")
                        .font(.caption)
                }
                .tint(Theme.good)
            } else if let zone {
                let fits = capture.pieces.filter { if case .fits = $0.fit(in: zone, grid: puzzle.grid) { return true }; return false }.count
                let maybe = capture.pieces.filter { if case .maybe = $0.fit(in: zone, grid: puzzle.grid) { return true }; return false }.count
                HStack(spacing: 14) {
                    Label("Підходять: \(fits)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    Label("Можливо: \(maybe)", systemImage: "questionmark.circle.fill").foregroundStyle(Theme.maybe)
                }
                .font(.subheadline.weight(.semibold))
            }
            HStack {
                Text(isDetecting ? "Шукаю шматки…" : "Обведено шматків: \(capture.pieces.count)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isAdding { ProgressView() }
            }
            Text(mode.hint).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Actions

    private func start() async {
        if photo == nil {
            let path = capture.photoPath
            photo = await Task.detached { ImageStore.shared.load(relativePath: path) }.value
        }
        if !capture.detectionFinished {
            await detect()
        }
        if zone != nil { await matchAllForZone() }
    }

    private func detect() async {
        isDetecting = true
        cancelFlag = CancellationFlag()
        let flag = cancelFlag
        do {
            let result = try await PuzzleEngine.shared.detectPieces(photoPath: capture.photoPath, cancel: flag) { value, text in
                Task { @MainActor in
                    progress = value
                    progressText = text
                }
            }
            for outline in result.pieces {
                let piece = DetectedPiece(outline: outline)
                modelContext.insert(piece)
                piece.capture = capture
            }
            capture.colorStats = result.colorStats
            capture.typicalPieceArea = result.typicalArea
            capture.detectionFinished = true
            if result.pieces.isEmpty {
                showToast("Шматків не знайдено — спробуйте інше фото")
            } else {
                Haptics.success()
            }
        } catch is CancellationError {
            showToast("Пошук зупинено")
        } catch {
            errorMessage = error.localizedDescription
        }
        isDetecting = false
    }

    private func matchAllForZone() async {
        let pending = capture.pieces.filter { $0.placements == nil && !$0.isPlaced }
        guard !pending.isEmpty else { return }
        isMatchingZone = true
        matchedCount = capture.pieces.count - pending.count
        let flag = cancelFlag
        for piece in pending {
            if flag.isCancelled { break }
            await PieceLocator.locate(piece, puzzle: puzzle)
            matchedCount += 1
        }
        isMatchingZone = false
    }

    private func handleTap(_ point: CGPoint) {
        guard !isDetecting else { return }
        let hit = capture.pieces.last { Geometry.contains($0.contour, point) }
        switch mode {
        case .locate:
            if let hit { Haptics.tap(); selectedPiece = hit }
        case .delete:
            if let hit {
                Haptics.warning()
                withAnimation { modelContext.delete(hit) }
                showToast("Шматок прибрано")
            }
        case .add:
            guard hit == nil, !isAdding else { return }
            isAdding = true
            let typical = capture.typicalPieceArea
            Task {
                do {
                    if let outline = try await PuzzleEngine.shared.segmentPiece(at: point, photoPath: capture.photoPath,
                                                                                typicalArea: typical) {
                        let piece = DetectedPiece(outline: outline)
                        modelContext.insert(piece)
                        piece.capture = capture
                        Haptics.success()
                        showToast("Шматок додано")
                    } else {
                        showToast("Тут не вдалося знайти шматок")
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
                isAdding = false
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if toast == text { toast = nil } }
        }
    }
}

/// Runs the location search for a piece and stores the result.
@MainActor
enum PieceLocator {
    @discardableResult
    static func locate(_ piece: DetectedPiece, puzzle: Puzzle, force: Bool = false) async -> String? {
        if piece.placements != nil && !force { return nil }
        guard let capture = piece.capture else { return nil }
        do {
            let placements = try await PuzzleEngine.shared.locate(
                puzzle.referenceInfo, photoPath: capture.photoPath, contour: piece.contour, area: piece.area,
                colorStats: capture.colorStats, scaleHint: capture.scaleHint)
            piece.placements = placements
            // A confident match tells the real scale of this photo; reuse it for the other pieces.
            if capture.scaleHint == nil, let best = placements.first, best.probability >= 0.6 {
                capture.scaleHint = best.scaleMultiplier
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
