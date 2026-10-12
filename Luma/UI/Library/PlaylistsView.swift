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
/// in-memory pass. Covers are files (`ArtworkStorage`), so prefetching `album` pulls only the
/// small Album rows.
func tracksRowDescriptor(sortByTitle: Bool = false, prefetchEntries: Bool = true) -> FetchDescriptor<Track> {
    var d = FetchDescriptor<Track>(sortBy: sortByTitle ? [SortDescriptor(\.title)] : [])
    d.relationshipKeyPathsForPrefetching = prefetchEntries ? [\.album, \.playlistEntries] : [\.album]
    return d
}

/// All albums for LIST surfaces (grid, search, pickers) — the scalar columns only.
///
/// Covers used to sit INSIDE the album table (the legacy `artworkData` attribute: 21 MB for a real
/// 119-album library), so a plain `@Query<Album>` read all of them on every fetch and on every
/// refresh after a save (140–180 ms each, per query). They are files now, but a library that has
/// not finished moving them (`LibraryRepository.moveArtworkToFilesIfNeeded`) still carries the
/// blobs, so the list keeps naming just the columns it shows.
func albumsRowDescriptor() -> FetchDescriptor<Album> {
    var d = FetchDescriptor<Album>(sortBy: [SortDescriptor(\.title)])
    d.propertiesToFetch = [\.id, \.title, \.artistName, \.year, \.genre, \.artworkVersion]
    return d
}

