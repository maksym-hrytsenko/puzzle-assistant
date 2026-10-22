import SwiftData
import UIKit
import XCTest
@testable import PuzzleAssistant

@MainActor
final class PuzzleArchiveTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Puzzle.self, PuzzleZone.self, PieceCapture.self, DetectedPiece.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    func testShareAndMerge() throws {
        let id = UUID()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { _ in UIColor.red.setFill(); UIRectFill(.infinite) }
        let ref = try ImageStore.shared.save(image, named: "reference.jpg", in: id)
        let thumb = try ImageStore.shared.save(image, named: "reference_thumb.jpg", in: id)
        let photo = try ImageStore.shared.save(image, named: "pieces_1.jpg", in: id)
        defer { ImageStore.shared.deleteAll(for: id) }

        // Phone A: a puzzle with a zone, a photo and two pieces.
        let containerA = try container()
        let a = containerA.mainContext
        let puzzle = Puzzle(id: id, name: "Тест", referenceImagePath: ref, referenceThumbnailPath: thumb,
                            referenceWidth: 40, referenceHeight: 30, pieceCount: 100)
        a.insert(puzzle)
        let zone = PuzzleZone(label: "Сова", rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        a.insert(zone); zone.puzzle = puzzle
        let capture = PieceCapture(photoPath: photo, zoneID: zone.id)
        a.insert(capture); capture.puzzle = puzzle
        let pieces = (0..<2).map { _ in DetectedPiece(outline: DetectedOutline(contour: [CGPoint(x: 0.1, y: 0.2)], area: 100, score: 0.9)) }
        for p in pieces { a.insert(p); p.capture = capture }

        // Phone B gets it.
        let url = try PuzzleArchive.write(PuzzleArchive.manifest(for: puzzle))
        let containerB = try container()
        let b = containerB.mainContext
        let first = try PuzzleArchive.merge(try PuzzleArchive.read(url), into: b)
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(first.newCaptures, 1)
        XCTAssertEqual(first.newZones, 1)
        let copy = try XCTUnwrap(b.fetch(FetchDescriptor<Puzzle>()).first)
        XCTAssertEqual(copy.captures.first?.pieces.count, 2)
        let point = try XCTUnwrap(copy.captures.first?.pieces.first?.contour.first)
        XCTAssertEqual(point.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0.2, accuracy: 1e-6)

        // A places a piece and shares again: B merges, nothing is duplicated.
        pieces[0].isPlaced = true
        let second = try PuzzleArchive.merge(try PuzzleArchive.read(try PuzzleArchive.write(PuzzleArchive.manifest(for: puzzle))), into: b)
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.newCaptures, 0)
        XCTAssertEqual(second.newlyPlaced, 1)
        XCTAssertEqual(try b.fetch(FetchDescriptor<DetectedPiece>()).count, 2)
        XCTAssertEqual(copy.placedCount, 1)
    }
}
