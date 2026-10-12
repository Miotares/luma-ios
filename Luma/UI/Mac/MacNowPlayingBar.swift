#if os(macOS)
import SwiftUI

/// Floating now-playing pill for macOS (Apple-Music-style Liquid Glass). Two rows: the cover +
/// title/artist on the left with the transport and right-hand controls on top, a full-width
/// scrubber below. The width is fully dynamic (no fixed center column) so the pill never overflows
/// or slips behind the chrome when the window is made narrow — the title truncates instead. Reuses
/// the shared player/queue from `AppContainer`.
struct MacNowPlayingBar: View {
    @Environment(AppContainer.self) private var app
    var onOpen: () -> Void
    /// Whether the queue inspector is currently open — lights up the queue button so it reads as
    /// the active toggle (the only stateful one in the pill besides the EQ).
    var isQueueOpen: Bool = false
    @State private var showingEQ = false
    @State private var showingLyrics = false

    var body: some View {
        if let track = app.player.currentTrack {
            content(track)
        }
    }

    private func content(_ track: Track) -> some View {
        HStack(spacing: 16) {
            // Transport — its OWN column on the far left, vertically centered across both rows:
            // shuffle · prev · play/pause · next · repeat.
            HStack(spacing: 14) {
                iconToggle("shuffle", active: app.queue.shuffleMode == .on, label: "Zufällig") {
                    app.queue.toggleShuffle()
                }
                transport("backward.fill", size: 14, label: "Vorheriger Titel") {
                    Task { await app.queue.playPrevious() }
                }
                transport(app.player.state.isPlaying ? "pause.fill" : "play.fill", size: 18, weight: .medium,
                          label: app.player.state.isPlaying ? "Pause" : "Wiedergabe") {
                    app.player.togglePlayPause()
                }
                transport("forward.fill", size: 14, label: "Nächster Titel") {
                    Task { await app.queue.advance() }
                }
                iconToggle(app.queue.repeatMode == .one ? "repeat.1" : "repeat",
                           active: app.queue.repeatMode != .off, label: "Wiederholen") {
                    app.queue.toggleRepeat()
                }
            }
            .fixedSize()

            // Everything else, to the RIGHT of the transport: cover/title + right-hand controls on
            // top, the scrubber below. The cover and the scrubber share THIS column's leading edge,
            // so they start flush (the scrubber is just shorter than before — that's fine).
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    // Cover + title/artist, left-aligned. Tap opens the queue. The title carries the
                    // layout flex: under a narrow window it truncates so nothing overflows or hides.
                    Button(action: onOpen) {
                        HStack(spacing: 9) {
                            ArtworkView(data: track.resolvedArtworkData(), cacheKey: track.artworkCacheKey,
                                        cornerRadius: 5, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.lumaInk()).lineLimit(1)
                                Text(track.artistName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.lumaInk(0.6)).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    // Right: equalizer, queue, volume (icon → popover).
                    HStack(spacing: 12) {
                        Button { showingEQ.toggle() } label: {
                            controlIcon("slider.vertical.3",
                                        tint: app.equalizer.isEnabled ? Color.lumaAccent : .lumaInk(0.75))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Equalizer")
                        .accessibilityLabel("Equalizer")
                        .popover(isPresented: $showingEQ, arrowEdge: .bottom) {
                            EqualizerView().environment(app).frame(width: 380, height: 460)
                        }

                        Button { showingLyrics.toggle() } label: {
                            controlIcon("quote.bubble",
                                        tint: showingLyrics ? Color.lumaAccent : .lumaInk(0.75))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Lyrics")
                        .accessibilityLabel("Lyrics")
                        .popover(isPresented: $showingLyrics, arrowEdge: .bottom) {
                            LyricsView().environment(app).frame(width: 380, height: 520)
                        }

                        Button(action: onOpen) {
                            controlIcon("list.bullet",
                                        tint: isQueueOpen ? Color.lumaAccent : .lumaInk(0.75))
                                // Lit pill behind the icon while the queue is open, so the toggle
                                // clearly reads as active (a bare brighter tint was too subtle).
                                .background {
                                    if isQueueOpen {
                                        Circle().fill(.lumaInk(0.16))
                                    }
                                }
                        }
                        .buttonStyle(PressableButtonStyle())
                        .help("Warteschlange")
                        .accessibilityLabel("Warteschlange")

                        LumaVolumeButton()
                    }
                    .fixedSize()
                }

                // Scrubber — flush with the cover above it (shorter, since the transport column
                // takes the left edge).
                MacScrubber()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Liquid-Glass pill (Apple-Music style); inset from the window edges by MacRootView.
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    /// Plain transport glyph (prev / play-pause / next).
    private func transport(_ icon: String, size: CGFloat, weight: Font.Weight = .regular,
                           label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.lumaInk())
                .contentTransition(.identity)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .animation(nil, value: icon)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    /// Stateful toggle glyph (shuffle / repeat) — tinted with the accent when active.
    private func iconToggle(_ icon: String, active: Bool, label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Color.lumaAccent : .lumaInk(0.55))
                .contentTransition(.identity)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .animation(nil, value: icon)
        }
        .buttonStyle(PressableButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func controlIcon(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

/// Isolated scrubber so the frequent `currentTime` updates re-render only this slider.
private struct MacScrubber: View {
    @Environment(AppContainer.self) private var app
    /// Thumb position while the user drags. A seek stops the node, reschedules the file segment,
    /// restarts playback and pushes now-playing info — far too heavy to run for every mouse-move
    /// of a drag (it stuttered the audio and the UI). So the drag only moves this local value and
    /// the player seeks ONCE, on release.
    @State private var dragTime: TimeInterval?
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.time(dragTime ?? app.player.currentTime))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(.lumaInk(0.5)).frame(width: 36, alignment: .leading)
            Slider(
                value: Binding(
                    get: { dragTime ?? app.player.currentTime },
                    set: { newValue in
                        // Outside a tracked drag (keyboard / accessibility increments) there is no
                        // release event to wait for — seek straight away.
                        if isEditing { dragTime = newValue } else { app.player.seek(to: newValue) }
                    }
                ),
                in: 0...max(app.player.duration, 0.01),
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing, let target = dragTime {
                        app.player.seek(to: target)
                        dragTime = nil
                    }
                }
            )
            .controlSize(.mini)
            .tint(Color.lumaAccent)
            Text(Self.time(app.player.duration))
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(.lumaInk(0.5)).frame(width: 36, alignment: .trailing)
        }
    }

    private static func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Volume as a single speaker icon (now-playing bar). Clicking opens a popover to the left with a
/// draggable slider; the speaker inside the popover toggles mute, remembering the prior level.
struct LumaVolumeButton: View {
    @Environment(AppContainer.self) private var app
    @State private var showing = false
    @State private var preMuteVolume: Float = 0.7

    private var isMuted: Bool { app.player.volume < 0.01 }
    private var glyph: String {
        if isMuted { return "speaker.slash.fill" }
        if app.player.volume < 0.33 { return "speaker.fill" }
        if app.player.volume < 0.66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: glyph)
                .font(.system(size: 13))
                .foregroundStyle(isMuted ? Color.lumaAccent : .lumaInk(0.75))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .animation(nil, value: glyph)
        }
        .buttonStyle(PressableButtonStyle())
        .help("Lautstärke")
        .accessibilityLabel("Lautstärke")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            HStack(spacing: 10) {
                Button { toggleMute() } label: {
                    Image(systemName: glyph)
                        .font(.system(size: 13))
                        .foregroundStyle(isMuted ? Color.lumaAccent : .lumaInk(0.7))
                        .frame(width: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Ton ein" : "Stumm")
                Slider(value: Binding(
                    get: { Double(app.player.volume) },
                    set: { app.player.volume = Float($0) }
                ), in: 0...1)
                .controlSize(.small)
                .frame(width: 130)
                .tint(Color.lumaAccent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func toggleMute() {
        if isMuted {
            app.player.volume = preMuteVolume > 0.02 ? preMuteVolume : 0.5
        } else {
            preMuteVolume = app.player.volume
            app.player.volume = 0
        }
    }
}

#endif