/// Only the tracks that sit in at least one playlist, with the two relationships the playlist
/// surfaces walk prefetched. This is what `validEntryTrackMap` actually needs: a track without
/// entries contributes nothing to the map. Feeding the map from the WHOLE table instead cost a
/// 36–62 ms main-thread fetch (2k-track library) every time a playlist surface was (re)created or
/// a save republished its @Query — for a result that only ever involves the playlist's own tracks.
func playlistTracksDescriptor() -> FetchDescriptor<Track> {
    var d = FetchDescriptor<Track>(predicate: #Predicate { !$0.playlistEntries.isEmpty })
    d.relationshipKeyPathsForPrefetching = [\.album, \.playlistEntries]
    return d
}

/// Artist fetch that prefetches `albums`, which every artist row reads
/// (`sortedAlbums.first?.coverData`, `albumCount`). `tracks` is prefetched only on request:
/// prefetching it materializes EVERY track of EVERY artist (36 ms for 76 artists / 2k tracks, vs
/// 4 ms without) just so a row can show `trackCount` — which a row gets far cheaper by faulting
/// its own to-many (~0.03 ms, only for rows that actually appear). Pass `prefetchTracks: true`
/// where the tracks themselves are walked for every artist (Statistics' listening-time ranking).
func artistsRowDescriptor(prefetchTracks: Bool = false) -> FetchDescriptor<Artist> {
    var d = FetchDescriptor<Artist>(sortBy: [SortDescriptor(\.name)])
    d.relationshipKeyPathsForPrefetching = prefetchTracks ? [\.albums, \.tracks] : [\.albums]
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
    /// Tracks that are in some playlist — all the entry→track map needs (see the descriptor).
    @Query(playlistTracksDescriptor()) private var playlistTracks: [Track]
    /// One-row probes: "does ANY track carry a genre / a year?" gates the Genre / Decade smart
    /// tiles. Asked as LIMIT-1 queries so answering it doesn't load the whole tracks table.
    @Query(PlaylistsView.anyGenreDescriptor) private var genreProbe: [Track]
    @Query(PlaylistsView.anyYearDescriptor) private var yearProbe: [Track]
    @State private var showingCreate = false
    @State private var newPlaylistName = ""
    @State private var isReordering = false
    @AppStorage(SmartSectionKind.masterKey) private var smartPlaylistsEnabled = true
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportDocument: PlaylistBackupDocument?
    @State private var showingImportResult = false
    @State private var importMessage = ""
    /// Non-nil while the cover editor is presented for a specific playlist (from the gallery
    /// context menu).

    private static let anyGenreDescriptor: FetchDescriptor<Track> = {
        var d = FetchDescriptor<Track>(predicate: #Predicate { $0.genre != nil && $0.genre != "" })
        d.fetchLimit = 1
        return d
    }()

    private static let anyYearDescriptor: FetchDescriptor<Track> = {
        var d = FetchDescriptor<Track>(predicate: #Predicate { $0.year != nil })
        d.fetchLimit = 1
        return d
    }()

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
                .foregroundStyle(.lumaInk())
            Spacer()
            if isReordering {
                Button { withAnimation { isReordering = false } } label: {
                    Text("Fertig")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.lumaInk())
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .contentShape(Rectangle())
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            } else {
                // Reorder mode opens the compact list; on macOS its `.onMove` rows reorder by
                // mouse drag (no edit mode), on iOS via the active edit handles.
                if playlists.count >= 2 {
                    Button { withAnimation { isReordering = true } } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.lumaInk())
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                            .glassEffect(.regular, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Reihenfolge ändern")
                }
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
                        .foregroundStyle(.lumaInk())
                        #if os(iOS) || os(visionOS)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                        .glassEffect(.regular, in: .circle)
                        #endif
                }
                .menuIndicator(.hidden)
                #if os(macOS)
                // A macOS Menu defaults to the bordered pop-up-button style, which draws a small
                // gray pill AROUND the label — so the "…" looked tiny and boxy next to the round
                // ⇅ / + buttons. Borderless removes that chrome; then the glass circle is put on
                // the MENU itself (not the label): a .glassEffect label carries no layout footprint,
                // so it collapsed to the bare glyph. Framing + glassing the menu gives a real 38×38
                // round button matching the ⇅ / + Buttons beside it.
                .menuStyle(.borderlessButton)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
                .glassEffect(.regular, in: .circle)
                #endif
                Button { showingCreate = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.lumaInk())
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

    private var hasGenres: Bool { !genreProbe.isEmpty }
    private var hasYears: Bool { !yearProbe.isEmpty }

    @ViewBuilder
    private var playlistsContent: some View {
        if isReordering {
            reorderList
        } else {
            let map = validEntryTrackMap(playlistTracks)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if smartPlaylistsEnabled {
                        SmartPlaylistsSection(hasGenres: hasGenres, hasYears: hasYears)
                            .padding(.top, 8)
                    }

                    Text("Deine Playlists")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.35)
                        .foregroundStyle(.lumaInk())
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
                                        .contentShape(Rectangle())
                                        .playlistContextMenu(playlist)
                                }
                                .buttonStyle(.plain)
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
        let map = validEntryTrackMap(playlistTracks)
        return List {
            ForEach(playlists) { playlist in
                HStack(spacing: 12) {
                    PlaylistArtworkView(playlist: playlist, tracks: playlist.safeSortedTracks(using: map), cornerRadius: 8)
                        .frame(width: 46, height: 46)
                    Text(playlist.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.lumaInk())
                        .lineLimit(1)
                    Spacer()
                    #if os(macOS)
                    // macOS has no edit-mode reorder handles, so the rows looked static even though
                    // they drag. A trailing grab handle signals that the row can be dragged to
                    // reorder (the whole row is draggable via .onMove; this is the visual cue).
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.lumaInk(0.3))
                        .accessibilityHidden(true)
                    #endif
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
        LumaEmptyState(icon: "music.note.list", title: "Keine Playlists",
                       subtitle: "Tippe auf + um deine erste Playlist zu erstellen.")
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
            PlaylistArtworkView(playlist: playlist, tracks: tracks)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(.lumaInk())
                    .lineLimit(1)
                Text(CountText.songs(tracks.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.lumaInk(0.42))
                    .lineLimit(1)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Playlist cover. Renders one of three styles per `playlist.coverStyle`:
///   • `.mosaic` (default) — a 2×2 grid of the first four tracks' artwork (or a single cover when
///     there are fewer than four). Updates automatically as tracks change.
///   • `.photo` — the user's on-device image.
///   • `.generated` — an app-rendered pattern (see `GeneratedCoverView`).
///
/// The style is read from the cheap scalar `coverStyleRaw`, so deciding which branch to render
/// never faults the externalStorage photo blob — that's loaded lazily by `ArtworkView` only when
/// the `.photo` branch is actually shown. `playlist` is optional so a caller (e.g. the editor's
/// Mosaik preview) can force a plain mosaic from `tracks` alone by passing nil.
struct PlaylistArtworkView: View {
    var playlist: Playlist?
    let tracks: [Track]
    var cornerRadius: CGFloat = 14
    @Environment(\.coverCornerScale) private var coverCornerScale

    var body: some View {
        switch playlist?.coverStyle ?? .mosaic {
        case .mosaic:
            mosaic
        case .photo:
            // The data: argument is an autoclosure — `playlist?.customArtworkData` is NOT read
            // here, only inside ArtworkView's .task on a cache miss. The cache key carries
            // `coverVersion` so a replaced photo invalidates the decoded-image cache. `maxPixel`
            // caps the decode at 512px (matching the album gallery card): this view fills cards
            // as small as a 2-column gallery tile, and the stored photo is ~1024px, so decoding
            // it full would cache a ~4 MB bitmap per card on the busiest scroll surface.
            ArtworkView(data: playlist?.customArtworkData, cacheKey: photoCacheKey,
                        cornerRadius: cornerRadius, size: nil, maxPixel: 512)
                .aspectRatio(1, contentMode: .fit)
        case .generated:
            GeneratedCoverView(config: playlist?.generatedConfigValue ?? .default,
                               title: playlist?.name, cornerRadius: cornerRadius)
                .aspectRatio(1, contentMode: .fit)
        }
    }

    private var photoCacheKey: String? {
        guard let playlist else { return nil }
        return "plcover-\(playlist.id.uuidString)-\(playlist.coverVersion)"
    }

    /// The first four DISTINCT albums in playlist order, de-duplicated by album identity (not
    /// artwork bytes) so four songs from the same album don't repeat a tile. Crucially this
    /// touches only the (cheap) Album rows — it does NOT read the cover here. That is read lazily
    /// by ArtworkView's autoclosure, only on a cache miss and off the card-build/scroll frame.
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

    @ViewBuilder
    private var mosaic: some View {
        let albums = coverAlbums
        if albums.count >= 4 {
            GeometryReader { geo in
                let half = (geo.size.width - 2) / 2
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        ArtworkView(data: albums[0].coverData, cacheKey: albums[0].artworkCacheKey, cornerRadius: 0, size: half)
                        ArtworkView(data: albums[1].coverData, cacheKey: albums[1].artworkCacheKey, cornerRadius: 0, size: half)
                    }
                    HStack(spacing: 2) {
                        ArtworkView(data: albums[2].coverData, cacheKey: albums[2].artworkCacheKey, cornerRadius: 0, size: half)
                        ArtworkView(data: albums[3].coverData, cacheKey: albums[3].artworkCacheKey, cornerRadius: 0, size: half)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius * coverCornerScale, style: .continuous))
        } else {
            // Single distinct album → one cover fills the tile. macOS caps the decode below the
            // stored ~1024px (the 220pt detail header @2x ≈ 440px, so 512 stays crisp) instead of
            // caching a ~4 MB full bitmap per surface. iOS keeps the default (nil = full-res), so
            // its denser @3x header is unchanged — same `@full` cache bucket as before.
            #if os(macOS)
            let fallbackMax: Int? = 512
            #else
            let fallbackMax: Int? = nil
            #endif
            ArtworkView(data: albums.first?.coverData, cacheKey: albums.first?.artworkCacheKey,
                        cornerRadius: cornerRadius, size: nil, maxPixel: fallbackMax)
                .aspectRatio(1, contentMode: .fit)
        }
    }
}
