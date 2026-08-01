import XCTest
@testable import PuzzleAssistant

final class RotationEstimatorTests: XCTestCase {
    func testHorizontalRectangleHasNearZeroRotation() {
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 20), transform: nil)
        let angle = RotationEstimator.estimateRotationDegrees(of: path)
        XCTAssertEqual(angle, 0, accuracy: 1.0)
    }

    func testDegeneratePathReturnsZero() {
        let path = CGMutablePath()
        path.move(to: .zero)
        let angle = RotationEstimator.estimateRotationDegrees(of: path)
        XCTAssertEqual(angle, 0)
    }
}
