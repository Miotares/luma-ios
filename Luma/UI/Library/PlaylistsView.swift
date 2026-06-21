import SwiftUI
import SwiftData
import UniformTypeIdentifiers

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

/// A `Track` fetch that PREFETCHES the relationships every track row touches, in one batched
/// query each, instead of faulting them ON THE MAIN THREAD once PER TRACK:
///   • `album`  — every `TrackRow` reads `track.album?.id` for the artwork cache key; scrolling
///                 1500 rows otherwise = 1500 individual SQLite reads → stutter at ~0% CPU
///                 (the thread is *waiting on disk*, not computing).
///   • `playlistEntries` — `validEntryTrackMap` walks these for every track; without prefetch
///                 that fault-storm fired on every tab switch / play-state flip (always-mounted
///                 PlaylistsView), the multi-second UI stalls where the UI lagged the audio.
/// Prefetching turns both into single batched loads, so building rows / the map is a fast
/// in-memory pass. `artworkData` is `.externalStorage`, so prefetching `album` does NOT pull
/// the cover blobs — only the small Album rows.
func tracksRowDescriptor(sortByTitle: Bool = false, prefetchEntries: Bool = true) -> FetchDescriptor<Track> {
    var d = FetchDescriptor<Track>(sortBy: sortByTitle ? [SortDescriptor(\.title)] : [])
    d.relationshipKeyPathsForPrefetching = prefetchEntries ? [\.album, \.playlistEntries] : [\.album]
    return d
}

