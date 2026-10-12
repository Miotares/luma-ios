#if os(macOS)
import SwiftUI
import AppKit

/// The menu-bar popover (`MenuBarExtra` window style): now-playing artwork + transport, so
/// playback is controllable while the main window is closed or in the background — a native
/// expectation for a Mac music player. Reads the shared player/queue from `AppContainer`.
struct MacMenuBarPlayer: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if let track = app.player.currentTrack {
                nowPlaying(track)
            } else {
                idle
            }
            Divider().padding(.top, 4)
            footer
        }
        .padding(14)
        .frame(width: 288)
    }

    private func nowPlaying(_ track: Track) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(data: track.resolvedArtworkData(), cacheKey: track.artworkCacheKey,
                            cornerRadius: 8, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.lumaInk())
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.system(size: 12))
                        .foregroundStyle(.lumaInk(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            MenuBarProgress()

            HStack(spacing: 28) {
                transport("backward.fill", size: 16) { Task { await app.queue.playPrevious() } }
                transport(app.player.showsPlaying ? "pause.fill" : "play.fill", size: 22) {
                    app.player.userTogglePlayPause()
                }
                transport("forward.fill", size: 16) { Task { await app.queue.advance() } }
            }
            .padding(.top, 2)
        }
    }

    private var idle: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundStyle(.lumaInk(0.4))
            Text("Nichts wird abgespielt")
                .font(.system(size: 13))
                .foregroundStyle(.lumaInk(0.55))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button("Luma öffnen") {
                NSApp.activate(ignoringOtherApps: true)
                // Bring an existing window forward (or let the WindowGroup reopen one).
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.lumaInk(0.8))
            Spacer()
            Button("Beenden") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.lumaInk(0.5))
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.top, 8)
    }

    private func transport(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.lumaInk())
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Thin progress bar for the menu-bar popover. Isolated so the ~per-second `currentTime`
/// updates re-render only this strip, not the whole popover.
private struct MenuBarProgress: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        let duration = max(app.player.duration, 0.01)
        let fraction = min(max(app.player.currentTime / duration, 0), 1)
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.lumaInk(0.14))
                    Capsule().fill(.lumaAccent).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            HStack {
                Text(Self.time(app.player.currentTime))
                Spacer()
                Text(Self.time(app.player.duration))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.lumaInk(0.45))
        }
    }

    private static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif
