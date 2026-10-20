import XCTest
@testable import PuzzleAssistant

final class GeometryTests: XCTestCase {
    private func square(_ x: Int, _ y: Int, _ size: Int, in width: Int, _ height: Int) -> BinaryMask {
        var pixels = [Bool](repeating: false, count: width * height)
        for yy in y..<(y + size) { for xx in x..<(x + size) { pixels[yy * width + xx] = true } }
        return BinaryMask(width: width, height: height, pixels: pixels)
    }

    func testComponentSeparatesTwoSquares() {
        var mask = square(1, 1, 4, in: 20, 10)
        let other = square(10, 2, 5, in: 20, 10)
        for i in 0..<mask.pixels.count where other.pixels[i] { mask.pixels[i] = true }
        XCTAssertEqual(mask.component(containing: 2, 2)?.area, 16)
        XCTAssertEqual(mask.component(containing: 12, 4)?.area, 25)
        XCTAssertNil(mask.component(containing: 0, 0))
    }

    func testSquareIsConvexAndNotElongated() {
        let mask = square(2, 2, 10, in: 16, 16)
        let hull = Geometry.convexHull(mask.rowExtremes)
        XCTAssertEqual(Double(Geometry.polygonArea(hull)), 100, accuracy: 0.5)
        let sides = Geometry.minAreaRectSides(hull)
        XCTAssertEqual(Double(sides.long), 10, accuracy: 0.01)
        XCTAssertEqual(Double(sides.short), 10, accuracy: 0.01)
    }

    func testContourTracesTheBoundary() {
        let mask = square(3, 3, 5, in: 12, 12)
        let contour = mask.outerContour()
        XCTAssertEqual(contour.count, 16) // perimeter pixels of a 5×5 square
        XCTAssertTrue(Geometry.contains(contour, CGPoint(x: 5.5, y: 5.5)))
        XCTAssertFalse(Geometry.contains(contour, CGPoint(x: 0.5, y: 0.5)))
    }

    func testUprightAngleOfRotatedSquare() {
        // Square rotated by 30° -> straightening needs 60° (≡ -30° mod 90).
        let a = 30.0 * .pi / 180
        let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map {
            CGPoint(x: 50 + 40 * ($0.0 * cos(a) - $0.1 * sin(a)), y: 50 + 40 * ($0.0 * sin(a) + $0.1 * cos(a)))
        }
        XCTAssertEqual(Geometry.uprightAngle(of: corners), 60, accuracy: 2)
    }
}

final class GridAndProbabilityTests: XCTestCase {
    func testGridMatchesPieceCountAndAspect() {
        let grid = PuzzleGrid(pieceCount: 4000, width: 7700, height: 5093)
        XCTAssertEqual(grid.columns, 78)
        XCTAssertEqual(grid.rows, 51)
        XCTAssertEqual(grid.cell(at: CGPoint(x: 0, y: 0)).row, 1)
        XCTAssertEqual(grid.cell(at: CGPoint(x: 0.999, y: 0.999)).column, 78)
    }

    func testProbabilitiesFavourTheClearWinner() {
        let p = ReferenceMatcher.probabilities([0.78, 0.5, 0.45])
        XCTAssertGreaterThan(p[0], 0.9)
        XCTAssertLessThan(p[0] + p[1] + p[2], 1.0001)
        // All weak scores: none of the places is likely.
        let weak = ReferenceMatcher.probabilities([0.45, 0.44])
        XCTAssertLessThan(weak[0], 0.05)
    }

    func testLabMatchesReferenceValues() {
        let white = LabColor.fromRGB(255, 255, 255)
        XCTAssertEqual(white.0, 255, accuracy: 0.5)
        XCTAssertEqual(white.1, 128, accuracy: 0.5)
        let red = LabColor.fromRGB(255, 0, 0)
        XCTAssertEqual(red.0, 136, accuracy: 1)   // OpenCV: (136, 208, 195)
        XCTAssertEqual(red.1, 208, accuracy: 1)
        XCTAssertEqual(red.2, 195, accuracy: 1)
    }
}
