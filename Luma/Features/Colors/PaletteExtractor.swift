import SwiftUI
import Foundation

struct ColorPalette: Sendable {
    let background: Color  // dark, saturated — used as gradient base
    let accent: Color      // vibrant dominant color
    let isDark: Bool       // whether foreground text should be light
}

// Thread-safe color palette extractor with in-memory cache.
// Uses pixel sampling of a 20×20 downsample — fast and accurate enough for music art.
actor PaletteExtractor {
    static let shared = PaletteExtractor()
    private init() {}

    private var cache: [UUID: ColorPalette] = [:]

    func palette(for id: UUID, imageData: Data?) async -> ColorPalette? {
        if let hit = cache[id] { return hit }
        guard let data = imageData else { return nil }

        let result = await Task.detached(priority: .userInitiated) {
            PaletteExtractor.extract(from: data)
        }.value

        if let result { cache[id] = result }
        return result
    }

    func invalidate(for id: UUID) {
        cache.removeValue(forKey: id)
    }

    // MARK: - Pixel Analysis (runs off main actor)

    private static func extract(from data: Data) -> ColorPalette? {
        #if os(iOS) || os(visionOS)
        guard let source = UIImage(data: data) else { return nil }
        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = small.cgImage else { return nil }
        #elseif os(macOS)
        guard let source = NSImage(data: data) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        guard let cgImage = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        #else
        return nil
        #endif

        var pixels = [UInt8](repeating: 0, count: 20 * 20 * 4)
        guard let ctx = CGContext(
            data: &pixels, width: 20, height: 20,
            bitsPerComponent: 8, bytesPerRow: 80,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 20, height: 20))

        var rSum: Float = 0, gSum: Float = 0, bSum: Float = 0, wSum: Float = 0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Float(pixels[i])   / 255
            let g = Float(pixels[i+1]) / 255
            let b = Float(pixels[i+2]) / 255

            let maxC = Swift.max(r, g, b)
            let minC = Swift.min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            let brightness  = maxC
            // Weight: high saturation + mid-high brightness → vibrant colors win
            let weight = (1 + saturation * 5) * (0.2 + brightness * 0.8)

            rSum += r * weight; gSum += g * weight; bSum += b * weight; wSum += weight
        }

        guard wSum > 0 else { return nil }
        let r = CGFloat(rSum / wSum)
        let g = CGFloat(gSum / wSum)
        let b = CGFloat(bSum / wSum)

        // Perceived luminance for text contrast decision
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b

        return ColorPalette(
            background: Color(red: r * 0.20, green: g * 0.20, blue: b * 0.20),
            accent: Color(red: r, green: g, blue: b),
            isDark: luminance < 0.5
        )
    }
}
