import CoreGraphics
import Foundation

/// The picture split into one cell per piece.
struct PuzzleGrid: Equatable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }

    /// Columns × rows closest to `pieceCount` with the picture's aspect ratio.
    init(pieceCount: Int, width: Int, height: Int) {
        let aspect = Double(max(width, 1)) / Double(max(height, 1))
        let columns = max(1, Int((Double(max(pieceCount, 1)) * aspect).squareRoot().rounded()))
        let rows = max(1, Int((Double(max(pieceCount, 1)) / Double(columns)).rounded()))
        self.init(columns: columns, rows: rows)
    }

    var cellCount: Int { columns * rows }

    /// 1-based (row, column) of a normalized point.
    func cell(at point: CGPoint) -> (row: Int, column: Int) {
        (min(rows, max(1, Int(point.y * CGFloat(rows)) + 1)), min(columns, max(1, Int(point.x * CGFloat(columns)) + 1)))
    }
}
