import SwiftUI
import SwiftData

/// Maps every playlist entry that still has a VALID track to that track, walking the
/// `track → playlistEntries` inverse. Resolving a playlist's tracks through this map
/// never touches `entry.track`, so entries left dangling by a deleted track are simply
/// skipped instead of crashing.
func validEntryTrackMap(_ allTracks: [Track]) -> [PersistentIdentifier: Track] {
    var map: [PersistentIdentifier: Track] = [:]
    for track in allTracks {
        for entry in track.playlistEntries {
            map[entry.persistentModelID] = track
        }
    }
    return map
}

extension Playlist {
    func safeSortedTracks(using map: [PersistentIdentifier: Track]) -> [Track] {
        entries
            .sorted { $0.order < $1.order }
            .compactMap { map[$0.persistentModelID] }
    }
}

struct PlaylistsView: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Playlist.createdDate, order: .reverse) private var playlists: [Playlist]
    @Query private var allTracks: [Track]
    @State private var showingCreate = false
    @State private var newPlaylistName = ""

    var body: some View {
        VStack(spacing: 0) {
            playlistsHeader
            playlistsContent
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        .alert("Neue Playlist", isPresented: $showingCreate) {
            TextField("Name", text: $newPlaylistName)
            Button("Erstellen") {
                guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                try? app.library.createPlaylist(name: newPlaylistName)
                newPlaylistName = ""
            }
            Button("Abbrechen", role: .cancel) { newPlaylistName = "" }
        }
    }

    // MARK: - Header

    private var playlistsHeader: some View {
        HStack {
            Text("Playlists")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.white)
            Spacer()
            Button { showingCreate = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
                    .glassEffect(.regular, in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var playlistsContent: some View {
        if playlists.isEmpty {
            emptyState
        } else {
            let map = validEntryTrackMap(allTracks)
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)],
                    spacing: 22
                ) {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistCard(playlist: playlist, tracks: playlist.safeSortedTracks(using: map))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                try? app.library.deletePlaylist(playlist)
                            } label: {
                                Label("Playlist löschen", systemImage: "trash")
                                    .foregroundStyle(.red)
                            }
                            .tint(.red)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .lumaScrollClearance(playerActive: app.player.state.isActive)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.18))
            Text("Keine Playlists")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.4))
            Text("Tippe auf + um deine erste Playlist zu erstellen.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Playlist Card (gallery)

struct PlaylistCard: View {
    let playlist: Playlist
    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlaylistArtworkView(tracks: tracks)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(CountText.songs(tracks.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Playlist cover: a 2×2 mosaic of the first four tracks' artwork, or just the first
/// track's artwork when there are fewer than four. Updates automatically as tracks change.
struct PlaylistArtworkView: View {
    let tracks: [Track]
    var cornerRadius: CGFloat = 14

    /// Covers from the first four DISTINCT albums, in playlist order. De-duplicates by
    /// album identity (not by artwork bytes) so four songs from the same album no longer
    /// repeat the same tile. Tracks without artwork are skipped; falls back to the single
    /// first cover when fewer than four distinct-album covers exist.
    private var artworks: [Data] {
        var result: [Data] = []
        var seenAlbums = Set<PersistentIdentifier>()
        for track in tracks {
            guard let album = track.album, let data = album.artworkData else { continue }
            guard seenAlbums.insert(album.persistentModelID).inserted else { continue }
            result.append(data)
            if result.count == 4 { break }
        }
        return result
    }

    var body: some View {
        let arts = artworks
        Group {
            if arts.count >= 4 {
                GeometryReader { geo in
                    let half = (geo.size.width - 2) / 2
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ArtworkView(data: arts[0], cornerRadius: 0, size: half)
                            ArtworkView(data: arts[1], cornerRadius: 0, size: half)
                        }
                        HStack(spacing: 2) {
                            ArtworkView(data: arts[2], cornerRadius: 0, size: half)
                            ArtworkView(data: arts[3], cornerRadius: 0, size: half)
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ArtworkView(data: arts.first, cornerRadius: cornerRadius, size: nil)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
