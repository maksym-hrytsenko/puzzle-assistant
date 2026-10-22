import SwiftUI

/// Drag the 4 corners onto the corners of the picture; the photo is then
/// straightened into an exact rectangle (like a document scanner).
struct CornerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let image: CGImage
    let initialCorners: [CGPoint]?
    let onApply: ([CGPoint]) -> Void

    @State private var corners: [CGPoint] = []
    @State private var dragging: Int?

    private static let inset: [CGPoint] = [CGPoint(x: 0.08, y: 0.08), CGPoint(x: 0.92, y: 0.08),
                                           CGPoint(x: 0.92, y: 0.92), CGPoint(x: 0.08, y: 0.92)]

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if verticalSizeClass == .compact {
                    HStack(spacing: 16) {
                        editor
                        VStack(spacing: 14) { hint; Spacer(); buttons }.frame(width: 260)
                    }
                } else {
                    VStack(spacing: 14) { hint; editor; buttons }
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Кути картини")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Скасувати") { dismiss() } } }
            .onAppear { if corners.isEmpty { corners = initialCorners ?? Self.inset } }
        }
    }

    private var hint: some View {
        Text("Перетягніть кружечки точно в кути картини.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var editor: some View {
                GeometryReader { proxy in
                    let size = fitted(in: proxy.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: UIImage(cgImage: image)).resizable().frame(width: size.width, height: size.height)
                        if corners.count == 4 {
                            // Dim outside the selected quadrilateral.
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: size))
                                path.addLines(corners.map { point($0, size) })
                                path.closeSubpath()
                            }
                            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                            Path { path in
                                path.addLines(corners.map { point($0, size) })
                                path.closeSubpath()
                            }
                            .stroke(Theme.accent, lineWidth: 2)
                            ForEach(0..<4, id: \.self) { index in
                                handle(index: index, size: size)
                            }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
    }

    private var buttons: some View {
        VStack(spacing: 14) {
                HStack {
                    Button("Скинути") { corners = initialCorners ?? Self.inset }
                        .buttonStyle(.bordered)
                    Button("Весь кадр") {
                        corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                    }
                    .buttonStyle(.bordered)
                }
                Button("Вирівняти") {
                    onApply(corners)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func handle(index: Int, size: CGSize) -> some View {
        let p = point(corners[index], size)
        return ZStack {
            Circle().fill(Color.white.opacity(0.25)).frame(width: 44, height: 44)
            Circle().stroke(Color.white, lineWidth: 3).frame(width: 26, height: 26)
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
        }
        .scaleEffect(dragging == index ? 1.3 : 1)
        .position(p)
        .gesture(
            DragGesture(coordinateSpace: .local)
                .onChanged { value in
                    dragging = index
                    corners[index] = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                             y: min(max(value.location.y / size.height, 0), 1))
                }
                .onEnded { _ in dragging = nil }
        )
    }

    private func point(_ normalized: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func fitted(in container: CGSize) -> CGSize {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let k = min(container.width / w, container.height / h)
        return CGSize(width: w * k, height: h * k)
    }
}
