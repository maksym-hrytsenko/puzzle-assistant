import Accelerate
import CoreGraphics
import Foundation
import Metal

/// One possible place of a piece on the full picture.
struct PlacementCandidate: Codable, Identifiable, Sendable {
    var id = UUID()
    /// Piece centre on the reference, normalized (0...1, y down).
    var x: Double
    var y: Double
    /// Piece outline transformed onto the reference, normalized.
    var outline: [CGPoint]
    var rotationDegrees: Double
    /// Multiplier on the grid-derived scale (reused as a hint for the same photo).
    var scaleMultiplier: Double
    /// Size of one photo pixel in grid cells (to draw the piece's photo at its place).
    var cellsPerPhotoPixel: Double?
    var score: Double
    var probability: Double
    var row: Int
    var column: Int
}

enum MatchError: LocalizedError {
    case metalUnavailable
    case referenceUnavailable
    case pieceTooSmall

    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return String(localized: "Цей пристрій не підтримує Metal.")
        case .referenceUnavailable: return String(localized: "Не вдалося підготувати зображення пазла.")
        case .pieceTooSmall: return String(localized: "Шматок замалий для порівняння.")
        }
    }
}

/// Finds where a piece belongs on the reference picture.
///
/// - Scale comes from the grid: a piece's body is about one grid cell, and
///   √(piece area) ≈ cell side.
/// - Pieces sit upright in the finished puzzle, so only 4 rotations of the
///   piece's straightened outline are tried (± 3° in the refinement).
/// - Coarse search over the whole picture (cell = 16 px), then a fine search
///   (cell = 40 px) around the 10 best coarse places, all on the GPU.
/// - Probability: softmax over distinct places plus an implicit "somewhere
///   else" option (uncalibrated heuristic — see docs/adr/0004).
final class ReferenceMatcher {
    static let coarseCell: Double = 16
    static let fineCell: Double = 40
    static let colorWeight: Float = 0.012
    static let minimumProbability = 0.05
    private static let softmaxTemperature = 0.025
    private static let backgroundScore = 0.58

    fileprivate struct Level {
        let texture: MTLTexture
        let cell: Double
        var width: Int { texture.width }
        var height: Int { texture.height }
    }

    private struct Params {
        var pixelCount: UInt32
        var originX: UInt32
        var originY: UInt32
        var outWidth: UInt32
        var outHeight: UInt32
        var sumT2: Float
        var meanL: Float
        var meanA: Float
        var meanB: Float
        var colorWeight: Float
    }

    private struct Template {
        let values: [SIMD4<Float>]
        let offsets: [SIMD2<UInt16>]
        let width: Int
        let height: Int
        let center: CGPoint      // piece centre inside the template
        let sumT2: Float
        let mean: SIMD3<Float>
    }

    private struct Pose {
        var angle: Double
        var scale: Double        // multiplier on the grid-derived scale
    }

    let columns: Int
    let rows: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let matchPipeline: MTLComputePipelineState
    private let coarse: Level
    private let fine: Level
    private let referenceStats: ColorStats

    init(reference: CGImage, columns: Int, rows: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = ReferenceMatcher.library(device),
              let labFunction = library.makeFunction(name: "rgbToLab"),
              let matchFunction = library.makeFunction(name: "maskedMatch") else {
            throw MatchError.metalUnavailable
        }
        self.device = device
        self.queue = queue
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        matchPipeline = try device.makeComputePipelineState(function: matchFunction)
        let labPipeline = try device.makeComputePipelineState(function: labFunction)

        func level(cell: Double) throws -> Level {
            let width = Int((Double(columns) * cell).rounded())
            let height = Int((Double(width) * Double(reference.height) / Double(reference.width)).rounded())
            guard width <= 8192, height <= 8192,
                  let rgba = RGBAImage(cgImage: reference, width: width, height: height) else {
                throw MatchError.referenceUnavailable
            }
            let rgbDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            rgbDescriptor.usage = .shaderRead
            let labDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            labDescriptor.usage = [.shaderRead, .shaderWrite]
            labDescriptor.storageMode = .private
            guard let rgb = device.makeTexture(descriptor: rgbDescriptor),
                  let lab = device.makeTexture(descriptor: labDescriptor),
                  let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeComputeCommandEncoder() else {
                throw MatchError.referenceUnavailable
            }
            rgba.data.withUnsafeBytes { raw in
                rgb.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: width * 4)
            }
            encoder.setComputePipelineState(labPipeline)
            encoder.setTexture(rgb, index: 0)
            encoder.setTexture(lab, index: 1)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            return Level(texture: lab, cell: cell)
        }
        coarse = try level(cell: ReferenceMatcher.coarseCell)
        fine = try level(cell: ReferenceMatcher.fineCell)

