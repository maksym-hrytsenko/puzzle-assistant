import SwiftUI
import SwiftData

struct ZoneSelectionView: View {
    let puzzle: Puzzle

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var label = ""
    @State private var dragStart: CGPoint?
    @State private var selectionRect: CGRect = .zero
    @State private var containerSize: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        if let path = puzzle.referenceImagePath, let image = ImageStore.shared.load(relativePath: path) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        if selectionRect != .zero {
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.15))
                                .frame(width: selectionRect.width, height: selectionRect.height)
                                .offset(x: selectionRect.origin.x, y: selectionRect.origin.y)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                containerSize = geo.size
                                let start = dragStart ?? value.startLocation
                                dragStart = start
                                selectionRect = CGRect(
                                    x: min(start.x, value.location.x),
                                    y: min(start.y, value.location.y),
                                    width: abs(value.location.x - start.x),
                                    height: abs(value.location.y - start.y)
                                )
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                }
                .aspectRatio(referenceAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Text("Drag over the reference image to mark the area you want to work on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                TextField("Zone name (e.g. \"Top-left corner\")", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Select a Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || selectionRect == .zero)
                }
            }
        }
    }

    private var referenceAspectRatio: CGFloat {
        puzzle.referenceImageHeight > 0 ? CGFloat(puzzle.referenceImageWidth) / CGFloat(puzzle.referenceImageHeight) : 1
    }

    private func save() {
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        let normalizedRect = CGRect(
            x: selectionRect.origin.x / containerSize.width,
            y: selectionRect.origin.y / containerSize.height,
            width: selectionRect.width / containerSize.width,
            height: selectionRect.height / containerSize.height
        )
        let zone = Zone(label: label.trimmingCharacters(in: .whitespaces), normalizedRect: normalizedRect)
        zone.puzzle = puzzle
        modelContext.insert(zone)

        let event = SessionEvent(kind: .zoneCreated, summary: "Zone \"\(zone.label)\" defined.")
        event.puzzle = puzzle
        modelContext.insert(event)

        dismiss()
    }
}
