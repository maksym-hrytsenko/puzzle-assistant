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
    @State private var shareURL: URL?
    @State private var isPreparingShare = false

    private var freeCaptures: [PieceCapture] {
        puzzle.captures.filter { $0.zoneID == nil }.sorted { $0.capturedAt > $1.capturedAt }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                // Landscape: the picture on the left, everything else scrolls on the right.
                HStack(alignment: .top, spacing: 16) {
                    referenceCard
                    ScrollView { sections.padding(.vertical) }.frame(width: 380)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        referenceCard.frame(height: 340)
                        sections
                    }
                    .padding()
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(puzzle.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(action: share) {
                if isPreparingShare { ProgressView() } else { Image(systemName: "square.and.arrow.up") }
            }
            .disabled(isPreparingShare)
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(url: url).presentationDetents([.medium, .large])
        }
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

    private var sections: some View {
            VStack(alignment: .leading, spacing: 20) {
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
            .frame(maxHeight: .infinity)
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

    /// Packs the puzzle into a .puzzlemate file and opens the share sheet.
    private func share() {
        isPreparingShare = true
        let manifest = PuzzleArchive.manifest(for: puzzle)
        Task {
            do {
                shareURL = try await Task.detached(priority: .userInitiated) { try PuzzleArchive.write(manifest) }.value
            } catch {
                errorMessage = String(localized: "Не вдалося підготувати файл пазла.")
            }
            isPreparingShare = false
        }
    }

    private func startCapture(with image: UIImage, zone: PuzzleZone?) {
        do {
            openedCapture = try CaptureFactory.makeCapture(from: image, puzzle: puzzle, zone: zone, context: modelContext)
        } catch {
            errorMessage = String(localized: "Не вдалося зберегти фото.")
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
                (capture.detectionFinished ? Text("Знайдено шматків: \(capture.pieces.count)") : Text("Ще не оброблено"))
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
    let title: LocalizedStringKey
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

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text).font(.subheadline)
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