        // Colour statistics of the picture, for colour transfer from piece photos.
        guard let small = RGBAImage(cgImage: reference, width: 256,
                                    height: max(1, 256 * reference.height / reference.width)) else {
            throw MatchError.referenceUnavailable
        }
        var sum = SIMD3<Double>(repeating: 0), sumSq = SIMD3<Double>(repeating: 0)
        let count = Double(small.width * small.height)
        for y in 0..<small.height {
            for x in 0..<small.width {
                let (r, g, b) = small.rgb(x, y)
                let lab = LabColor.fromRGB(r, g, b)
                let v = SIMD3<Double>(Double(lab.0), Double(lab.1), Double(lab.2))
                sum += v
                sumSq += v * v
            }
        }
        let mean = sum / count
        let variance = sumSq / count - mean * mean
        referenceStats = ColorStats(mean: [Float(mean.x), Float(mean.y), Float(mean.z)],
                                    std: [Float(max(variance.x, 1).squareRoot()), Float(max(variance.y, 1).squareRoot()),
                                          Float(max(variance.z, 1).squareRoot())])
    }

    private static func library(_ device: MTLDevice) -> MTLLibrary? {
        if let library = device.makeDefaultLibrary() { return library }
        #if os(macOS)
        // Command-line test harness: compiled shaders in $MATCHING_METALLIB.
        if let path = ProcessInfo.processInfo.environment["MATCHING_METALLIB"] {
            return try? device.makeLibrary(URL: URL(fileURLWithPath: path))
        }
        #endif
        return nil
    }

    /// Distinct likely places, most likely first; only those ≥ `minimumProbability`
    /// (at least the best one is always returned).
    func locate(contour normalizedContour: [CGPoint], area: Double, in photo: CGImage,
                photoStats: ColorStats?, scaleHint: Double?) throws -> [PlacementCandidate] {
        let photoSize = CGSize(width: photo.width, height: photo.height)
        let contour = normalizedContour.map { CGPoint(x: $0.x * photoSize.width, y: $0.y * photoSize.height) }
        let pieceSide = area.squareRoot()
        guard pieceSide > 8, contour.count > 4 else { throw MatchError.pieceTooSmall }

        let xs = contour.map(\.x), ys = contour.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -8, dy: -8)
        let center = CGPoint(x: box.midX, y: box.midY)
        // One area-averaged crop per level, 2× oversampled relative to the template.
        func crop(forCell cell: Double) throws -> (PieceCrop, CGPoint, Double) {
            let scale = min(1, cell * 1.3 * 2 / pieceSide)
            guard let image = RGBAImage(cgImage: photo, crop: box, scale: scale) else { throw MatchError.pieceTooSmall }
            let sx = CGFloat(image.width) / box.width, sy = CGFloat(image.height) / box.height
            let local = contour.map { CGPoint(x: ($0.x - box.minX) * sx, y: ($0.y - box.minY) * sy) }
            let piece = PieceCrop(lab: labPixels(of: image, photoStats: photoStats),
                                  mask: rasterize(local, width: image.width, height: image.height),
                                  width: image.width, height: image.height)
            return (piece, CGPoint(x: (center.x - box.minX) * sx, y: (center.y - box.minY) * sy), pieceSide * Double(sx))
        }
        let (coarseCrop, coarseCenter, coarseSide) = try crop(forCell: coarse.cell)
        let (fineCrop, fineCenter, fineSide) = try crop(forCell: fine.cell)

        let upright = Geometry.uprightAngle(of: contour)
        let angles = (0..<4).map { upright + Double($0) * 90 }
        let scales = scaleHint.map { [$0 * 0.92, $0, $0 * 1.08] } ?? [0.75, 0.87, 1.0, 1.15, 1.3]

        // Coarse: whole picture, every pose.
        var coarseHits: [(score: Float, pose: Pose, x: Double, y: Double)] = []
        for scale in scales {
            let poses = angles.map { Pose(angle: $0, scale: scale) }
            let templates = poses.map { makeTemplate(coarseCrop, center: coarseCenter,
                                                      factor: coarse.cell * $0.scale / coarseSide, angle: $0.angle) }
            let jobs: [(Template, MatchRegion)?] = templates.map { template in
                guard let template, let region = fullRegion(for: template, in: coarse) else { return nil }
                return (template, region)
            }
            let maps = try run(jobs, on: coarse)
            for (index, map) in maps.enumerated() {
                guard let map, let template = templates[index] else { continue }
                for peak in peaks(of: map, count: 3, radius: max(template.width, template.height)) {
                    coarseHits.append((peak.score, poses[index],
                                       Double(peak.x) + Double(template.center.x), Double(peak.y) + Double(template.center.y)))
                }
            }
        }
        coarseHits.sort { $0.score > $1.score }

        // Fine: small windows around the best coarse places, ±3° and ±6 % scale.
        let ratio = fine.cell / coarse.cell
        let radius = Int(ratio * 1.5) + 2
        var jobs: [(Template, MatchRegion)?] = []
        var jobPoses: [(hit: Int, pose: Pose)] = []
        for (hitIndex, hit) in coarseHits.prefix(10).enumerated() {
            for da in [-3.0, 0, 3] {
                for ds in [0.94, 1.0, 1.06] {
                    let pose = Pose(angle: hit.pose.angle + da, scale: hit.pose.scale * ds)
                    let template = makeTemplate(fineCrop, center: fineCenter,
                                                factor: fine.cell * pose.scale / fineSide, angle: pose.angle)
                    let region = template.flatMap { t -> MatchRegion? in
                        let x0 = Int((hit.x * ratio - Double(t.center.x)).rounded()) - radius
                        let y0 = Int((hit.y * ratio - Double(t.center.y)).rounded()) - radius
                        return MatchRegion(x: x0, y: y0, width: 2 * radius + 1, height: 2 * radius + 1)
                            .clamped(templateWidth: t.width, templateHeight: t.height, level: fine)
                    }
                    jobs.append(template.flatMap { t in region.map { (t, $0) } })
                    jobPoses.append((hitIndex, pose))
                }
            }
        }
        let fineMaps = try run(jobs, on: fine)
        var bestPerHit: [Int: (score: Float, pose: Pose, x: Double, y: Double)] = [:]
        for (index, map) in fineMaps.enumerated() {
            guard let map, let job = jobs[index], let peak = peaks(of: map, count: 1, radius: 0).first else { continue }
            let x = Double(job.1.x + peak.x) + Double(job.0.center.x)
            let y = Double(job.1.y + peak.y) + Double(job.0.center.y)
            let hit = jobPoses[index].hit
            if bestPerHit[hit] == nil || bestPerHit[hit]!.score < peak.score {
                bestPerHit[hit] = (peak.score, jobPoses[index].pose, x, y)
            }
        }
        let refined = bestPerHit.values.sorted { $0.score > $1.score }

        // Distinct places only.
        var distinct: [(score: Float, pose: Pose, x: Double, y: Double)] = []
        for r in refined where distinct.allSatisfy({ hypot($0.x - r.x, $0.y - r.y) > fine.cell }) {
            distinct.append(r)
            if distinct.count == 4 { break }
        }
        let probabilities = ReferenceMatcher.probabilities(distinct.map { Double($0.score) })

        let fineSize = CGSize(width: fine.width, height: fine.height)
        var result: [PlacementCandidate] = []
        for (place, probability) in zip(distinct, probabilities) {
            let factor = fine.cell * place.pose.scale / pieceSide
            let outline = contour.map { p -> CGPoint in
                let q = ReferenceMatcher.transform(p, center: center, factor: factor, angle: place.pose.angle,
                                                   to: CGPoint(x: place.x, y: place.y))
                return CGPoint(x: q.x / fineSize.width, y: q.y / fineSize.height)
            }
            let nx = place.x / Double(fineSize.width), ny = place.y / Double(fineSize.height)
            result.append(PlacementCandidate(x: nx, y: ny, outline: Geometry.simplify(outline, tolerance: 0.0004),
                                             rotationDegrees: place.pose.angle, scaleMultiplier: place.pose.scale,
                                             cellsPerPhotoPixel: factor / fine.cell,
                                             score: Double(place.score),
                                             probability: probability,
                                             row: min(rows, Int(ny * Double(rows)) + 1),
                                             column: min(columns, Int(nx * Double(columns)) + 1)))
        }
        let likely = result.filter { $0.probability >= ReferenceMatcher.minimumProbability }
        return likely.isEmpty ? Array(result.prefix(1)) : likely
    }

    static func probabilities(_ scores: [Double]) -> [Double] {
        let values = (scores + [backgroundScore]).map { $0 / softmaxTemperature }
        let peak = values.max() ?? 0
        let exps = values.map { exp($0 - peak) }
        let total = exps.reduce(0, +)
        return exps.dropLast().map { $0 / total }
    }

    // MARK: - Templates

    private static func transform(_ p: CGPoint, center: CGPoint, factor: Double, angle: Double, to target: CGPoint) -> CGPoint {
        let a = angle * .pi / 180
        let dx = Double(p.x - center.x) * factor, dy = Double(p.y - center.y) * factor
        return CGPoint(x: Double(target.x) + dx * cos(a) - dy * sin(a), y: Double(target.y) + dx * sin(a) + dy * cos(a))
    }

    private func rasterize(_ polygon: [CGPoint], width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // CGContext is y-up; flip so that row 0 of the buffer is the top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.addLines(between: polygon)
            context.closePath()
            context.fillPath()
        }
        return buffer
    }

    private func labPixels(of image: RGBAImage, photoStats: ColorStats?) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: .zero, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let (r, g, b) = image.rgb(x, y)
                let lab = LabColor.fromRGB(r, g, b)
                var v = SIMD3<Float>(lab.0, lab.1, lab.2)
                if let photoStats {
                    // Reinhard colour transfer into the reference's lighting.
                    for c in 0..<3 {
                        v[c] = (v[c] - photoStats.mean[c]) / max(photoStats.std[c], 1) * referenceStats.std[c] + referenceStats.mean[c]
                    }
                }
                out[y * image.width + x] = v
            }
        }
        return out
    }

    private struct PieceCrop {
        let lab: [SIMD3<Float>]
        let mask: [UInt8]
        let width: Int
        let height: Int
    }

    /// The piece rotated by `angle` and scaled by `factor` (template px per crop px).
    /// Only pixels well inside the piece are kept (the outermost ones mix with
    /// the table and the piece's shadow).
    private func makeTemplate(_ crop: PieceCrop, center: CGPoint, factor: Double, angle: Double) -> Template? {
        guard factor > 0 else { return nil }
        let a = angle * .pi / 180
        let cosA = cos(a), sinA = sin(a)
        // Template bounds = rotated crop rectangle.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: crop.width, y: 0), CGPoint(x: 0, y: crop.height),
                       CGPoint(x: crop.width, y: crop.height)]
            .map { ReferenceMatcher.transform($0, center: center, factor: factor, angle: angle, to: .zero) }
        let minX = corners.map(\.x).min()!, minY = corners.map(\.y).min()!
        let width = Int((corners.map(\.x).max()! - minX).rounded(.up)) + 1
        let height = Int((corners.map(\.y).max()! - minY).rounded(.up)) + 1
        guard width >= 4, height >= 4, width < 4096, height < 4096 else { return nil }
        let templateCenter = CGPoint(x: -minX, y: -minY)

        @inline(__always) func maskAt(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < crop.width && y < crop.height && crop.mask[y * crop.width + x] > 127
        }
        // Erode by ~1 template pixel, measured in crop pixels.
        let erosion = max(1, Int((1 / factor).rounded()))
        var samples: [(SIMD3<Float>, SIMD2<UInt16>)] = []
        for ty in 0..<height {
            for tx in 0..<width {
                // Inverse transform: template pixel centre -> crop coordinates.
                let dx = (Double(tx) + 0.5 - Double(templateCenter.x)) / factor
                let dy = (Double(ty) + 0.5 - Double(templateCenter.y)) / factor
                let cx = Double(center.x) + dx * cosA + dy * sinA
                let cy = Double(center.y) - dx * sinA + dy * cosA
                let ix = Int(cx.rounded(.down)), iy = Int(cy.rounded(.down))
                guard maskAt(ix, iy), maskAt(ix - erosion, iy), maskAt(ix + erosion, iy),
                      maskAt(ix, iy - erosion), maskAt(ix, iy + erosion) else { continue }
                samples.append((bilinear(crop, cx - 0.5, cy - 0.5), SIMD2(UInt16(tx), UInt16(ty))))
            }
        }
        guard samples.count >= 12 else { return nil }
        var mean = SIMD3<Float>(repeating: 0)
        for s in samples { mean += s.0 }
        mean /= Float(samples.count)
        var sumT2: Float = 0
        var values: [SIMD4<Float>] = []
        values.reserveCapacity(samples.count)
        for s in samples {
            let d = s.0 - mean
            sumT2 += (d * d).sum()
            values.append(SIMD4(d.x, d.y, d.z, 0))
        }
        return Template(values: values, offsets: samples.map(\.1), width: width, height: height,
                        center: templateCenter, sumT2: max(sumT2, 1e-3), mean: mean)
    }

    private func bilinear(_ crop: PieceCrop, _ x: Double, _ y: Double) -> SIMD3<Float> {
        let x0 = min(max(Int(x.rounded(.down)), 0), crop.width - 1), y0 = min(max(Int(y.rounded(.down)), 0), crop.height - 1)
        let x1 = min(x0 + 1, crop.width - 1), y1 = min(y0 + 1, crop.height - 1)
        let fx = Float(min(max(x - Double(x0), 0), 1)), fy = Float(min(max(y - Double(y0), 0), 1))
        let top = crop.lab[y0 * crop.width + x0] * (1 - fx) + crop.lab[y0 * crop.width + x1] * fx
        let bottom = crop.lab[y1 * crop.width + x0] * (1 - fx) + crop.lab[y1 * crop.width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: - GPU

    fileprivate struct MatchRegion {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        /// Keeps the template inside the level; nil if nothing is left.
        fileprivate func clamped(templateWidth: Int, templateHeight: Int, level: Level) -> MatchRegion? {
            let x0 = max(x, 0), y0 = max(y, 0)
            let x1 = min(x + width, level.width - templateWidth + 1)
            let y1 = min(y + height, level.height - templateHeight + 1)
            guard x1 > x0, y1 > y0 else { return nil }
            return MatchRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    private struct ScoreMap {
        var values: [Float]
        let width: Int
        let height: Int
    }

    private func fullRegion(for template: Template, in level: Level) -> MatchRegion? {
        MatchRegion(x: 0, y: 0, width: level.width - template.width + 1, height: level.height - template.height + 1)
            .clamped(templateWidth: template.width, templateHeight: template.height, level: level)
    }

    private func run(_ jobs: [(Template, MatchRegion)?], on level: Level) throws -> [ScoreMap?] {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MatchError.metalUnavailable }
        encoder.setComputePipelineState(matchPipeline)
        encoder.setTexture(level.texture, index: 0)
        var outputs: [MTLBuffer?] = []
        for job in jobs {
            guard let (template, region) = job,
                  let values = device.makeBuffer(bytes: template.values, length: template.values.count * MemoryLayout<SIMD4<Float>>.stride),
                  let offsets = device.makeBuffer(bytes: template.offsets, length: template.offsets.count * MemoryLayout<SIMD2<UInt16>>.stride),
                  let output = device.makeBuffer(length: region.width * region.height * 4, options: .storageModeShared) else {
                outputs.append(nil)
                continue
            }
            var params = Params(pixelCount: UInt32(template.values.count), originX: UInt32(region.x), originY: UInt32(region.y),
                                outWidth: UInt32(region.width), outHeight: UInt32(region.height), sumT2: template.sumT2,
                                meanL: template.mean.x, meanA: template.mean.y, meanB: template.mean.z,
                                colorWeight: ReferenceMatcher.colorWeight)
            encoder.setBuffer(values, offset: 0, index: 0)
            encoder.setBuffer(offsets, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            encoder.dispatchThreads(MTLSize(width: region.width, height: region.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            outputs.append(output)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return zip(outputs, jobs).map { output, job in
            guard let output, let region = job?.1 else { return nil }
            let pointer = output.contents().assumingMemoryBound(to: Float.self)
            return ScoreMap(values: Array(UnsafeBufferPointer(start: pointer, count: region.width * region.height)),
                            width: region.width, height: region.height)
        }
    }

    /// Best positions with non-maximum suppression in a (2·radius+1)² square.
    private func peaks(of map: ScoreMap, count: Int, radius: Int) -> [(score: Float, x: Int, y: Int)] {
        var values = map.values
        var result: [(score: Float, x: Int, y: Int)] = []
        for _ in 0..<count {
            var best: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(values, 1, &best, &index, vDSP_Length(values.count))
            guard best.isFinite, best > -10 else { break }
            let px = Int(index) % map.width, py = Int(index) / map.width
            result.append((best, px, py))
            for y in max(0, py - radius)...min(map.height - 1, py + radius) {
                for x in max(0, px - radius)...min(map.width - 1, px + radius) {
                    values[y * map.width + x] = -100
                }
            }
        }
        return result
    }
}
