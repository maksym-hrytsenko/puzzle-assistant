import CoreImage
import CoreImage.CIFilterBuiltins

struct ImageEnhancer {
    static func enhanceReferenceImage(_ image: CIImage) -> CIImage {
        var output = image

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = output
        colorControls.saturation = 1.05
        colorControls.contrast = 1.08
        colorControls.brightness = 0.0
        output = colorControls.outputImage ?? output

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = output
        sharpen.sharpness = 0.4
        output = sharpen.outputImage ?? output

        return output
    }
}
