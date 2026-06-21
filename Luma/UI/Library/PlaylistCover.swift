import SwiftUI

// MARK: - Cover style

/// How a single playlist renders its cover. `mosaic` is the original behaviour — a 2×2 grid of
/// the first tracks' album art — and is always available as an option. `photo` shows a
/// user-picked image kept entirely on-device. `generated` shows an app-rendered pattern the
/// user customises (colour / pattern / texture / symbol).
///
/// Persisted as a raw `Int` on `Playlist.coverStyleRaw` — a cheap scalar column, so reading the
/// style while building a card never faults the (externalStorage) custom-image blob.
nonisolated enum PlaylistCoverStyle: Int, Codable, CaseIterable, Identifiable {
    case mosaic = 0
    case photo = 1
    case generated = 2

    var id: Int { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .mosaic:    return "Mosaik"
        case .photo:     return "Foto"
        case .generated: return "Muster"
        }
    }
}

// MARK: - Generated cover configuration

/// The recipe for a generated cover. Tiny + Codable, persisted as JSON on the playlist — no
/// bitmap is ever stored, the cover is re-rendered live at any size, so it stays crisp from a
/// 46pt thumbnail to a 220pt header and costs nothing to store. Pure data (no SwiftUI colours):
/// holds a base `hue` the palette is derived from.
nonisolated struct GeneratedCoverConfig: Codable, Equatable {
    var hue: Double = 0.58
    var pattern: Pattern = .gradient
    var texture: Texture = .none
    /// Optional SF Symbol drawn as a focal glyph; nil = none.
    var glyph: String? = nil
    /// Whether the playlist title is drawn onto the cover.
    var showTitle: Bool = false

    init() {}

    /// Tolerant decode: each field falls back to its default when the key is absent, so adding a
    /// field (like `showTitle`) never breaks a config persisted by an earlier build. `encode` and
    /// `CodingKeys` stay synthesized.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0.58
        pattern = try c.decodeIfPresent(Pattern.self, forKey: .pattern) ?? .gradient
        texture = try c.decodeIfPresent(Texture.self, forKey: .texture) ?? .none
        glyph = try c.decodeIfPresent(String.self, forKey: .glyph)
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? false
    }

    nonisolated enum Pattern: Int, Codable, CaseIterable, Identifiable {
        case gradient, mesh, radial, conic, split
        var id: Int { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .gradient: return "Verlauf"
            case .mesh:     return "Mesh"
            case .radial:   return "Strahl"
            case .conic:    return "Wirbel"
            case .split:    return "Diagonal"
            }
        }
    }

    nonisolated enum Texture: Int, Codable, CaseIterable, Identifiable {
        case none, grain, dots, lines, vignette
        var id: Int { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .none:     return "Ohne"
            case .grain:    return "Korn"
            case .dots:     return "Punkte"
            case .lines:    return "Linien"
            case .vignette: return "Vignette"
            }
        }
    }

    static let `default` = GeneratedCoverConfig()

    /// Curated base hues shown as colour swatches in the editor.
    static let hueChoices: [Double] = (0..<12).map { Double($0) / 12.0 }

    /// Curated focal-glyph choices (SF Symbols). "None" is offered separately in the UI.
    static let glyphChoices: [String] = [
        "music.note", "heart.fill", "star.fill", "bolt.fill",
        "flame.fill", "moon.stars.fill", "sun.max.fill", "leaf.fill",
        "sparkles", "guitars.fill", "headphones", "drop.fill",
    ]

    /// A pleasant default derived from the playlist name, so switching to "Muster" already looks
    /// intentional and unique before the user changes anything. FNV-1a hash → hue.
    static func seeded(forName name: String) -> GeneratedCoverConfig {
        var h: UInt64 = 1469598103934665603
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        var cfg = GeneratedCoverConfig()
        // Snap to one of the editor's swatch hues so the seeded default actually highlights a
        // swatch (and is re-selectable) instead of landing between them with no selection ring.
        cfg.hue = hueChoices[Int(h % UInt64(hueChoices.count))]
        return cfg
    }

    /// Hue wrapped into [0, 1) — shared so swatches and the renderer derive identical colours.
    static func wrap(_ x: Double) -> Double {
        let m = x.truncatingRemainder(dividingBy: 1)
        return m < 0 ? m + 1 : m
    }

    /// Two-stop gradient used for the editor's colour swatches (a compact stand-in for the full
    /// pattern), matching the renderer's light→deep palette.
    static func swatchGradient(hue: Double) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: wrap(hue + 0.02), saturation: 0.55, brightness: 0.98),
                Color(hue: wrap(hue - 0.07), saturation: 0.92, brightness: 0.48),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

// MARK: - Renderer