/// Artist fetch that prefetches `albums` + `tracks`, which every `ArtistListRow` reads
/// (`sortedAlbums.first?.artworkData`, `albumCount`, `trackCount`) — otherwise each artist row
/// faults two relationships from SQLite on the main thread while scrolling the Artists list.
func artistsRowDescriptor() -> FetchDescriptor<Artist> {
    var d = FetchDescriptor<Artist>(sortBy: [SortDescriptor(\.name)])
    d.relationshipKeyPathsForPrefetching = [\.albums, \.tracks]
    return d
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
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    @Query(tracksRowDescriptor()) private var allTracks: [Track]
    @State private var showingCreate = false
    @State private var newPlaylistName = ""
    @State private var isReordering = false
    @AppStorage(SmartSectionKind.masterKey) private var smartPlaylistsEnabled = true
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: PlaylistBackupDocument?
    @State private var showingImportResult = false
    @State private var importMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            playlistsHeader
            playlistsContent
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        .navigationDestination(for: SmartPlaylistKind.self) { SmartPlaylistDetailView(kind: $0) }
        .navigationDestination(for: SmartHub.self) { SmartHubView(hub: $0) }
        .alert("Neue Playlist", isPresented: $showingCreate) {
            TextField("Name", text: $newPlaylistName)
            Button("Erstellen") {
                guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                try? app.library.createPlaylist(name: newPlaylistName)
                newPlaylistName = ""
            }
            Button("Abbrechen", role: .cancel) { newPlaylistName = "" }
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: "Luma Playlists") { _ in }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { handleImport($0) }
        .alert("Playlists importiert", isPresented: $showingImportResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
    }

    private func exportAll() {
        exportDocument = PlaylistBackupDocument(data: app.library.makeBackupData() ?? Data())
        showingExporter = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let outcome = try? app.library.importBackup(data) else {
            importMessage = String(localized: "Import fehlgeschlagen.")
            showingImportResult = true
            return
        }
        if outcome.created == 0 {
            importMessage = String(localized: "Diese Playlists sind bereits vorhanden.")
        } else {
            importMessage = String(localized: "\(outcome.created) Playlists importiert, \(outcome.placeholders) Titel noch nicht in der Mediathek.")
        }
        showingImportResult = true
    }

    // MARK: - Header

    private var playlistsHeader: some View {
        HStack(spacing: 10) {
            Text("Playlists")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.white)
            Spacer()
            if isReordering {
                Button { withAnimation { isReordering = false } } label: {
                    Text("Fertig")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            } else {
                #if os(iOS) || os(visionOS)
                if playlists.count >= 2 {
                    Button { withAnimation { isReordering = true } } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                            .glassEffect(.regular, in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                #endif
                Menu {
                    Button { showingImporter = true } label: {
                        Label("Playlists importieren", systemImage: "square.and.arrow.down")
                    }
                    if !playlists.isEmpty {
                        Button { exportAll() } label: {
                            Label("Playlists exportieren", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                        .glassEffect(.regular, in: .circle)
                }
                .menuIndicator(.hidden)
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    private var hasGenres: Bool {
        allTracks.contains { !($0.genre?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
    }
    private var hasYears: Bool {
        allTracks.contains { $0.year != nil }
    }

    @ViewBuilder
    private var playlistsContent: some View {
        if isReordering {
            reorderList
        } else {
            let map = validEntryTrackMap(allTracks)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if smartPlaylistsEnabled {
                        SmartPlaylistsSection(hasGenres: hasGenres, hasYears: hasYears)
                            .padding(.top, 8)
                    }

                    Text("Deine Playlists")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.35)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                        .padding(.bottom, 12)

                    if playlists.isEmpty {
                        playlistsEmptyHint
                    } else {
                        LazyVGrid(columns: lumaGalleryColumns(spacing: 18), spacing: 22) {
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
                    }
                }
                .padding(.bottom, 20)
            }
            .lumaScrollClearance(playerActive: app.player.isActive)
        }
    }

    // MARK: - Reorder

    /// Drag-to-reorder mode: the gallery collapses to a compact list with active edit
    /// handles, so playlists can be dragged into a custom order. Order is persisted to
    /// `Playlist.sortIndex` on every move.
    private var reorderList: some View {
        let map = validEntryTrackMap(allTracks)
        return List {
            ForEach(playlists) { playlist in
                HStack(spacing: 12) {
                    PlaylistArtworkView(tracks: playlist.safeSortedTracks(using: map), cornerRadius: 8)
                        .frame(width: 46, height: 46)
                    Text(playlist.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 16))
            }
            .onMove(perform: movePlaylists)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(iOS) || os(visionOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .lumaScrollClearance(playerActive: app.player.isActive)
    }

    private func movePlaylists(from source: IndexSet, to destination: Int) {
        var ordered = playlists
        ordered.move(fromOffsets: source, toOffset: destination)
        try? app.library.reorderPlaylists(ordered)
    }

    private var playlistsEmptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.18))
            Text("Keine Playlists")
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.4))
            Text("Tippe auf + um deine erste Playlist zu erstellen.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 40)
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

    /// The first four DISTINCT albums in playlist order, de-duplicated by album identity (not
    /// artwork bytes) so four songs from the same album don't repeat a tile. Crucially this
    /// touches only the (cheap, externalStorage-free) Album rows — it does NOT read
    /// `artworkData` here. The multi-MB blob is faulted lazily by ArtworkView's autoclosure,
    /// only on a cache miss and off the card-build/scroll frame. (Reading the blob eagerly here
    /// faulted it on the main thread for every card as it scrolled into view.)
    private var coverAlbums: [Album] {
        var result: [Album] = []
        var seenAlbums = Set<PersistentIdentifier>()
        for track in tracks {
            guard let album = track.album else { continue }
            guard seenAlbums.insert(album.persistentModelID).inserted else { continue }
            result.append(album)
            if result.count == 4 { break }
        }
        return result
    }

    var body: some View {
        let albums = coverAlbums
        Group {
            if albums.count >= 4 {
                GeometryReader { geo in
                    let half = (geo.size.width - 2) / 2
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            ArtworkView(data: albums[0].artworkData, cacheKey: albums[0].id.uuidString, cornerRadius: 0, size: half)
                            ArtworkView(data: albums[1].artworkData, cacheKey: albums[1].id.uuidString, cornerRadius: 0, size: half)
                        }
                        HStack(spacing: 2) {
                            ArtworkView(data: albums[2].artworkData, cacheKey: albums[2].id.uuidString, cornerRadius: 0, size: half)
                            ArtworkView(data: albums[3].artworkData, cacheKey: albums[3].id.uuidString, cornerRadius: 0, size: half)
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ArtworkView(data: albums.first?.artworkData, cacheKey: albums.first?.id.uuidString, cornerRadius: cornerRadius, size: nil)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
