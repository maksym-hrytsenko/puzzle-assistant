import SwiftData
import UIKit

@MainActor
enum CaptureFactory {
    /// Saves a photo of loose pieces (upright) and creates its capture record.
    static func makeCapture(from image: UIImage, puzzle: Puzzle, zone: PuzzleZone?,
                            context: ModelContext) throws -> PieceCapture {
        guard let upright = image.uprightCGImage() else { throw ImageStoreError.encodingFailed }
        let name = "pieces_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let path = try ImageStore.shared.save(UIImage(cgImage: upright), named: name, in: puzzle.id, quality: 0.9)
        let capture = PieceCapture(photoPath: path, zoneID: zone?.id)
        capture.thumbnailPath = try? ImageStore.shared.save(
            ImageStore.shared.makeThumbnail(of: UIImage(cgImage: upright), maxDimension: 200),
            named: "thumb_" + name, in: puzzle.id)
        context.insert(capture)
        capture.puzzle = puzzle
        return capture
    }
}

extension Puzzle {
    var referenceInfo: ReferenceInfo {
        ReferenceInfo(puzzleID: id, imagePath: referenceImagePath, columns: gridColumns, rows: gridRows)
    }
}
