import SwiftData
import SwiftUI

/// Step-by-step assembly of a zone: the pieces found for it, in reading order,
/// each with its orientation and where it goes relative to pieces already placed.
struct ZoneAssemblyView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let zone: PuzzleZone
    let puzzle: Puzzle

    @State private var reference: UIImage?
    @State private var images: [UUID: UIImage] = [:]
    @State private var stepIndex = 0
    @State private var showPicture = true
    @State private var showSource = false

    struct Step: Identifiable {
        let piece: DetectedPiece
        let place: PlacementCandidate
        var id: UUID { piece.id }
    }

    /// Pieces that belong to the zone, top-to-bottom, left-to-right.
    private var steps: [Step] {
        let grid = puzzle.grid
        let pieces = puzzle.captures.filter { $0.zoneID == zone.id }.flatMap(\.pieces)
        var steps: [Step] = []
        for piece in pieces {
            switch piece.fit(in: zone, grid: grid) {
            case .fits(let c), .maybe(let c): steps.append(Step(piece: piece, place: c))
            default: break
            }
        }
        // Several photos may contain the same physical piece: keep the most likely per cell.
        var byCell: [String: Step] = [:]
        for step in steps {
            let key = "\(step.place.row)-\(step.place.column)"
            if let existing = byCell[key], existing.place.probability >= step.place.probability { continue }
            byCell[key] = step
        }
        return byCell.values.sorted { ($0.place.row, $0.place.column) < ($1.place.row, $1.place.column) }
    }

    var body: some View {
        let steps = self.steps
        Group {
            if steps.isEmpty {
                ContentUnavailableView("Ще немає шматків для ділянки",
                                       systemImage: "puzzlepiece",
                                       description: Text("Сфотографуйте розкидані шматки — знайдені для цієї ділянки з'являться тут."))
            } else {
                let index = min(stepIndex, steps.count - 1)
                AdaptiveSplit(panelWidth: 340) {
                    map(steps: steps, current: index)
                        .padding(8)
                } panel: {
                    ScrollView { stepCard(steps: steps, index: index).padding() }
                        .frame(maxHeight: verticalSizeClass == .compact ? .infinity : 330)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Збираємо «\(zone.label)»")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Toggle(isOn: $showPicture) { Image(systemName: "photo") }
                .toggleStyle(.button)
        }
        .task {
            reference = ImageStore.shared.load(relativePath: puzzle.referenceImagePath)
            stepIndex = steps.firstIndex { !$0.piece.isPlaced } ?? 0
            for step in steps where images[step.piece.id] == nil {
                if let path = step.piece.capture?.photoPath,
                   let image = await PuzzleEngine.shared.pieceImage(photoPath: path, contour: step.piece.contour) {
                    images[step.piece.id] = image
                }
            }
        }
        .sheet(isPresented: $showSource) {
            let all = self.steps
            if !all.isEmpty { SourcePhotoView(piece: all[min(stepIndex, all.count - 1)].piece) }
        }
    }

    // MARK: - Map of the zone

    /// The zone (plus half a cell around) with the pieces drawn at their places.
    private var visibleRect: CGRect {
        let g = puzzle.grid
        return zone.rect.insetBy(dx: -0.5 / CGFloat(g.columns), dy: -0.5 / CGFloat(g.rows))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func map(steps: [Step], current: Int) -> some View {
        let rect = visibleRect
        let aspect = rect.width * CGFloat(puzzle.referenceWidth) / max(rect.height * CGFloat(puzzle.referenceHeight), 1)
        return GeometryReader { proxy in
            let size = fit(aspect: aspect, in: proxy.size)
            ZStack(alignment: .topLeading) {
                ZoneThumbnail(reference: reference, rect: rect)
                    .opacity(showPicture ? 0.55 : 0.12)
                    .frame(width: size.width, height: size.height)
                // Piece photos at their places: placed ones solid, the current one highlighted.
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    pieceOnMap(step, index: index, current: current, rect: rect, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func pieceOnMap(_ step: Step, index: Int, current: Int, rect: CGRect, size: CGSize) -> some View {
        let place = step.place
        let center = CGPoint(x: (place.x - rect.minX) / rect.width * size.width,
                             y: (place.y - rect.minY) / rect.height * size.height)
        let cellPoints = size.width / (rect.width * CGFloat(puzzle.gridColumns))
        let outline = place.outline.map {
            CGPoint(x: ($0.x - rect.minX) / rect.width * size.width, y: ($0.y - rect.minY) / rect.height * size.height)
        }
        let isCurrent = index == current
        ZStack {
            if (step.piece.isPlaced || isCurrent), let image = images[step.piece.id], let k = place.cellsPerPhotoPixel {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * k * cellPoints, height: image.size.height * k * cellPoints)
                    .rotationEffect(.degrees(place.rotationDegrees))
                    .position(center)
                    .opacity(step.piece.isPlaced ? 1 : 0.85)
            }
            outlinePolygon(outline)
                .stroke(isCurrent ? Theme.good : Color.white.opacity(step.piece.isPlaced ? 0.0 : 0.6),
                        lineWidth: isCurrent ? 3 : 1)
            if !step.piece.isPlaced {
                Text("\(index + 1)")
                    .font(.system(size: max(9, cellPoints * 0.35), weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(isCurrent ? Theme.good : Color.black.opacity(0.55), in: Circle())
                    .position(center)
            }
        }
        .contentShape(outlinePolygon(outline))
        .onTapGesture { stepIndex = index }
    }

    private func outlinePolygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    private func fit(aspect: CGFloat, in container: CGSize) -> CGSize {
        guard aspect > 0, container.width > 0, container.height > 0 else { return .zero }
        return container.width / container.height > aspect
            ? CGSize(width: container.height * aspect, height: container.height)
            : CGSize(width: container.width, height: container.width / aspect)
    }

    // MARK: - Step card

    private func stepCard(steps: [Step], index: Int) -> some View {
        let step = steps[index]
        let placedCount = steps.filter(\.piece.isPlaced).count
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Крок \(index + 1) з \(steps.count)").font(.headline)
                Spacer()
                Text("покладено \(placedCount)").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(placedCount), total: Double(steps.count)).tint(Theme.good)

            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Color(.tertiarySystemFill)
                    if let image = images[step.piece.id] {
                        Image(uiImage: image).resizable().scaledToFit().padding(8)
                            .rotationEffect(.degrees(step.place.rotationDegrees))
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: instruction(for: index, in: steps)).font(.subheadline)
                    HStack {
                        Pill(text: "\(Int((step.place.probability * 100).rounded())) %",
                             color: Theme.color(probability: step.place.probability))
                        Text("р. \(step.place.row) · ст. \(step.place.column)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Поверніть шматок так, як на мініатюрі.").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Button {
                step.piece.isPlaced.toggle()
                Haptics.success()
                if step.piece.isPlaced, let next = nextUnplaced(after: index, in: steps) {
                    withAnimation { stepIndex = next }
                }
            } label: {
                Label(step.piece.isPlaced ? LocalizedStringKey("Ще не покладено") : LocalizedStringKey("Поклав(-ла)"),
                      systemImage: step.piece.isPlaced ? "arrow.uturn.backward" : "checkmark.seal.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: 10) {
                Button { withAnimation { stepIndex = max(0, index - 1) } } label: {
                    Image(systemName: "chevron.left").frame(maxWidth: .infinity)
                }
                .disabled(index == 0)
                Button { showSource = true } label: {
                    Label("Де він лежить?", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                Button { withAnimation { stepIndex = min(steps.count - 1, index + 1) } } label: {
                    Image(systemName: "chevron.right").frame(maxWidth: .infinity)
                }
                .disabled(index == steps.count - 1)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private func nextUnplaced(after index: Int, in steps: [Step]) -> Int? {
        let order = Array(steps.indices.dropFirst(index + 1)) + Array(steps.indices.prefix(index))
        return order.first { !steps[$0].piece.isPlaced }
    }

    /// Where the piece goes, relative to a neighbour that is already placed (or
    /// to the previous step when nothing is placed nearby yet).
    private func instruction(for index: Int, in steps: [Step]) -> String {
        let place = steps[index].place
        let candidates = steps.indices.filter { $0 != index && (steps[$0].piece.isPlaced || $0 < index) }
        let neighbour = candidates
            .map { ($0, abs(steps[$0].place.row - place.row) + abs(steps[$0].place.column - place.column)) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }
        guard let (other, _) = neighbour else {
            return String(localized: "Почніть із цього шматка: рядок \(place.row), стовпець \(place.column).")
        }
        let dr = place.row - steps[other].place.row, dc = place.column - steps[other].place.column
        // Full sentences per direction: word order differs between languages.
        let step = other + 1
        let sentence: String
        switch (dr.signum(), dc.signum()) {
        case (0, 1): sentence = String(localized: "Кладіть праворуч від шматка з кроку \(step).")
        case (0, -1): sentence = String(localized: "Кладіть ліворуч від шматка з кроку \(step).")
        case (1, 0): sentence = String(localized: "Кладіть під шматком з кроку \(step).")
        case (-1, 0): sentence = String(localized: "Кладіть над шматком з кроку \(step).")
        case (1, 1): sentence = String(localized: "Кладіть по діагоналі: нижче й правіше від шматка з кроку \(step).")
        case (1, -1): sentence = String(localized: "Кладіть по діагоналі: нижче й лівіше від шматка з кроку \(step).")
        case (-1, 1): sentence = String(localized: "Кладіть по діагоналі: вище й правіше від шматка з кроку \(step).")
        case (-1, -1): sentence = String(localized: "Кладіть по діагоналі: вище й лівіше від шматка з кроку \(step).")
        default: sentence = String(localized: "Кладіть поруч зі шматком з кроку \(step).")
        }
        return max(abs(dr), abs(dc)) > 1 ? sentence + " " + String(localized: "(через одну клітинку)") : sentence
    }
}

/// The photo of loose pieces with one piece highlighted, to find it on the table.
private struct SourcePhotoView: View {
    @Environment(\.dismiss) private var dismiss
    let piece: DetectedPiece
    @State private var photo: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let photo {
                    ZoomableImage(image: photo) { size, zoom in
                        Canvas { context, _ in
                            let path = outlinePath(piece.contour, in: size)
                            // Dim everything except the piece.
                            var dim = Path(CGRect(origin: .zero, size: size))
                            dim.addPath(path)
                            context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                            context.stroke(path, with: .color(Theme.good), lineWidth: 3 / zoom)
                        }
                    }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("Цей шматок на фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task {
                if let path = piece.capture?.photoPath {
                    photo = await Task.detached { ImageStore.shared.load(relativePath: path) }.value
                }
            }
        }
    }
}
