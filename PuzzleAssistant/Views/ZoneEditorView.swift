import SwiftData
import SwiftUI

/// Draw a rectangle on the picture (snapped to the piece grid) to assemble that area.
struct ZoneEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let puzzle: Puzzle
    let onCreated: (PuzzleZone) -> Void

    @State private var reference: UIImage?
    @State private var start: CGPoint?
    @State private var selection: CGRect?
    @State private var label = ""

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact {
                    HStack(spacing: 16) {
                        picture
                        ScrollView { controls }.frame(width: 300)
                    }
                } else {
                    VStack(spacing: 16) {
                        hint
                        picture
                        controls
                    }
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Нова ділянка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Скасувати") { dismiss() } } }
            .task { reference = ImageStore.shared.load(relativePath: puzzle.referenceThumbnailPath) }
        }
    }

    private var hint: some View {
        Text("Проведіть пальцем по картині, щоб виділити ділянку, яку збираєте зараз.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var picture: some View {
                GeometryReader { proxy in
                    if let reference {
                        let size = fitted(reference.size, in: proxy.size)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: reference).resizable().frame(width: size.width, height: size.height)
                            GridOverlay(grid: puzzle.grid).frame(width: size.width, height: size.height)
                            if let selection {
                                let r = CGRect(x: selection.minX * size.width, y: selection.minY * size.height,
                                               width: selection.width * size.width, height: selection.height * size.height)
                                // Dim everything outside the selection.
                                Path { path in
                                    path.addRect(CGRect(origin: .zero, size: size))
                                    path.addRect(r)
                                }
                                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                                Rectangle().stroke(Color.white, lineWidth: 2)
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let a = start ?? normalized(value.startLocation, size)
                                    start = a
                                    selection = snap(a, normalized(value.location, size))
                                }
                                .onEnded { _ in start = nil }
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var controls: some View {
            VStack(spacing: 16) {
                if verticalSizeClass == .compact { hint }
                if let selection {
                    let g = puzzle.grid
                    Label("≈ \(Int((selection.width * CGFloat(g.columns)).rounded())) × \(Int((selection.height * CGFloat(g.rows)).rounded())) шматків",
                          systemImage: "square.dashed")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField("Назва ділянки, напр. «Сова»", text: $label)
                    .padding(14)
                    .card()
                Button("Почати збирати") { save() }
                    .buttonStyle(PrimaryButtonStyle(enabled: selection != nil))
                    .disabled(selection == nil)
            }
    }

    private func fitted(_ image: CGSize, in container: CGSize) -> CGSize {
        let k = min(container.width / max(image.width, 1), container.height / max(image.height, 1))
        return CGSize(width: image.width * k, height: image.height * k)
    }

    private func normalized(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
    }

    /// Rectangle between two points, expanded to whole grid cells.
    private func snap(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let g = puzzle.grid
        let cols = CGFloat(g.columns), rows = CGFloat(g.rows)
        let x0 = (min(a.x, b.x) * cols).rounded(.down) / cols, x1 = (max(a.x, b.x) * cols).rounded(.up) / cols
        let y0 = (min(a.y, b.y) * rows).rounded(.down) / rows, y1 = (max(a.y, b.y) * rows).rounded(.up) / rows
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 1 / cols), height: max(y1 - y0, 1 / rows))
    }

    private func save() {
        guard let selection else { return }
        let name = label.trimmingCharacters(in: .whitespaces)
        let zone = PuzzleZone(label: name.isEmpty ? String(localized: "Ділянка \(puzzle.zones.count + 1)") : name, rect: selection)
        modelContext.insert(zone)
        zone.puzzle = puzzle
        Haptics.success()
        dismiss()
        onCreated(zone)
    }
}
