import CoreGraphics
import Foundation

/// A binary mask stored row-major, `true` = object.
struct BinaryMask {
    let width: Int
    let height: Int
    var pixels: [Bool]

    init(width: Int, height: Int, pixels: [Bool]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> Bool {
        pixels[y * width + x]
    }

    var area: Int { pixels.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// The 4-connected component containing (x, y); nil when that pixel is empty.
    func component(containing x: Int, _ y: Int) -> BinaryMask? {
        guard x >= 0, y >= 0, x < width, y < height, self[x, y] else { return nil }
        var out = [Bool](repeating: false, count: pixels.count)
        var stack = [y * width + x]
        out[y * width + x] = true
        while let index = stack.popLast() {
            let px = index % width, py = index / width
            for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]
            where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let n = ny * width + nx
                if pixels[n] && !out[n] {
                    out[n] = true
                    stack.append(n)
                }
            }
        }
        return BinaryMask(width: width, height: height, pixels: out)
    }

    /// Bounding box in pixel units (inclusive min, exclusive max).
    var boundingBox: CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Points that bound the mask from the left and right on every row; their
    /// convex hull equals the hull of the whole mask.
    var rowExtremes: [CGPoint] {
        var points: [CGPoint] = []
        for y in 0..<height {
            let row = y * width
            var first = -1, last = -1
            for x in 0..<width where pixels[row + x] {
                if first < 0 { first = x }
                last = x
            }
            if first >= 0 {
                // Pixel corners, so that the hull covers whole pixels.
                points.append(CGPoint(x: first, y: y))
                points.append(CGPoint(x: first, y: y + 1))
                points.append(CGPoint(x: last + 1, y: y))
                points.append(CGPoint(x: last + 1, y: y + 1))
            }
        }
        return points
    }

    /// Outer boundary traced with Moore-neighbour tracing, as pixel-centre points.
    func outerContour() -> [CGPoint] {
        guard let start = pixels.firstIndex(of: true) else { return [] }
        let sx = start % width, sy = start / width
        func filled(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && self[x, y]
        }
        // Clockwise neighbour offsets starting from west.
        let dirs = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        var contour: [CGPoint] = [CGPoint(x: Double(sx) + 0.5, y: Double(sy) + 0.5)]
        var cx = sx, cy = sy
        var backtrack = 0 // we entered the start pixel from the west (it is the first in its row)
        let limit = 4 * (width + height) * 4
        for _ in 0..<limit {
            var found = false
            for i in 1...8 {
                let d = (backtrack + i) % 8
                let nx = cx + dirs[d].0, ny = cy + dirs[d].1
                if filled(nx, ny) {
                    cx = nx; cy = ny
                    backtrack = (d + 4) % 8
                    found = true
                    break
                }
            }
            if !found || (cx == sx && cy == sy) { break }
            contour.append(CGPoint(x: Double(cx) + 0.5, y: Double(cy) + 0.5))
        }
        return contour
    }
}

enum Geometry {
    /// Andrew's monotone chain convex hull (counter-clockwise in a y-up frame).
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Side lengths (long, short) of the minimum-area rectangle around a convex polygon.
    static func minAreaRectSides(_ hull: [CGPoint]) -> (long: CGFloat, short: CGFloat) {
        guard hull.count > 2 else { return (0, 0) }
        var best: (area: CGFloat, w: CGFloat, h: CGFloat) = (.infinity, 0, 0)
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            var minU = CGFloat.infinity, maxU = -CGFloat.infinity
            var minV = CGFloat.infinity, maxV = -CGFloat.infinity
            for p in hull {
                let u = (p.x - a.x) * ux + (p.y - a.y) * uy
                let v = -(p.x - a.x) * uy + (p.y - a.y) * ux
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, v); maxV = max(maxV, v)
            }
            let w = maxU - minU, h = maxV - minV
            if w * h < best.area { best = (w * h, w, h) }
        }
        return (max(best.w, best.h), min(best.w, best.h))
    }

    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Chaikin corner cutting: smooths the stair-steps of a pixel contour.
    static func smooth(_ polygon: [CGPoint], iterations: Int = 2) -> [CGPoint] {
        var result = polygon
        for _ in 0..<iterations where result.count > 2 {
            var next: [CGPoint] = []
            next.reserveCapacity(result.count * 2)
            for i in 0..<result.count {
                let a = result[i], b = result[(i + 1) % result.count]
                next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            result = next
        }
        return result
    }

    /// Douglas–Peucker simplification of a closed polygon.
    static func simplify(_ polygon: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard polygon.count > 3 else { return polygon }
        func rdp(_ pts: ArraySlice<CGPoint>) -> [CGPoint] {
            guard let first = pts.first, let last = pts.last, pts.count > 2 else { return Array(pts) }
            let dx = last.x - first.x, dy = last.y - first.y
            let len = max(hypot(dx, dy), 1e-6)
            var maxDist: CGFloat = 0, index = pts.startIndex
            for i in pts.indices.dropFirst().dropLast() {
                let p = pts[i]
                let d = abs(dy * p.x - dx * p.y + last.x * first.y - last.y * first.x) / len
                if d > maxDist { maxDist = d; index = i }
            }
            if maxDist <= tolerance { return [first, last] }
            let left = rdp(pts[pts.startIndex...index])
            let right = rdp(pts[index...])
            return left.dropLast() + right
        }
        // Split at the farthest point from the first one so the closed curve is handled.
        let start = polygon[0]
        let far = polygon.indices.max { hypot(polygon[$0].x - start.x, polygon[$0].y - start.y) <
                                         hypot(polygon[$1].x - start.x, polygon[$1].y - start.y) } ?? 0
        let a = rdp(polygon[0...far])
        let b = rdp((polygon[far...] + [start])[...])
        return Array((a.dropLast() + b).dropLast())
    }

    /// Rotation (degrees, 0..<90) that makes a classic piece's body square
    /// axis-aligned: the straight parts of the sides dominate the outline
    /// directions, tabs/blanks are curved and spread over many directions.
    static func uprightAngle(of contour: [CGPoint]) -> Double {
        let poly = simplify(contour, tolerance: max(1, perimeter(contour) / 300))
        var histogram = [Double](repeating: 0, count: 90)
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let length = Double(hypot(b.x - a.x, b.y - a.y))
            var angle = atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi
            angle = angle.truncatingRemainder(dividingBy: 90)
            if angle < 0 { angle += 90 }
            for k in -4...4 {
                let bin = (Int(angle.rounded()) + k + 90) % 90
                histogram[bin] += length * length * exp(-Double(k * k) / 8)
            }
        }
        let peak = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        // Rotating by -peak makes the dominant edges horizontal/vertical.
        return Double((90 - peak) % 90)
    }

    static func perimeter(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count > 1 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += hypot(b.x - a.x, b.y - a.y)
        }
        return sum
    }

    static func centroid(_ polygon: [CGPoint]) -> CGPoint {
        guard !polygon.isEmpty else { return .zero }
        let sum = polygon.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(polygon.count), y: sum.y / CGFloat(polygon.count))
    }
}