/// Renders a generated cover from a `GeneratedCoverConfig`. Used by both the cover editor's live
/// preview and `PlaylistArtworkView` (when a playlist's style is `.generated`). Pure SwiftUI
/// vector drawing — no bitmap — so it's crisp at every size and cheap enough to render in a
/// scrolling grid.
struct GeneratedCoverView: View {
    let config: GeneratedCoverConfig
    /// The playlist title, drawn onto the cover when `config.showTitle` is true. nil/empty hides it.
    var title: String? = nil
    var cornerRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                pattern(side: side)
                sheen
                texture(side: side)
                glyph(side: side)
                titleOverlay(side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // Palette derived from the base hue: a light tint, a saturated mid, and a deep shade.
    private var light: Color { Color(hue: GeneratedCoverConfig.wrap(config.hue + 0.02), saturation: 0.55, brightness: 0.98) }
    private var mid:   Color { Color(hue: GeneratedCoverConfig.wrap(config.hue),         saturation: 0.78, brightness: 0.82) }
    private var deep:  Color { Color(hue: GeneratedCoverConfig.wrap(config.hue - 0.07),  saturation: 0.92, brightness: 0.45) }

    @ViewBuilder
    private func pattern(side: CGFloat) -> some View {
        switch config.pattern {
        case .gradient:
            LinearGradient(colors: [light, mid, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mesh:
            MeshGradient(
                width: 3, height: 3,
                points: [
                    SIMD2<Float>(0, 0),   SIMD2<Float>(0.5, 0),   SIMD2<Float>(1, 0),
                    SIMD2<Float>(0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1, 0.5),
                    SIMD2<Float>(0, 1),   SIMD2<Float>(0.5, 1),   SIMD2<Float>(1, 1),
                ],
                colors: [light, mid, deep, mid, light, deep, deep, mid, light]
            )
        case .radial:
            ZStack {
                deep
                RadialGradient(colors: [light, mid, .clear], center: .topLeading, startRadius: 0, endRadius: side * 1.15)
            }
        case .conic:
            ZStack {
                deep
                AngularGradient(colors: [light, mid, deep, mid, light], center: .center)
            }
        case .split:
            ZStack {
                deep
                DiagonalTriangle()
                    .fill(LinearGradient(colors: [light, mid], startPoint: .top, endPoint: .bottomTrailing))
            }
        }
    }

    /// A faint top-down highlight applied to every pattern for a little depth/sheen.
    private var sheen: some View {
        LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func texture(side: CGFloat) -> some View {
        switch config.texture {
        case .none:
            EmptyView()
        case .grain:
            grain
        case .dots:
            dots
        case .lines:
            lines
        case .vignette:
            RadialGradient(colors: [.clear, .black.opacity(0.40)], center: .center,
                           startRadius: side * 0.18, endRadius: side * 0.72)
                .allowsHitTesting(false)
        }
    }

    /// Filmic grain — a deterministic dot field (fixed-seed RNG, so it renders identically every
    /// frame) blended over the pattern.
    private var grain: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(seed: 0xC0FFEE_BABE)
            let count = min(420, Int(size.width * size.height / 700))
            for _ in 0..<max(0, count) {
                let x = Double.random(in: 0...max(1, size.width), using: &rng)
                let y = Double.random(in: 0...max(1, size.height), using: &rng)
                let r = Double.random(in: 0.4...1.2, using: &rng)
                let op = Double.random(in: 0.02...0.11, using: &rng)
                let dark = Bool.random(using: &rng)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color((dark ? Color.black : Color.white).opacity(op))
                )
            }
        }
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }

    private var dots: some View {
        Canvas { ctx, size in
            let step = max(12, size.width / 12)
            let dot: CGFloat = 2.2
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                        with: .color(.white.opacity(0.12))
                    )
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    private var lines: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 13
            var x = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 1)
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glyph(side: CGFloat) -> some View {
        if let glyph = config.glyph {
            Image(systemName: glyph)
                .font(.system(size: side * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.15), radius: side * 0.02, y: side * 0.008)
        }
    }

    /// The playlist title pinned bottom-leading, over a bottom scrim so it stays legible on any
    /// palette. Hidden on very small renders (e.g. the 46pt reorder thumbnail) where text would
    /// just be clutter; the surrounding list already shows the name there.
    @ViewBuilder
    private func titleOverlay(side: CGFloat) -> some View {
        if config.showTitle, let title, !title.isEmpty, side >= 60 {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                Text(title)
                    .font(.system(size: side * 0.12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.35), radius: side * 0.015, y: side * 0.006)
                    .padding(.horizontal, side * 0.08)
                    .padding(.bottom, side * 0.07)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Top-left triangle for the `.split` pattern.
private struct DiagonalTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Deterministic RNG (splitmix64) so a `.grain` texture renders identically every frame: a fresh
/// generator seeded with the same value each render produces the same dot field.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
