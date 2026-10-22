import CoreImage
#if canImport(UIKit)
import UIKit
#endif
import Vision

/// Turns a photo of the box/poster (or a downloaded picture) into an exact rectangle.
enum ReferencePreparer {
    static let maxDimension: CGFloat = 4096

    struct Result {
        let original: CGImage
        /// Perspective-corrected picture, nil when no clear rectangle was found.
        let rectified: CGImage?
        /// Detected corners of the picture (top-left, top-right, bottom-right,
        /// bottom-left), normalized, y down; nil when none were found.
        let corners: [CGPoint]?
    }

    /// The picture turned by 90° counter-clockwise.
    static func rotatedLeft(_ image: CGImage) -> CGImage? {
        let rotated = CIImage(cgImage: image).oriented(.left)
        return CIContext().createCGImage(rotated, from: rotated.extent)
    }

    #if canImport(UIKit)
    static func prepare(_ image: UIImage) -> Result? {
        guard let upright = image.uprightCGImage(maxDimension: maxDimension) else { return nil }
        return prepare(upright)
    }
    #endif

    /// `image` must already be upright and at most `maxDimension` on its long side.
    static func prepare(_ upright: CGImage) -> Result {
        // Best: SAM outline + line fit + edge snapping (see PictureBoundary).
        if let sam = try? SAMSegmenter.shared.get(), let corners = PictureBoundary.corners(in: upright, sam: sam) {
            return Result(original: upright, rectified: rectify(upright, corners: corners), corners: corners)
        }
        // Fallback: the whole picture is the largest rectangle; Vision alone
        // sometimes returns only a part of it (e.g. above a fold of a poster).
        let candidates = [visionQuad(upright), colorQuad(upright)].compactMap { $0 }
        guard let quad = candidates.max(by: { Geometry.polygonArea($0) < Geometry.polygonArea($1) }) else {
            return Result(original: upright, rectified: nil, corners: nil)
        }
        return Result(original: upright, rectified: correct(upright, quad: quad),
                      corners: quad.map { CGPoint(x: $0.x, y: 1 - $0.y) })
    }

    /// Perspective correction with corners set by the user (normalized, y down,
    /// top-left, top-right, bottom-right, bottom-left).
    static func rectify(_ image: CGImage, corners: [CGPoint]) -> CGImage? {
        guard corners.count == 4 else { return nil }
        return correct(image, quad: corners.map { CGPoint(x: $0.x, y: 1 - $0.y) })
    }

    /// Corners (top-left, top-right, bottom-right, bottom-left), normalized, y up (Core Image).
    private typealias Quad = [CGPoint]

    private static func visionQuad(_ image: CGImage) -> Quad? {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.5
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1
        request.minimumSize = 0.3
        request.quadratureTolerance = 25
        request.maximumObservations = 1
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let rect = request.results?.first else { return nil }
        // A rectangle covering almost the whole frame is the photo itself, not a picture in it.
        let quad = [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
        let area = Geometry.polygonArea(quad)
        guard area > 0.2, area < 0.97 else { return nil }
        return quad
    }

    /// Fallback for pictures on a busy floor/table (validated in the Python test bench):
    /// the photo border shows the table; the picture is the largest region whose
    /// colours differ from all border colours; its corners are the hull extremes.
    private static func colorQuad(_ image: CGImage) -> Quad? {
        let scale = 800 / CGFloat(max(image.width, image.height))
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard let small = RGBAImage(cgImage: image, width: width, height: height) else { return nil }
        var lab = [SIMD3<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = small.rgb(x, y)
                let c = LabColor.fromRGB(r, g, b)
                lab[y * width + x] = SIMD3(c.0, c.1, c.2)
            }
        }
        // Border colours, clustered with k-means.
        let band = 12
        var border: [SIMD3<Float>] = []
        for y in 0..<height {
            for x in 0..<width where x < band || y < band || x >= width - band || y >= height - band {
                border.append(lab[y * width + x])
            }
        }
        let centers = kMeans(border, k: 4)
        func distance(_ v: SIMD3<Float>) -> Float {
            centers.map { c -> Float in let d = v - c; return (d * d).sum().squareRoot() }.min() ?? 0
        }
        let borderDistances = border.map(distance).sorted()
        let threshold = max(borderDistances[Int(Double(borderDistances.count) * 0.9)] * 1.5, 12)
        var mask = BinaryMask(width: width, height: height, pixels: lab.map { distance($0) > threshold })
        // Close small gaps (dark details of the picture that match the floor).
        mask = dilate(mask, 3)
        guard let component = largestComponent(mask) else { return nil }
        let hull = Geometry.convexHull(component.rowExtremes)
        let area = Geometry.polygonArea(hull) / CGFloat(width * height)
        guard area > 0.2, area < 0.98 else { return nil }
        // Corners in image coordinates (y down), then normalized with y up for Core Image.
        let tl = hull.min { $0.x + $0.y < $1.x + $1.y }!, br = hull.max { $0.x + $0.y < $1.x + $1.y }!
        let tr = hull.max { $0.x - $0.y < $1.x - $1.y }!, bl = hull.min { $0.x - $0.y < $1.x - $1.y }!
        return [tl, tr, br, bl].map { CGPoint(x: $0.x / CGFloat(width), y: 1 - $0.y / CGFloat(height)) }
    }

    private static func kMeans(_ values: [SIMD3<Float>], k: Int) -> [SIMD3<Float>] {
        guard values.count >= k else { return values }
        var centers = (0..<k).map { values[$0 * values.count / k] }
        for _ in 0..<12 {
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            var counts = [Float](repeating: 0, count: k)
            for v in values {
                var best = 0
                var bestDistance = Float.infinity
                for (i, c) in centers.enumerated() {
                    let d = ((v - c) * (v - c)).sum()
                    if d < bestDistance { bestDistance = d; best = i }
                }
                sums[best] += v
                counts[best] += 1
            }
            for i in 0..<k where counts[i] > 0 { centers[i] = sums[i] / counts[i] }
        }
        return centers
    }

    private static func dilate(_ mask: BinaryMask, _ radius: Int) -> BinaryMask {
        var out = mask.pixels
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask[x, y] {
                for yy in max(0, y - radius)...min(mask.height - 1, y + radius) {
                    for xx in max(0, x - radius)...min(mask.width - 1, x + radius) {
                        out[yy * mask.width + xx] = true
                    }
                }
            }
        }
        return BinaryMask(width: mask.width, height: mask.height, pixels: out)
    }

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

    private static func correct(_ image: CGImage, quad: Quad) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(point(quad[0]), forKey: "inputTopLeft")
        filter.setValue(point(quad[1]), forKey: "inputTopRight")
        filter.setValue(point(quad[2]), forKey: "inputBottomRight")
        filter.setValue(point(quad[3]), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
