// Runs the app's on-device recognition code (PuzzleAssistant/Vision) natively on macOS,
// where Core ML behaves as on an iPhone (the iOS Simulator returns empty SAM masks).
// Build and run: tools/ios_pipeline_check/run.sh
import AppKit
import CoreGraphics
import Foundation

func loadImage(_ path: String) -> CGImage {
    let image = NSImage(contentsOfFile: path)!
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

func resized(_ image: CGImage, maxSide: Int) -> CGImage {
    let k = Double(maxSide) / Double(max(image.width, image.height))
    guard k < 1 else { return image }
    return RGBAImage(cgImage: image, width: Int(Double(image.width) * k), height: Int(Double(image.height) * k))!.cgImage()!
}

func saveJPEG(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])?.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
let imageDir = args[1], outDir = args[2]
let photo = loadImage("\(imageDir)/IMG_8775.JPG")
let reference = resized(loadImage("\(imageDir)/IMG_8774.JPG"), maxSide: 4096)
print("photo \(photo.width)x\(photo.height), reference \(reference.width)x\(reference.height)")

// 1. Reference: rectify + turn landscape.
let prepared = ReferencePreparer.prepare(reference)
guard let rectified = prepared.rectified, let picture = ReferencePreparer.rotatedLeft(rectified) else {
    print("FAIL: poster edges not found"); exit(1)
}
saveJPEG(resized(picture, maxSide: 1600), "\(outDir)/ios_reference.jpg")
let grid = PuzzleGrid(pieceCount: 4000, width: picture.width, height: picture.height)
print("reference rectified \(picture.width)x\(picture.height), grid \(grid.columns)x\(grid.rows)")

// 2. Detection.
let sam = try SAMSegmenter.shared.get()
let detector = PieceDetector(sam: sam)
var t = Date()
let cat = try detector.segmentPiece(at: CGPoint(x: 3766.0 / 6048, y: 3025.0 / 8064), in: photo)
print("tap segmentation \(String(format: "%.2f", Date().timeIntervalSince(t))) s, found: \(cat != nil)")
t = Date()
let result = try detector.detect(in: photo) { value, text in
    if Int(value * 100) % 20 == 0 { print("  \(Int(value * 100))% \(text)") }
}
print("detection: \(result.pieces.count) pieces in \(String(format: "%.1f", Date().timeIntervalSince(t))) s")

// Outlines on the photo.
let size = CGSize(width: photo.width / 4, height: photo.height / 4)
let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(photo, in: CGRect(origin: .zero, size: size))
ctx.setLineWidth(2.5)
for (i, piece) in result.pieces.enumerated() {
    ctx.setStrokeColor(NSColor(hue: CGFloat(i % 6) / 6, saturation: 1, brightness: 1, alpha: 1).cgColor)
    ctx.addLines(between: piece.contour.map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height) })
    ctx.closePath()
    ctx.strokePath()
}
saveJPEG(ctx.makeImage()!, "\(outDir)/ios_detection.jpg")

// 3. Location of a few pieces.
let matcher = try ReferenceMatcher(reference: picture, columns: grid.columns, rows: grid.rows)
var hint: Double?
// Expected (Python test bench, grid 78×51): fairy r13 c62, yellow-green r24 c44, green r29 c46, cat r29 c56.
let samples: [(String, CGPoint)] = [("orange fairy", CGPoint(x: 4362.0 / 6048, y: 2725.0 / 8064)),
                                    ("yellow-green", CGPoint(x: 3737.0 / 6048, y: 2662.0 / 8064)),
                                    ("green", CGPoint(x: 4000.0 / 6048, y: 2762.0 / 8064)),
                                    ("cat", CGPoint(x: 3766.0 / 6048, y: 3025.0 / 8064)),
                                    ("cat without hint", CGPoint(x: 3766.0 / 6048, y: 3025.0 / 8064))]
print("typical: detection \(Int(result.typicalArea)), median of found pieces \(Int(result.pieces.map(\.area).sorted()[result.pieces.count / 2]))")
var largest: [Int: Int] = [:]
for p in result.pieces { largest[Int(p.area / 10000), default: 0] += 1 }
print("area histogram (×10k): \(largest.sorted { $0.key < $1.key })")
for (name, point) in samples {
    let areas = result.pieces.map(\.area).sorted()
    guard let piece = try detector.segmentPiece(at: point, in: photo, typicalArea: result.typicalArea) else { print("\(name): not segmented"); continue }
    t = Date()
    let places = try matcher.locate(contour: piece.contour, area: piece.area, in: photo,
                                    photoStats: result.colorStats, scaleHint: name.hasSuffix("without hint") ? nil : hint)
    let summary = places.map { "r\($0.row) c\($0.column) \(Int($0.probability * 100))% (score \(String(format: "%.2f", $0.score)), scale \(String(format: "%.2f", $0.scaleMultiplier)))" }
    print("\(name) [area \(Int(piece.area)), score \(String(format: "%.2f", piece.score))]: \(String(format: "%.2f", Date().timeIntervalSince(t))) s -> \(summary.joined(separator: "; "))")
    if hint == nil, let best = places.first, best.probability >= 0.6 { hint = best.scaleMultiplier }
}

