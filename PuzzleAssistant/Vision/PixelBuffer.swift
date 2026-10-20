import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// 8-bit RGBA pixels, row-major, top row first.
struct RGBAImage {
    let width: Int
    let height: Int
    var data: [UInt8]

    init(width: Int, height: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
    }

    /// Renders a CGImage scaled to the given size (high-quality downsampling).
    init?(cgImage: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.init(width: width, height: height, data: buffer)
    }

    /// Crops `rect` (pixel units of `cgImage`) and scales it to `scale`.
    init?(cgImage: CGImage, crop rect: CGRect, scale: CGFloat) {
        let bounded = rect.integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !bounded.isEmpty, let cropped = cgImage.cropping(to: bounded) else { return nil }
        self.init(cgImage: cropped,
                  width: max(1, Int((bounded.width * scale).rounded())),
                  height: max(1, Int((bounded.height * scale).rounded())))
    }

    @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = (y * width + x) * 4
        return (Float(data[i]), Float(data[i + 1]), Float(data[i + 2]))
    }

    func cgImage() -> CGImage? {
        var copy = data
        return copy.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

#if canImport(UIKit)
extension UIImage {
    /// Pixels in display orientation (camera photos are often stored rotated).
    func uprightCGImage(maxDimension: CGFloat? = nil) -> CGImage? {
        var target = size
        if let maxDimension, max(size.width, size.height) > maxDimension {
            let k = maxDimension / max(size.width, size.height)
            target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        }
        if imageOrientation == .up, target == size, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }
}

#endif

/// sRGB -> CIE Lab in OpenCV's 8-bit convention (L 0...255, a/b offset by 128),
/// identical to the Metal kernel used for the reference image.
enum LabColor {
    @inline(__always) static func fromRGB(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        @inline(__always) func linear(_ c: Float) -> Float {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = (0.412453 * rl + 0.357580 * gl + 0.180423 * bl) / 0.950456
        let y = 0.212671 * rl + 0.715160 * gl + 0.072169 * bl
        let z = (0.019334 * rl + 0.119193 * gl + 0.950227 * bl) / 1.088754
        @inline(__always) func f(_ t: Float) -> Float { t > 0.008856 ? cbrtf(t) : 7.787 * t + 16.0 / 116.0 }
        let fx = f(x), fy = f(y), fz = f(z)
        let l: Float = y > 0.008856 ? 116 * fy - 16 : 903.3 * y
        return (l * 255 / 100, 500 * (fx - fy) + 128, 200 * (fy - fz) + 128)
    }
}
