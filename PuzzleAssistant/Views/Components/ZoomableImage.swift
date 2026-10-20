import SwiftUI

/// An image fitted into the available space with pinch-to-zoom and pan.
/// The overlay is drawn in the fitted image's coordinate space, and taps are
/// reported as normalized image coordinates (0...1).
struct ZoomableImage<Overlay: View>: View {
    let image: UIImage
    var onTap: ((CGPoint) -> Void)?
    @ViewBuilder var overlay: (_ size: CGSize, _ zoom: CGFloat) -> Overlay

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let fitted = fittedSize(in: proxy.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                overlay(fitted, zoom)
                    .frame(width: fitted.width, height: fitted.height)
                    .allowsHitTesting(false)
            }
            .frame(width: fitted.width, height: fitted.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                onTap?(CGPoint(x: location.x / fitted.width, y: location.y / fitted.height))
            }
            .scaleEffect(zoom)
            .offset(offset)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(lastZoom * value.magnification, 1), 12)
                        }
                        .onEnded { _ in
                            lastZoom = zoom
                            clampOffset(fitted: fitted, container: proxy.size)
                        },
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard zoom > 1 else { return }
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in clampOffset(fitted: fitted, container: proxy.size) }
                )
            )
            .overlay(alignment: .topTrailing) {
                if zoom > 1.05 {
                    Button {
                        withAnimation(.spring) { resetZoom() }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.footnote.weight(.bold))
                            .padding(9)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(10)
                }
            }
        }
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let k = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * k, height: imageSize.height * k)
    }

    private func resetZoom() {
        zoom = 1; lastZoom = 1
        offset = .zero; lastOffset = .zero
    }

    private func clampOffset(fitted: CGSize, container: CGSize) {
        if zoom <= 1.01 {
            withAnimation(.spring) { resetZoom() }
            return
        }
        let maxX = max(0, (fitted.width * zoom - container.width) / 2)
        let maxY = max(0, (fitted.height * zoom - container.height) / 2)
        withAnimation(.spring) {
            offset = CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
        }
        lastOffset = offset
    }
}

/// Path of a normalized polygon in a view of the given size.
func outlinePath(_ points: [CGPoint], in size: CGSize) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
    for p in points.dropFirst() {
        path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
    }
    path.closeSubpath()
    return path
}

/// Thin grid lines (every 10th line stronger) over the reference picture.
struct GridOverlay: View {
    let grid: PuzzleGrid
    var zoom: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let thin = Path { path in
                for c in 1..<grid.columns where c % 10 != 0 {
                    let x = size.width * CGFloat(c) / CGFloat(grid.columns)
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for r in 1..<grid.rows where r % 10 != 0 {
                    let y = size.height * CGFloat(r) / CGFloat(grid.rows)
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            let thick = Path { path in
                for c in Swift.stride(from: 10, to: grid.columns, by: 10) {
                    let x = size.width * CGFloat(c) / CGFloat(grid.columns)
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for r in Swift.stride(from: 10, to: grid.rows, by: 10) {
                    let y = size.height * CGFloat(r) / CGFloat(grid.rows)
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            // Thin lines only when cells are big enough on screen.
            if size.width * zoom / CGFloat(grid.columns) > 6 {
                context.stroke(thin, with: .color(.white.opacity(0.35)), lineWidth: 0.5 / zoom)
            }
            context.stroke(thick, with: .color(.white.opacity(0.75)), lineWidth: 1.2 / zoom)
        }
    }
}
