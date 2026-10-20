import SwiftData
import SwiftUI

struct PuzzleHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var puzzle: Puzzle

    @State private var reference: UIImage?
    @State private var showGrid = true
    @State private var showNewCapture = false
    @State private var showZoneEditor = false
    @State private var openedCapture: PieceCapture?
    @State private var openedZone: PuzzleZone?
    @State private var errorMessage: String?

    private var freeCaptures: [PieceCapture] {
        puzzle.captures.filter { $0.zoneID == nil }.sorted { $0.capturedAt > $1.capturedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                referenceCard
                HStack(spacing: 12) {
                    Button { showNewCapture = true } label: {
                        ActionTile(icon: "camera.viewfinder", title: "Знайти місця шматків",
                                   subtitle: "Сфотографуйте розкидані шматки й торкніться будь-якого")
                    }
                    Button { showZoneEditor = true } label: {
                        ActionTile(icon: "square.dashed.inset.filled", title: "Зібрати ділянку",
                                   subtitle: "Виділіть частину картини — знайду шматки саме для неї",
                                   tint: Color(red: 0.73, green: 0.32, blue: 0.93))
                    }
                }
                .buttonStyle(.plain)

                if !puzzle.zones.isEmpty { zonesSection }
                if !freeCaptures.isEmpty { capturesSection }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(puzzle.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reference = ImageStore.shared.load(relativePath: puzzle.referenceImagePath)
            await PuzzleEngine.shared.warmUp(puzzle.referenceInfo)
        }
        .sheet(isPresented: $showNewCapture) {
            NewCaptureSheet(title: "Фото розкиданих шматків") { image in
                startCapture(with: image, zone: nil)
            }
        }
        .sheet(isPresented: $showZoneEditor) {
            ZoneEditorView(puzzle: puzzle) { zone in openedZone = zone }
        }
        .navigationDestination(item: $openedCapture) { DetectionView(capture: $0, puzzle: puzzle) }
        .navigationDestination(item: $openedZone) { ZoneSessionView(zone: $0, puzzle: puzzle) }
        .alert("Помилка", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if let reference {
                    ZoomableImage(image: reference) { size, zoom in
                        ZStack {
                            if showGrid { GridOverlay(grid: puzzle.grid, zoom: zoom) }
                            ForEach(puzzle.zones) { zone in
                                let r = zone.rect
                                Rectangle()
                                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2 / zoom, dash: [6 / zoom, 4 / zoom]))
                                    .frame(width: r.width * size.width, height: r.height * size.height)
                                    .position(x: r.midX * size.width, y: r.midY * size.height)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(puzzle.pieceCount) шматків").font(.headline)
                    Text("Сітка \(puzzle.gridColumns) × \(puzzle.gridRows) · покладено \(puzzle.placedCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $showGrid) { Image(systemName: "grid") }
                    .toggleStyle(.button)
            }
        }
        .padding(12)
        .card()
    }

    private var zonesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ділянки").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(puzzle.zones.sorted { $0.createdAt > $1.createdAt }) { zone in
                        Button { openedZone = zone } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZoneThumbnail(reference: reference, rect: zone.rect)
                                    .frame(width: 150, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(zone.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(puzzle.captures.filter { $0.zoneID == zone.id }.count) фото")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 150)
                            .padding(10)
                            .card()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Видалити", systemImage: "trash", role: .destructive) { modelContext.delete(zone) }
                        }
                    }
                }
            }
        }
    }

    private var capturesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Фото шматків").font(.title3.bold())
            ForEach(freeCaptures) { capture in
                Button { openedCapture = capture } label: { CaptureRow(capture: capture) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Видалити", systemImage: "trash", role: .destructive) { delete(capture) }
                    }
            }
        }
    }

    private func startCapture(with image: UIImage, zone: PuzzleZone?) {
        do {
            openedCapture = try CaptureFactory.makeCapture(from: image, puzzle: puzzle, zone: zone, context: modelContext)
        } catch {
            errorMessage = "Не вдалося зберегти фото."
        }
    }

    private func delete(_ capture: PieceCapture) {
        ImageStore.shared.delete(relativePath: capture.photoPath)
        modelContext.delete(capture)
    }
}

/// Part of the reference picture.
struct ZoneThumbnail: View {
    let reference: UIImage?
    let rect: CGRect

    var body: some View {
        GeometryReader { proxy in
            if let reference, let cg = reference.cgImage {
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                let crop = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
                if let part = cg.cropping(to: crop) {
                    Image(uiImage: UIImage(cgImage: part)).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
            } else {
                Color(.tertiarySystemFill)
            }
        }
    }
}

struct CaptureRow: View {
    let capture: PieceCapture

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let path = capture.thumbnailPath, let image = ImageStore.shared.load(relativePath: path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
                Text(capture.detectionFinished ? "Знайдено шматків: \(capture.pieces.count)" : "Ще не оброблено")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(10)
        .card()
    }
}

/// Sheet for choosing a photo of loose pieces.
struct NewCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onImage: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                tip("square.grid.3x3.middle.filled", "Розкладіть шматки картинкою догори, бажано не один на одному.")
                tip("sun.max", "Рівне світло без відблисків — так кольори ближчі до картини.")
                tip("iphone.gen3", "Тримайте телефон паралельно до столу; у кадрі 50–300 шматків.")
                tip("hand.tap", "Пропущений шматок можна додати дотиком, а зайвий — видалити.")
                Spacer()
                PhotoSourceButtons(cameraHint: "Тримайте телефон паралельно до столу") { image in
                    dismiss()
                    onImage(image)
                }
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Скасувати") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text).font(.subheadline)
        }
    }
}
