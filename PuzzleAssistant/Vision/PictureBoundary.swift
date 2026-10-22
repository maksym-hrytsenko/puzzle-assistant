import CoreGraphics
import Foundation

/// Precise corners of the finished picture on a photo (box, poster, assembled puzzle).
///
/// 1. SAM 2.1 outlines the *table* around the picture: positive prompts along the
///    photo border, a negative one in the middle. A busy picture is many objects
///    for SAM, but a plain table is one, so this mask is clean.
/// 2. The picture is the largest region that is not table.
/// 3. A straight line is fitted to each side of its outline (robust fit, so a
///    curled corner does not bend it), then snapped to the strongest brightness
///    edge next to it on the photo itself (sharper than the 1024 px mask).
enum PictureBoundary {
    /// Corners (top-left, top-right, bottom-right, bottom-left) normalized, y down.
    static func corners(in image: CGImage, sam: SAMSegmenter) -> [CGPoint]? {
        let size = SAMSegmenter.inputSize
        // The whole photo squeezed into 1024×1024: lines stay lines under per-axis scaling.
        guard let square = RGBAImage(cgImage: image, width: size, height: size)?.cgImage(),
              let embedding = try? sam.encode(square) else { return nil }
        let s = CGFloat(size), e: CGFloat = 12
        var prompts: [(point: CGPoint, label: Int)] = [(e, e), (s / 2, e), (s - e, e), (s - e, s / 2), (s - e, s - e),
                                                       (s / 2, s - e), (e, s - e), (e, s / 2)]
            .map { (CGPoint(x: $0.0, y: $0.1), 1) }
        prompts.append((CGPoint(x: s / 2, y: s / 2), 0))
        guard let masks = try? sam.masks(for: prompts, in: embedding), let table = masks.first else { return nil }

        let n = SAMSegmenter.maskSize
        let tableShare = Double(table.logits.filter { $0 > 0 }.count) / Double(n * n)
        // No table visible: the photo is the picture itself (e.g. a downloaded image).
        if tableShare < 0.01 {
            return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        }
        let notTable = BinaryMask(width: n, height: n, pixels: table.logits.map { $0 <= 0 })
        guard let picture = largestComponent(notTable) else { return nil }
        let share = Double(picture.area) / Double(n * n)
        guard share > 0.15, share < 0.995 else { return nil }

        // Outline in normalized coordinates.
        let outline = picture.outerContour().map { CGPoint(x: $0.x / CGFloat(n), y: $0.y / CGFloat(n)) }
        guard outline.count > 20 else { return nil }
        let rough = extremeCorners(Geometry.convexHull(outline))
        guard let fitted = fitSides(rough, points: outline) else { return rough }
        return snapToEdges(fitted, image: image) ?? fitted
    }

    // MARK: - Geometry

    private static func largestComponent(_ mask: BinaryMask) -> BinaryMask? {
        var visited = [Bool](repeating: false, count: mask.pixels.count)
        var best: BinaryMask?
        var bestArea = 0
        for i in 0..<mask.pixels.count where mask.pixels[i] && !visited[i] {
            guard let component = mask.component(containing: i % mask.width, i / mask.width) else { continue }
            var area = 0
            for j in 0..<component.pixels.count where component.pixels[j] {
                visited[j] = true
                area += 1
            }
            if area > bestArea { bestArea = area; best = component }
        }
        return best
    }

    /// Hull points closest to the 4 frame corners.
    static func extremeCorners(_ hull: [CGPoint]) -> [CGPoint] {
        let tl = hull.min { $0.x + $0.y < $1.x + $1.y }!, br = hull.max { $0.x + $0.y < $1.x + $1.y }!
        let tr = hull.max { $0.x - $0.y < $1.x - $1.y }!, bl = hull.min { $0.x - $0.y < $1.x - $1.y }!
        return [tl, tr, br, bl]
    }

