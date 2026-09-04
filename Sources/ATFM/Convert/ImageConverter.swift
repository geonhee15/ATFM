import AppKit
import ImageIO
import UniformTypeIdentifiers

/// ImageIO based still-image conversion (handles EXIF orientation, optional downscale, alpha flattening).
enum ImageConverter {
    static func convert(input: URL, output: URL, format: OutputFormat, quality: Double, maxPixelSize: Int) throws {
        guard let utType = format.utType else { throw ConvertError.unsupported(format.title) }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConvertError.failed("이미지를 열 수 없어요")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longest = max(width, height, 1)
        let target = maxPixelSize > 0 ? min(maxPixelSize, longest) : longest

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCache: false,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConvertError.failed("이미지를 디코딩하지 못했어요")
        }

        let supportsAlpha = ["public.png", "public.tiff", "com.compuserve.gif", "public.heic", "public.avif"].contains(utType)
        if !supportsAlpha, hasAlpha(image) {
            image = try flattened(image)
        }

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, utType as CFString, 1, nil) else {
            throw ConvertError.failed("\(format.title) 파일을 만들 수 없어요")
        }
        var destinationOptions: [CFString: Any] = [:]
        if format.lossy { destinationOptions[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError.failed("\(format.title) 로 저장하지 못했어요")
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Draws the image over white so JPEG/BMP don't turn transparent areas black.
    private static func flattened(_ image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvertError.failed("이미지 배경을 처리하지 못했어요")
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConvertError.failed("이미지 배경을 처리하지 못했어요") }
        return result
    }
}
