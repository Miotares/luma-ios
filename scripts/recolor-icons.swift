#!/usr/bin/env swift
//
// Generates the alternate app-icon variants from the primary (flat two-tone) Luma icon.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     xcrun swift scripts/recolor-icons.swift \
//       "Luma/Assets.xcassets/AppIcon.appiconset/Frame 23 (1).png" /tmp/out
//
// The source is a black music note on a solid background, so each variant is just a
// re-coloring: the GREEN channel (~215 on the background, ~12 on the note) is the
// discriminator, giving a soft mask that keeps the glyph's anti-aliased edges. To change
// the offered colors, edit `variants` below and re-run, then drop the 1024px PNGs into the
// matching AppIcon<Name>.appiconset (and 240px previews into IconPreview<Name>.imageset).
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("usage: recolor-icons <src.png> <outDir>") }
let srcPath = args[1]
let outDir = args[2]

guard let data = FileManager.default.contents(atPath: srcPath),
      let provider = CGDataProvider(data: data as CFData),
      let src = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
else { fatalError("cannot load \(srcPath)") }

let W = src.width, H = src.height
let bpr = W * 4
let cs = CGColorSpaceCreateDeviceRGB()
let bm = CGImageAlphaInfo.premultipliedLast.rawValue

var srcBuf = [UInt8](repeating: 0, count: H * bpr)
do {
    let ctx = CGContext(data: &srcBuf, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: cs, bitmapInfo: bm)!
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: W, height: H))
}

struct Variant { let name: String; let bg: (Double, Double, Double); let glyph: (Double, Double, Double) }
let variants = [
    Variant(name: "AppIconGraphite", bg: (28, 28, 30),   glyph: (255, 255, 255)),
    Variant(name: "AppIconSnow",     bg: (244, 244, 247), glyph: (20, 20, 22)),
    Variant(name: "AppIconBlue",     bg: (10, 122, 255),  glyph: (255, 255, 255)),
    Variant(name: "AppIconViolet",   bg: (88, 86, 224),   glyph: (255, 255, 255)),
]

func writePNG(_ buffer: [UInt8], to path: String) {
    var b = buffer
    // iOS app icons must NOT carry an alpha channel (App Store upload rejects them, ITMS-90717).
    // The buffer is RGBX (alpha byte = 255); noneSkipLast ignores it so ImageIO writes 24-bit RGB.
    let opaque = CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: &b, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: cs, bitmapInfo: opaque)!
    guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("dest failed") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let lo = 50.0, hi = 190.0
for v in variants {
    var out = [UInt8](repeating: 0, count: H * bpr)
    var i = 0
    while i < H * bpr {
        let g = Double(srcBuf[i + 1])
        var t = (g - lo) / (hi - lo)
        t = max(0, min(1, t))               // 1 = background, 0 = glyph
        out[i]     = UInt8(max(0, min(255, v.glyph.0 * (1 - t) + v.bg.0 * t)))
        out[i + 1] = UInt8(max(0, min(255, v.glyph.1 * (1 - t) + v.bg.1 * t)))
        out[i + 2] = UInt8(max(0, min(255, v.glyph.2 * (1 - t) + v.bg.2 * t)))
        out[i + 3] = 255
        i += 4
    }
    writePNG(out, to: "\(outDir)/\(v.name)_1024.png")
    print("wrote \(v.name)_1024.png")
}