    /// A line through the outline points near each side of the rough quad, then
    /// the 4 intersections.
    private static func fitSides(_ quad: [CGPoint], points: [CGPoint]) -> [CGPoint]? {
        var lines: [Line] = []
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let length = hypot(d.x, d.y)
            guard length > 0.05 else { return nil }
            let normal = CGPoint(x: -d.y / length, y: d.x / length)
            let side = points.filter { p in
                let t = ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / (length * length)
                let dist = abs((p.x - a.x) * normal.x + (p.y - a.y) * normal.y)
                return t > 0.1 && t < 0.9 && dist < 0.03
            }
            guard let line = Line.robustFit(side) else { return nil }
            lines.append(line)
        }
        var corners: [CGPoint] = []
        for i in 0..<4 {
            guard let p = lines[(i + 3) % 4].intersection(lines[i]) else { return nil }
            corners.append(p)
        }
        // Reject a fit that wandered far from the rough corners.
        for (p, q) in zip(corners, quad) where hypot(p.x - q.x, p.y - q.y) > 0.08 { return nil }
        return corners
    }

    /// Moves each side onto the strongest brightness step within a narrow band.
    private static func snapToEdges(_ quad: [CGPoint], image: CGImage) -> [CGPoint]? {
        let maxSide = 2048.0
        let k = min(1, maxSide / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * k), h = Int(Double(image.height) * k)
        guard let rgba = RGBAImage(cgImage: image, width: w, height: h) else { return nil }
        var luma = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let (r, g, b) = rgba.rgb(i % w, i / w)
            luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        func sample(_ x: Double, _ y: Double) -> Float? {
            guard x >= 0, y >= 0, x < Double(w - 1), y < Double(h - 1) else { return nil }
            let x0 = Int(x), y0 = Int(y)
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            let a = luma[y0 * w + x0] * (1 - fx) + luma[y0 * w + x0 + 1] * fx
            let b = luma[(y0 + 1) * w + x0] * (1 - fx) + luma[(y0 + 1) * w + x0 + 1] * fx
            return a * (1 - fy) + b * fy
        }
        let pixels = quad.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) }
        let center = Geometry.centroid(pixels)
        let band = Double(min(w, h)) * 0.015
        var lines: [Line] = []
        for i in 0..<4 {
            let a = pixels[i], b = pixels[(i + 1) % 4]
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let length = hypot(dx, dy)
            var nx = -dy / length, ny = dx / length
            // Normal pointing outwards.
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if nx * Double(mid.x - center.x) + ny * Double(mid.y - center.y) < 0 { nx = -nx; ny = -ny }
            var edgePoints: [CGPoint] = []
            for step in 1..<60 {
                let t = 0.08 + 0.84 * Double(step) / 60
                let px = Double(a.x) + dx * t, py = Double(a.y) + dy * t
                var bestOffset = 0.0, bestGradient: Float = 0
                var offset = -band
                while offset <= band {
                    if let inside = sample(px + (offset - 1.5) * nx, py + (offset - 1.5) * ny),
                       let outside = sample(px + (offset + 1.5) * nx, py + (offset + 1.5) * ny) {
                        let gradient = abs(inside - outside)
                        if gradient > bestGradient { bestGradient = gradient; bestOffset = offset }
                    }
                    offset += 0.5
                }
                if bestGradient > 12 {
                    edgePoints.append(CGPoint(x: px + bestOffset * nx, y: py + bestOffset * ny))
                }
            }
            // Too few clear edge points: keep the mask line for this side.
            if edgePoints.count >= 15, let line = Line.robustFit(edgePoints) {
                lines.append(line)
            } else {
                guard let line = Line.through(a, b) else { return nil }
                lines.append(line)
            }
        }
        var corners: [CGPoint] = []
        for i in 0..<4 {
            guard let p = lines[(i + 3) % 4].intersection(lines[i]) else { return nil }
            guard hypot(p.x - pixels[i].x, p.y - pixels[i].y) < CGFloat(band * 2) else { return nil }
            corners.append(CGPoint(x: p.x / CGFloat(w), y: p.y / CGFloat(h)))
        }
        return corners
    }
}

/// A line n·p = c with |n| = 1.
struct Line {
    let normal: CGPoint
    let offset: CGFloat

    static func through(_ a: CGPoint, _ b: CGPoint) -> Line? {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let n = CGPoint(x: -dy / length, y: dx / length)
        return Line(normal: n, offset: n.x * a.x + n.y * a.y)
    }

    /// Total least squares with Huber-style reweighting (outliers count less).
    static func robustFit(_ points: [CGPoint]) -> Line? {
        guard points.count >= 3 else { return nil }
        var weights = [CGFloat](repeating: 1, count: points.count)
        var line: Line?
        for _ in 0..<6 {
            let total = weights.reduce(0, +)
            guard total > 0 else { return line }
            var mx: CGFloat = 0, my: CGFloat = 0
            for (p, w) in zip(points, weights) { mx += p.x * w; my += p.y * w }
            mx /= total; my /= total
            var sxx: CGFloat = 0, sxy: CGFloat = 0, syy: CGFloat = 0
            for (p, w) in zip(points, weights) {
                let dx = p.x - mx, dy = p.y - my
                sxx += w * dx * dx; sxy += w * dx * dy; syy += w * dy * dy
            }
            // Direction = principal eigenvector of the covariance.
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let n = CGPoint(x: -sin(angle), y: cos(angle))
            let fitted = Line(normal: n, offset: n.x * mx + n.y * my)
            line = fitted
            let residuals = points.map { abs(fitted.distance($0)) }
            let scale = max(residuals.sorted()[residuals.count / 2] * 1.5, 1e-6)
            weights = residuals.map { $0 <= scale ? 1 : scale / $0 }
        }
        return line
    }

    func distance(_ p: CGPoint) -> CGFloat { normal.x * p.x + normal.y * p.y - offset }

    func intersection(_ other: Line) -> CGPoint? {
        let det = normal.x * other.normal.y - normal.y * other.normal.x
        guard abs(det) > 1e-9 else { return nil }
        return CGPoint(x: (offset * other.normal.y - normal.y * other.offset) / det,
                       y: (normal.x * other.offset - offset * other.normal.x) / det)
    }
}
