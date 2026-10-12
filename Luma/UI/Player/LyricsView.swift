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
                    Text(verbatim: "\(track.title) · \(track.artistName)")
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
                .padding(.top, 10)
                // Room below the last lines, so they too can scroll up to the reading position.
                .padding(.bottom, 360)
            }
            // Lines fade out towards the header and the bottom edge instead of being cut off.
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
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

    /// Where the current line sits in the view: a little above the middle.
    private static let readingAnchor = UnitPoint(x: 0.5, y: 0.32)

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
