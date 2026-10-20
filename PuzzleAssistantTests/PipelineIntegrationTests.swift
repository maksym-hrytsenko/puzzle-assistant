import XCTest
@testable import PuzzleAssistant

/// End-to-end check on the real test photos in img/ (skipped when they are absent).
/// Runs on the simulator CPU, so it is slow (minutes); debug images go to
/// $PIPELINE_DEBUG_DIR when that variable is set.
final class PipelineIntegrationTests: XCTestCase {
    private let imageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("img")

    private func load(_ name: String) throws -> CGImage {
        let url = imageDir.appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: url.path)?.uprightCGImage() else {
            throw XCTSkip("\(name) not found")
        }
        return image
    }

    func testDetectAndLocateOnRealPhotos() throws {
        // The iOS Simulator's Core ML returns all-zero masks from the SAM 2.1 decoder
        // (macOS and devices are fine). The same code is checked natively on macOS by
        // tools/ios_pipeline_check/run.sh.
        #if targetEnvironment(simulator)
        let inSimulator = true
        #else
        let inSimulator = false
        #endif
        try XCTSkipIf(inSimulator, "SAM mask decoder does not run correctly in the iOS Simulator")
        let reference = try load("IMG_8774.JPG")
        let photo = try load("IMG_8775.JPG")
        let sam = try SAMSegmenter.shared.get()

        // Reference: rectify, turn landscape (the poster was photographed sideways).
        let prepared = try XCTUnwrap(ReferencePreparer.prepare(UIImage(cgImage: reference)))
        let rectified = try XCTUnwrap(prepared.rectified, "poster edges not found")
        let picture = try XCTUnwrap(ReferencePreparer.rotatedLeft(rectified))
        XCTAssertGreaterThan(picture.width, picture.height)
        let grid = PuzzleGrid(pieceCount: 4000, width: picture.width, height: picture.height)

        // One piece from a tap: the orange cat piece.
        let detector = PieceDetector(sam: sam)
        let start = Date()
        // Whole-photo detection.
        let result = try detector.detect(in: photo) { _, _ in }
        print("PIPELINE detection: \(result.pieces.count) pieces in \(Date().timeIntervalSince(start)) s")
        XCTAssertGreaterThan(result.pieces.count, 100)
        let cat = try XCTUnwrap(detector.segmentPiece(at: CGPoint(x: 3766.0 / 6048, y: 3025.0 / 8064), in: photo,
                                                      typicalArea: result.typicalArea))

        // Location of the cat piece (macOS check: row 27, column 58 of a 77×52 grid).
        let matcher = try ReferenceMatcher(reference: picture, columns: grid.columns, rows: grid.rows)
        let matchStart = Date()
        let places = try matcher.locate(contour: cat.contour, area: cat.area, in: photo,
                                        photoStats: result.colorStats, scaleHint: nil)
        print("PIPELINE match: \(Date().timeIntervalSince(matchStart)) s")
        for p in places {
            print("PIPELINE place row \(p.row) col \(p.column) prob \(p.probability) score \(p.score) scale \(p.scaleMultiplier)")
        }
        let best = try XCTUnwrap(places.first)
        XCTAssertEqual(best.row, 27, accuracy: 2)
        XCTAssertEqual(best.column, 58, accuracy: 2)
        XCTAssertGreaterThan(best.probability, 0.6)

        if let dir = ProcessInfo.processInfo.environment["PIPELINE_DEBUG_DIR"] {
            saveDebug(photo: photo, pieces: result.pieces, to: URL(fileURLWithPath: dir).appendingPathComponent("ios_detection.jpg"))
        }
    }

    private func saveDebug(photo: CGImage, pieces: [DetectedOutline], to url: URL) {
        let size = CGSize(width: photo.width / 2, height: photo.height / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: photo).draw(in: CGRect(origin: .zero, size: size))
            context.cgContext.setLineWidth(3)
            for (i, piece) in pieces.enumerated() {
                let hue = CGFloat(i % 6) / 6
                context.cgContext.setStrokeColor(UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor)
                context.cgContext.addLines(between: piece.contour.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                context.cgContext.closePath()
                context.cgContext.strokePath()
            }
        }
        try? image.jpegData(compressionQuality: 0.85)?.write(to: url)
    }
}
