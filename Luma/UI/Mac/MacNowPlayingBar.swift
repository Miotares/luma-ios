#if os(macOS)
import SwiftUI

/// Full-width now-playing bar pinned to the bottom of the macOS window (Apple-Music style):
/// artwork + title on the left, centered transport with a scrubber. Reuses the shared
/// player/queue from `AppContainer`.
struct MacNowPlayingBar: View {
    @Environment(AppContainer.self) private var app
    var onOpen: () -> Void

    var body: some View {
        if let track = app.player.currentTrack {
            content(track)
        }
    }

    private func content(_ track: Track) -> some View {
        HStack(spacing: 16) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    ArtworkView(data: track.album?.artworkData, cornerRadius: 6, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1)
                        Text(track.artistName)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 5) {
                HStack(spacing: 22) {
                    transport("backward.fill", size: 15) { Task { await app.queue.playPrevious() } }
                    transport(app.player.state.isPlaying ? "pause.fill" : "play.fill", size: 19, weight: .medium) {
                        app.player.togglePlayPause()
                    }
                    transport("forward.fill", size: 15) { Task { await app.queue.advance() } }
                }
                MacScrubber()
            }
            .frame(width: 520)
            .layoutPriority(1)

            // Queue toggle + volume on the right; flexible width keeps transport centered.
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                Button(action: onOpen) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .help("Warteschlange")
                LumaVolumeControl()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func transport(_ icon: String, size: CGFloat, weight: Font.Weight = .regular,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white)
                .contentTransition(.identity)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .animation(nil, value: icon)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Isolated scrubber so the frequent `currentTime` updates re-render only this slider.
private struct MacScrubber: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.time(app.player.currentTime))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.5)).frame(width: 36, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { app.player.currentTime },
                    set: { app.player.seek(to: $0) }
                ),
                in: 0...max(app.player.duration, 0.01)
            )
            .controlSize(.mini)
            .tint(Color.lumaAccent)
            Text(Self.time(app.player.duration))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.5)).frame(width: 36, alignment: .leading)
        }
    }

    private static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Compact volume slider bound to the shared player (macOS). Used by the now-playing bar
/// and the queue.
struct LumaVolumeControl: View {
    @Environment(AppContainer.self) private var app
    var width: CGFloat = 96

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: app.player.volume < 0.01 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { Double(app.player.volume) },
                    set: { app.player.volume = Float($0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(Color.lumaAccent)
            .frame(width: width)
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)
        }
    }
}
#endif
