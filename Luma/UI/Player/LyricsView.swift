import SwiftUI

/// Lyrics of the track that is playing, as carried by its file (see `LyricsStore`). With
/// timestamps (LRC) they follow playback: the current line is lit, the view scrolls along, and a
/// tap on a line jumps there. Without timestamps it is the plain text to scroll through.
struct LyricsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var track: Track? { app.player.currentTrack }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        // Same backdrop as the player this opens from: the cover, blurred. Always dark, so the
        // text is white whatever the app's appearance.
        .background { ArtworkBackground(data: track?.resolvedArtworkData(), palette: nil) }
        #if os(iOS) || os(visionOS)
        // The lyrics cover the player, so its controls come along in small: pause, skip and
        // see where the song is without leaving the lyrics. (On the Mac the lyrics are a popover
        // right above the now-playing bar, which already has all of that.)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if track != nil {
                LyricsControls()
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        #endif
        .task(id: track?.id) { await app.lyrics.load(for: track) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lyrics")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                if let track {
                    Text(verbatim: "\(track.artistName) – \(track.title)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer()
            #if os(iOS) || os(visionOS)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schließen")
            #endif
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let track, app.lyrics.trackID == track.id, let lyrics = app.lyrics.lyrics {
            if lyrics.isSynced {
                SyncedLyrics(lines: lyrics.lines)
                    .id(track.id)   // a new song starts at the top, with fresh scroll state
            } else {
                ScrollView {
                    Text(lyrics.plainText)
                        .font(.system(size: 21, weight: .semibold))
                        .lineSpacing(9)
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 40)
                }
                .id(track.id)
            }
        } else {
            // The song changed to one without lyrics while this was open (the Lyrics button only
            // exists for songs that have them).
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Keine Lyrics")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Dieser Titel enthält keine Lyrics.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Controls

/// Compact transport for the lyrics view: elapsed time · previous / play-pause / next · time left,
/// over a hairline of progress — the mini-player's controls without its cover and title, which
/// the header above already shows. Built to the SAME measures as `MiniPlayer` (48 pt buttons +
/// 9 pt padding = 66 pt high, 18 pt corners, same icon sizes and progress line), so the two bars
/// read as one control.
private struct LyricsControls: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                LyricsTimeLabel(showsRemaining: false)
                    .frame(width: 56, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    button("backward.fill", size: 18, label: "Vorheriger Titel") {
                        Task { await app.queue.playPrevious() }
                    }
                    button(app.player.showsPlaying ? "pause.fill" : "play.fill", size: 26, weight: .medium,
                           label: app.player.showsPlaying ? "Pause" : "Wiedergabe") {
                        app.player.userTogglePlayPause()
                    }
                    button("forward.fill", size: 18, label: "Nächster Titel") {
                        Task { await app.queue.advance() }
                    }
                    .disabled(!app.queue.hasNext)
                    .opacity(app.queue.hasNext ? 1 : 0.35)
                }
                Spacer(minLength: 0)
                LyricsTimeLabel(showsRemaining: true)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            LyricsProgressBar()
                .padding(.horizontal, 16)
                .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .environment(\.colorScheme, .dark)   // sits on the (always dark) cover backdrop
    }

    private func button(_ icon: String, size: CGFloat, weight: Font.Weight = .regular,
                        label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.white)
                .contentTransition(.identity)   // no slow symbol morph on play↔pause
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
                .animation(nil, value: icon)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Isolated, like the progress line below, so the several-times-a-second position updates
/// re-render only these few characters — not the buttons next to them.
private struct LyricsTimeLabel: View {
    @Environment(AppContainer.self) private var app
    let showsRemaining: Bool

    var body: some View {
        let time = app.player.currentTime
        let shown = showsRemaining ? max(0, app.player.duration - time) : time
        Text(verbatim: (showsRemaining ? "-" : "") + Self.format(shown))
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
    }

    private static func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct LyricsProgressBar: View {
    @Environment(AppContainer.self) private var app

    private var progress: Double {
        let duration = app.player.duration
        guard duration > 0 else { return 0 }
        return min(1, max(0, app.player.currentTime / duration))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: 2.5)
    }
}

// MARK: - Synced lyrics

/// Timestamped lyrics that follow playback.
private struct SyncedLyrics: View {
    @Environment(AppContainer.self) private var app
    let lines: [LyricsText.Line]

    /// Index (into `lines`) of the line being sung; nil before the first one.
    @State private var active: Int?
    /// While the user scrolls by hand the view must not yank the text back to the current line;
    /// following resumes a few seconds after they let go (or at once when they tap a line).
    @State private var followPausedUntil = Date.distantPast

    /// Lines light up this much BEFORE their timestamp: read a beat early feels in sync, a beat
    /// late feels broken.
    private static let lead: TimeInterval = 0.15

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            lineView(line, index: index)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    // The first line starts clear of the fade under the header.
                    .padding(.top, Self.topFade + 12)
                    // Room below the last lines, so they too can scroll up to the middle.
                    .padding(.bottom, geo.size.height * 0.6)
                }
                // Lines fade out towards the header and the bottom edge instead of being cut off.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.topFade)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120)
                    }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .decelerating {
                        followPausedUntil = Date().addingTimeInterval(3)
                    }
                }
                .onChange(of: active) { _, index in
                    guard let index, Date() >= followPausedUntil else { return }
                    withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(index, anchor: Self.readingAnchor) }
                }
                .task { await follow(proxy) }
            }
        }
    }

    /// Height of the fade under the header.
    private static let topFade: CGFloat = 24

    /// Where the current line is held while the lyrics scroll along: the middle of the view (a
    /// touch above its geometric centre, which reads as centred under the header). The first
    /// lines simply start at the top — the text begins to move once the current line gets here.
    private static let readingAnchor = UnitPoint(x: 0.5, y: 0.45)

    @ViewBuilder
    private func lineView(_ line: LyricsText.Line, index: Int) -> some View {
        let isActive = index == active
        if let time = line.time {
            Button {
                app.player.seek(to: time)
                followPausedUntil = .distantPast
                active = index
            } label: {
                // A timestamp without words marks an instrumental stretch.
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white.opacity(isActive ? 1 : 0.34))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.3), value: isActive)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])
        } else if !line.text.isEmpty {
            // Untimed text inside timed lyrics (a heading, a credit line): shown, never lit.
            Text(line.text)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.34))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Keeps `active` in step with playback while the view is on screen.
    ///
    /// The player publishes its position only about five times a second — too coarse to switch
    /// lines on time. So between two published values the position is carried forward by the
    /// clock, and looked at often; `active` (the only state this writes) changes just once per
    /// line, so the text is not re-laid-out in between.
    private func follow(_ proxy: ScrollViewProxy) async {
        var lastPublished = app.player.currentTime
        var lastPublishedAt = Date()
        var first = true
        while !Task.isCancelled {
            let now = Date()
            let published = app.player.currentTime
            if published != lastPublished {
                lastPublished = published
                lastPublishedAt = now
            }
            var position = published
            if app.player.state.isPlaying {
                position += min(now.timeIntervalSince(lastPublishedAt), 0.4)
            }
            let index = lineIndex(at: position + Self.lead)
            if index != active { active = index }
            if first {
                // Opened mid-song: start at the current line, without the scroll animation.
                first = false
                if let index { proxy.scrollTo(index, anchor: Self.readingAnchor) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The last timed line at or before `position` (lines are in playing order).
    private func lineIndex(at position: TimeInterval) -> Int? {
        var result: Int?
        for (index, line) in lines.enumerated() {
            guard let time = line.time else { continue }
            if time <= position { result = index } else { break }
        }
        return result
    }
}
