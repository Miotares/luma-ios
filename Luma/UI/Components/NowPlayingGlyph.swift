import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#endif

/// The animated "this track is playing" indicator shown on the current track's row (and the
/// queue's now-playing row).
///
/// iOS keeps the SF Symbol `waveform` with its `variableColor` symbol effect. macOS must NOT use
/// that: a repeating `symbolEffect` inside a `List` row redraws its RenderBox layer every frame,
/// and each redraw makes the MAIN thread wait synchronously on the WindowServer
/// (`RB::SharedSurfaceGroup::wait_for_allocations`). Measured on the shipping app: the main thread
/// sat blocked 48–59 % of wall time while a current-track row was merely instantiated (even
/// scrolled off-screen), CPU 2–3 % → 14–24 % — the "spongy while playing" feel. The macOS variant
/// below is four CALayer bars driven by `CABasicAnimation`, which the render server animates on
/// its own: 0 % app CPU and an idle main thread (same measurement method).
struct NowPlayingGlyph: View {
    var isActive: Bool
    var size: CGFloat
    var weight: Font.Weight = .regular
    var tint: Color

    #if os(macOS)
    // Read so an appearance flip re-runs the representable's update with the new environment
    // (the tint is an adaptive color that must be re-resolved for light/dark).
    @Environment(\.colorScheme) private var colorScheme
    #endif

    var body: some View {
        #if os(macOS)
        NowPlayingBars(isAnimating: isActive, tint: tint, colorScheme: colorScheme)
            .frame(width: (size * 1.15).rounded(), height: size.rounded())
            .accessibilityHidden(true)
        #else
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: isActive)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
        #endif
    }
}

#if os(macOS)
private struct NowPlayingBars: NSViewRepresentable {
    var isAnimating: Bool
    var tint: Color
    var colorScheme: ColorScheme

    func makeNSView(context: Context) -> NowPlayingBarsView { NowPlayingBarsView() }

    func updateNSView(_ view: NowPlayingBarsView, context: Context) {
        view.barColor = tint.resolve(in: context.environment).cgColor
        view.isAnimating = isAnimating
    }
}

/// Layer-backed bars. All motion is a repeating Core Animation on each bar's `transform.scale.y`,
/// so no app code (and no SwiftUI/RenderBox redraw) runs per frame.
final class NowPlayingBarsView: NSView {
    /// Resting heights (fraction of the full height) — a small static waveform while paused.
    private static let restScale: [CGFloat] = [0.45, 0.85, 0.6, 0.3]
    private static let durations: [CFTimeInterval] = [0.52, 0.41, 0.63, 0.47]
    private static let animationKey = "luma.nowPlaying.bounce"

    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }

    var barColor: CGColor = .white {
        didSet {
            guard barColor != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for bar in bars { bar.backgroundColor = barColor }
            CATransaction.commit()
        }
    }

    var isAnimating = false {
        didSet { if isAnimating != oldValue { syncAnimations() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.backgroundColor = barColor
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let count = CGFloat(bars.count)
        // Bars and gaps share the width evenly (n bars + n-1 gaps of the same size).
        let unit = bounds.width / (count * 2 - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            // Scale around the centre, so the bars pulse symmetrically like the waveform glyph
            // (and the view's flippedness doesn't matter).
            bar.bounds = CGRect(x: 0, y: 0, width: unit, height: bounds.height)
            bar.position = CGPoint(x: unit * (CGFloat(i) * 2 + 0.5), y: bounds.midY)
            bar.cornerRadius = unit / 2
            bar.transform = CATransform3DMakeScale(1, Self.restScale[i], 1)
        }
        CATransaction.commit()
        syncAnimations()
    }

    // Core Animation drops a layer's animations when it leaves the render tree (row reuse, the
    // view being re-hosted, the window closing) — re-arm them whenever the view comes back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncAnimations()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncAnimations()
    }

    private func syncAnimations() {
        let shouldRun = isAnimating && window != nil
        for (i, bar) in bars.enumerated() {
            let running = bar.animation(forKey: Self.animationKey) != nil
            if shouldRun, !running {
                let bounce = CABasicAnimation(keyPath: "transform.scale.y")
                bounce.fromValue = 0.25
                bounce.toValue = 1.0
                bounce.duration = Self.durations[i]
                bounce.autoreverses = true
                bounce.repeatCount = .infinity
                bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(bounce, forKey: Self.animationKey)
            } else if !shouldRun, running {
                bar.removeAnimation(forKey: Self.animationKey)
            }
        }
    }
}
#endif
