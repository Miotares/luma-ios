import SwiftUI
import SwiftData

struct StatisticsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Track.playCount, order: .reverse) private var topTracks: [Track]
    @Query private var albums: [Album]
    @Query private var artists: [Artist]
    @Query private var playlists: [Playlist]

    // Actual listened time (includes partial / skipped plays), not playCount × duration.
    private var totalListeningTime: TimeInterval {
        topTracks.reduce(0) { $0 + $1.listenSeconds }
    }
    private var totalPlays: Int { topTracks.reduce(0) { $0 + $1.playCount } }
    private var topPlayed: [Track] { topTracks.filter { $0.playCount > 0 }.prefix(10).map { $0 } }

    /// Artists ranked by minutes actually listened (summed over their tracks).
    private var topArtists: [(artist: Artist, seconds: TimeInterval)] {
        artists
            .map { artist in (artist, artist.tracks.reduce(0) { $0 + $1.listenSeconds }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map { (artist: $0.0, seconds: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    heroCard
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 12)

                    summaryGrid
                        .padding(.horizontal, 16)

                    if !topPlayed.isEmpty {
                        sectionHeader("Top Songs")
                        ForEach(Array(topPlayed.enumerated()), id: \.element.id) { idx, track in
                            topTrackRow(rank: idx + 1, track: track)
                            if idx < topPlayed.count - 1 { LumaSeparator() }
                        }
                    }

                    if !topArtists.isEmpty {
                        sectionHeader("Top Künstler")
                        ForEach(Array(topArtists.enumerated()), id: \.element.artist.id) { idx, entry in
                            topArtistRow(rank: idx + 1, artist: entry.artist, seconds: entry.seconds)
                            if idx < topArtists.count - 1 { LumaSeparator() }
                        }
                    }

                    if topPlayed.isEmpty && topArtists.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, 20)
            }
            .lumaScrollClearance(playerActive: app.player.state.isActive)
        }
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
    }

    // MARK: - Header

    private var statsHeader: some View {
        HStack(spacing: 14) {
            LumaBackButton { dismiss() }
            Text("Statistiken")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    // MARK: - Hero (listening time)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "headphones")
                    .font(.system(size: 13, weight: .semibold))
                Text("HÖRZEIT")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
            }
            .foregroundStyle(.white.opacity(0.5))

            Text(DurationText.hoursMinutes(totalListeningTime))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(CountText.plays(totalPlays))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Library counts

    private var summaryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            StatCard(value: "\(topTracks.count)", label: "Songs",     icon: "music.note")
            StatCard(value: "\(albums.count)",    label: "Alben",     icon: "square.stack")
            StatCard(value: "\(artists.count)",   label: "Künstler",  icon: "music.microphone")
            StatCard(value: "\(playlists.count)", label: "Playlists", icon: "music.note.list")
        }
    }

    // MARK: - Rows

    private func topTrackRow(rank: Int, track: Track) -> some View {
        Button { playTrack(track, in: topPlayed) } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rank <= 3 ? .white : Color.white.opacity(0.4))
                    .frame(width: 24, alignment: .center)

                ArtworkView(data: track.album?.artworkData, cacheKey: track.album?.id.uuidString, cornerRadius: 6, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(track.playCount)×")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(LumaRowStyle())
    }

    private func topArtistRow(rank: Int, artist: Artist, seconds: TimeInterval) -> some View {
        Button { playArtist(artist) } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(rank <= 3 ? .white : Color.white.opacity(0.4))
                    .frame(width: 24, alignment: .center)

                ArtworkView(data: artistArtwork(artist), cacheKey: artist.id.uuidString, cornerRadius: 22, size: 44)

                Text(artist.name)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(DurationText.hoursMinutes(seconds))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(LumaRowStyle())
    }

    /// A representative cover for the artist — the first of their tracks that has one.
    private func artistArtwork(_ artist: Artist) -> Data? {
        artist.tracks.first(where: { $0.album?.artworkData != nil })?.album?.artworkData
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text("Noch keine Wiedergaben")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.4))
            Text("Hör etwas und deine Statistiken erscheinen hier.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private func playTrack(_ track: Track, in list: [Track]) {
        guard let idx = list.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(list, startAt: idx)
        Task { await app.player.play(track: track) }
    }

    /// Play an artist's catalogue, most-listened first.
    private func playArtist(_ artist: Artist) {
        let tracks = artist.tracks.sorted { $0.listenSeconds > $1.listenSeconds }
        guard let first = tracks.first else { return }
        app.queue.setQueue(tracks, startAt: 0)
        Task { await app.player.play(track: first) }
    }
}

// MARK: - Stat Card

/// Compact library-count card: monochrome icon + value + label on a surface tile,
/// matching the app's neutral white-on-dark language (no rainbow accents).
struct StatCard: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
