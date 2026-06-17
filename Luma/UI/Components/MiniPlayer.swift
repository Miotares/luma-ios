import SwiftUI

/// Mini-player floated above the tab bar via `lumaMiniPlayer` (a `safeAreaInset`).
/// The Liquid Glass background is supplied by the caller's `.glassEffect`; this view
/// only lays out artwork, title, a thin progress indicator and the transport controls.
/// The title column fills the middle (no empty `Spacer`) so the glass stays continuous.
struct MiniPlayer: View {
    @Environment(AppContainer.self) private var app
    var onTap: (() -> Void)?

    var body: some View {
        if let track = app.player.currentTrack {
            content(track: track)
        }
    }

    private func content(track: Track) -> some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 12) {
                // Only the artwork + title open the full player. The transport
                // controls are OUTSIDE this tap region, so they no longer compete
                // with the open-gesture (which made them feel laggy/mushy).
                HStack(spacing: 12) {
                    ArtworkView(data: track.album?.artworkData, cornerRadius: 8, size: 44)
                        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }

                HStack(spacing: 2) {
                    controlButton("backward.fill", size: 18) {
                        Task { await app.queue.playPrevious() }
                    }
                    controlButton(
                        app.player.state.isPlaying ? "pause.fill" : "play.fill",
                        size: 26, weight: .medium
                    ) {
                        app.player.togglePlayPause()
                    }
                    controlButton("forward.fill", size: 18) {
                        Task { await app.queue.advance() }
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.vertical, 9)

            MiniProgressBar()
                .padding(.horizontal, 16)
                .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity)
    }

    private func controlButton(_ icon: String, size: CGFloat, weight: Font.Weight = .regular, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white)
                .contentTransition(.identity)   // no slow symbol morph on play↔pause
                .frame(width: 40, height: 48)
                .contentShape(Rectangle())
                .animation(nil, value: icon)     // flip state instantly, never animate
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Isolated so the ~4×/sec `currentTime` updates re-render only this hairline, not
/// the whole MiniPlayer (which kept its buttons busy and feeling unresponsive).
private struct MiniProgressBar: View {
    @Environment(AppContainer.self) private var app

    private var progress: Double {
        let d = app.player.duration
        guard d > 0 else { return 0 }
        return min(1, max(0, app.player.currentTime / d))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 2.5)
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: max(0, geo.size.width * progress), height: 2.5)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2.5)
    }
}
