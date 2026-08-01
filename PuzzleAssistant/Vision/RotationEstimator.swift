import CoreGraphics

/// Estimates a piece's dominant orientation from its silhouette via PCA on the
/// contour points. This is a coarse approximation: near-symmetric piece shapes
/// (e.g. close to square) don't have a well-defined dominant axis, so the estimate
/// is unreliable for them — matching compensates by also trying fixed rotation
/// steps rather than trusting this angle alone.
struct RotationEstimator {
    static func estimateRotationDegrees(of path: CGPath) -> Double {
        var points: [CGPoint] = []
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[2])
            default:
                break
            }
        }
        guard points.count >= 3 else { return 0 }

        let n = CGFloat(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n

        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - meanX
            let dy = p.y - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n

        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return Double(angle * 180 / .pi)
    }
}
