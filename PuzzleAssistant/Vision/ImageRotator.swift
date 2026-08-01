import CoreImage

struct ImageRotator {
    private static let context = CIContext()

    static func rotate(_ cgImage: CGImage, degrees: Double) -> CGImage? {
        guard degrees != 0 else { return cgImage }
        let ciImage = CIImage(cgImage: cgImage)
        let radians = degrees * .pi / 180
        let rotated = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
        return context.createCGImage(rotated, from: rotated.extent)
    }
}
