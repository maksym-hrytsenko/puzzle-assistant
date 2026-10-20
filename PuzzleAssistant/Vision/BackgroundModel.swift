import Foundation

/// Where the table (paper, cardboard, cloth) is visible between pieces.
///
/// Background = the most common colours among smooth pixels AND smooth itself.
/// Either test alone fails: light pieces have the colour of white paper, and
/// dark pieces are smooth.
struct BackgroundModel {
    let width: Int
    let height: Int
    let isBackground: [Bool]
    let assembled: [Bool]

    init(image: RGBAImage) {
        width = image.width
        height = image.height
        let n = width * height

        var gray = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let (r, g, b) = image.rgb(i % width, i / width)
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        let mean = BackgroundModel.boxMean(gray, width, height, radius: 2)
        let meanSq = BackgroundModel.boxMean(gray.map { $0 * $0 }, width, height, radius: 2)
        var smooth = [Bool](repeating: false, count: n)
        for i in 0..<n {
            smooth[i] = sqrtf(max(meanSq[i] - mean[i] * mean[i], 0)) < 6
        }

        // Dominant colours of smooth pixels (4 bits per channel).
        @inline(__always) func bin(_ i: Int) -> Int {
            let p = i * 4
            return (Int(image.data[p]) >> 4) << 8 | (Int(image.data[p + 1]) >> 4) << 4 | (Int(image.data[p + 2]) >> 4)
        }
        var histogram = [Int](repeating: 0, count: 4096)
        var smoothCount = 0
        for i in 0..<n where smooth[i] {
            histogram[bin(i)] += 1
            smoothCount += 1
        }
        var backgroundBins = [Bool](repeating: false, count: 4096)
        let threshold = max(1, smoothCount / 40) // >= 2.5 % of smooth pixels
        for b in 0..<4096 where histogram[b] >= threshold {
            // Neighbouring bins too: shading of the same table colour.
            let r = b >> 8, g = (b >> 4) & 15, bl = b & 15
            for dr in -1...1 { for dg in -1...1 { for db in -1...1 {
                let nr = r + dr, ng = g + dg, nb = bl + db
                if (0..<16).contains(nr), (0..<16).contains(ng), (0..<16).contains(nb) {
                    backgroundBins[nr << 8 | ng << 4 | nb] = true
                }
            }}}
        }
        var background = [Bool](repeating: false, count: n)
        for i in 0..<n {
            background[i] = smooth[i] && backgroundBins[bin(i)]
        }
        isBackground = background
        assembled = [Bool](repeating: false, count: n)
    }

    private init(width: Int, height: Int, isBackground: [Bool], assembled: [Bool]) {
        self.width = width
        self.height = height
        self.isBackground = isBackground
        self.assembled = assembled
    }

    /// Marks the already assembled part: no table visible over a window of a
    /// few pieces (loose piles always show some table between pieces).
    func withAssembledRegion(pieceSide: Double) -> BackgroundModel {
        let radius = max(2, Int(pieceSide * 1.25))
        let fg = isBackground.map { $0 ? Float(0) : Float(1) }
        let density = BackgroundModel.boxMean(fg, width, height, radius: radius)
        var dense = density.map { $0 > 0.97 }
        // Grow by half a window so the border pieces of the assembled area are included.
        let grow = BackgroundModel.boxMean(dense.map { $0 ? Float(1) : 0 }, width, height, radius: radius / 2)
        dense = grow.map { $0 > 0 }
        return BackgroundModel(width: width, height: height, isBackground: isBackground, assembled: dense)
    }

    func background(atX x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return true }
        return isBackground[y * width + x]
    }

    func assembled(atX x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return assembled[y * width + x]
    }

    /// Box filter via an integral image (edges clamped).
    static func boxMean(_ values: [Float], _ width: Int, _ height: Int, radius: Int) -> [Float] {
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += Double(values[y * width + x])
                integral[(y + 1) * (width + 1) + x + 1] = integral[y * (width + 1) + x + 1] + rowSum
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let s = integral[y1 * (width + 1) + x1] - integral[y0 * (width + 1) + x1]
                    - integral[y1 * (width + 1) + x0] + integral[y0 * (width + 1) + x0]
                out[y * width + x] = Float(s / Double((y1 - y0) * (x1 - x0)))
            }
        }
        return out
    }
}
