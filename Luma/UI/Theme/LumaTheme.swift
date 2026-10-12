import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Luma Design Tokens (appearance-adaptive)
//
// Luma's visual language is the same on every platform — a dark, glassy, white-accent
// music player. iOS is locked to dark (see LumaApp), so on iOS these tokens resolve to
// the EXACT literals the app shipped with: there is zero visual change on iOS.
//
// macOS follows the system appearance (the user asked for light + dark). To make that
// work without hand-tuning hundreds of colors, the whole UI is expressed in terms of an
// adaptive "ink" — `lumaInk(opacity)` — instead of `Color.white.opacity(opacity)`.
// Ink is white on a dark background and (near-)black on a light one, so every text
// color, icon tint, hairline and subtle fill flips correctly with the appearance while
// preserving the exact opacity ramp the design was tuned with. In dark mode ink == white,
// so dark Luma is pixel-identical to before.

extension Color {

    // MARK: Surfaces

    /// App background. Dark: the near-black Luma canvas. Light (macOS): a soft cool white.
    static let lumaBackground = adaptive(
        dark:  (0.051, 0.051, 0.067),
        light: (0.953, 0.953, 0.965)
    )

    /// Elevated surface (cards, sheets, controls). Dark: lifted slate. Light: pure white.
    static let lumaSurface = adaptive(
        dark:  (0.098, 0.102, 0.133),
        light: (1.000, 1.000, 1.000)
    )

    // MARK: Ink (replaces every `.white` / `.white.opacity(x)`)

    /// Full-strength adaptive ink — white on dark, near-black on light. Use `lumaInk(_:)`
    /// for the common opacity-scaled cases; this is the opaque base it scales from.
    static let lumaInkBase = adaptive(
        dark:  (1.000, 1.000, 1.000),
        light: (0.066, 0.066, 0.086)
    )

    /// Adaptive ink at the given opacity. `lumaInk(0.5)` is the drop-in for
    /// `Color.white.opacity(0.5)`: identical in dark mode, correct (dark ink) in light.
    static func lumaInk(_ opacity: Double = 1) -> Color { lumaInkBase.opacity(opacity) }

    // MARK: Accent

    /// High-contrast accent (play-button fills, active pills, tint). Luma's accent is the
    /// "ink" color itself — white on dark, near-black on light — so it always pops against
    /// the canvas without introducing a brand hue.
    static let lumaAccent = lumaInkBase

    /// Foreground that sits ON an accent fill (e.g. the play glyph). The inverse of accent:
    /// black on dark, white on light.
    static let lumaOnAccent = adaptive(
        dark:  (0.000, 0.000, 0.000),
        light: (1.000, 1.000, 1.000)
    )

    /// Readable "on" color for switches/toggles (a plain white tint is invisible on the
    /// dark canvas, and pure-light needs a touch more depth). Slightly deeper in light.
    static let lumaToggle = adaptive(
        dark:  (0.22, 0.80, 0.46),
        light: (0.15, 0.66, 0.38)
    )

    // MARK: - Adaptive helper

    /// Builds a Color that resolves per appearance. On iOS the app is locked to dark, so
    /// only the `dark` tuple is ever used (the literal the app shipped with). On macOS the
    /// color tracks the effective NSAppearance (light/dark) live.
    private static func adaptive(
        dark: (Double, Double, Double),
        light: (Double, Double, Double)
    ) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(red: dark.0, green: dark.1, blue: dark.2)
        #endif
    }
}

// Leading-dot access in ShapeStyle positions, mirroring how SwiftUI exposes `.white`,
// `.red`, … This lets `.foregroundStyle(.lumaInk(0.5))`, `.fill(.lumaAccent)`,
// `.background(.lumaSurface)` etc. resolve, not just the explicit `Color.lumaInk(…)` form.
extension ShapeStyle where Self == Color {
    static func lumaInk(_ opacity: Double = 1) -> Color { Color.lumaInk(opacity) }
    static var lumaBackground: Color { Color.lumaBackground }
    static var lumaSurface: Color { Color.lumaSurface }
    static var lumaAccent: Color { Color.lumaAccent }
    static var lumaOnAccent: Color { Color.lumaOnAccent }
    static var lumaToggle: Color { Color.lumaToggle }
}

// MARK: - Appearance

#if os(macOS)
/// User's macOS appearance preference. "system" follows the OS; the app otherwise pins
/// light/dark. Stored so the choice survives launches; surfaced in Settings.
enum LumaAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light:  return "Hell"
        case .dark:   return "Dunkel"
        }
    }
    static let storageKey = "macAppearance"
}
#endif

extension View {
    /// Luma's identity is dark on iOS (locked). On macOS the app follows the system
    /// appearance by default, or the user's explicit Hell/Dunkel override from Settings.
    /// Sheets re-apply this because a presented scene does not inherit the host's scheme.
    @ViewBuilder func lumaForcedAppearance() -> some View {
        #if os(macOS)
        modifier(MacAppearanceModifier())
        #else
        preferredColorScheme(.dark)
        #endif
    }
}

#if os(macOS)
private struct MacAppearanceModifier: ViewModifier {
    @AppStorage(LumaAppearance.storageKey) private var raw = LumaAppearance.system.rawValue
    func body(content: Content) -> some View {
        content.preferredColorScheme(LumaAppearance(rawValue: raw)?.colorScheme ?? nil)
    }
}
#endif
