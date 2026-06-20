import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales raw cover-art bytes to a compact JPEG so the copy stored inline on the Album
/// row stays small (~1024 px on the long edge). The full-resolution original is kept
/// separately on disk in `ArtworkCache`, keyed by album id.
///
/// Uses ImageIO thumbnailing, which decodes the source at the reduced size instead of
/// inflating the full bitmap into memory — cheap enough to run per track in the off-actor
/// import pipeline.
enum ImageDownscaler {
    /// Returns a downscaled JPEG (long edge ≤ `maxPixel`), or the original bytes unchanged if
    /// decoding fails or the source is already smaller than the result.
    static func thumbnail(from data: Data, maxPixel: Int = 1024, quality: CGFloat = 0.82) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return data
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return data }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        let result = output as Data
        // Already smaller than our target → keep the original, no point storing a bigger file.
        return result.count < data.count ? result : data
    }
}
