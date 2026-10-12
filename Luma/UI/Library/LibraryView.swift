import SwiftUI
import SwiftData

enum LibraryFilter: String, CaseIterable {
    case albums  = "Alben"
    case artists = "Künstler"
    case songs   = "Songs"
    case liked   = "Liked"

    /// Localized pill title (the raw value is the German key; `Text(rawValue)` would
    /// render verbatim and never translate).
    var displayName: String {
        switch self {
        case .albums:  return String(localized: "Alben")
        case .artists: return String(localized: "Künstler")
        case .songs:   return String(localized: "Songs")
        case .liked:   return String(localized: "Liked")
        }
    }
}

enum AlbumLayout {
    case gallery, list
}

/// Sort comparator that always starts with letters (A–Z); titles beginning with a
/// number or symbol (`"`, `.`, …) sort AFTER the whole alphabet.
func lumaTitleBefore(_ a: String, _ b: String) -> Bool {
    let aLetter = a.first?.isLetter ?? false
    let bLetter = b.first?.isLetter ?? false
    if aLetter != bLetter { return aLetter }
    return a.localizedStandardCompare(b) == .orderedAscending
}

/// The library root. It owns the chrome (header, iOS filter bar, navigation destinations) and
/// decides which page shows; the pages themselves are data-driven views (`LibraryAlbumsContent`,
/// `LibraryArtistsContent`, `LibrarySongsContent`) so the two platforms can feed them differently:
///
/// • iOS keeps every query HERE at the root. The tab stays mounted for the app's lifetime, so the
///   fetches are paid once and switching the filter pill is instant.
/// • macOS tears this view down on every sidebar section switch (`MacRootView.detail`), so
///   root-level queries were re-run each time — ~80–90 ms of main-thread fetching (2k-track
///   library) to show, say, the Alben grid, which needs none of the tracks. There each page is
///   wrapped in a small host that owns ONLY the queries that page needs (`MacLibrary…Page`).
struct LibraryView: View {
    @Environment(AppContainer.self) private var app
    #if os(macOS)
    @Environment(\.openNowPlaying) private var openNowPlaying
    /// macOS drives the library filter from the sidebar (MacRootView), not the in-view filter bar.
    @Environment(MacNavigationState.self) private var macNav
    #endif
    var resetSignal: Int = 0

    /// Bounded so the "recently added" section never re-fetches the whole tracks table
    /// (it only needs enough rows to find 12 distinct albums).
    fileprivate static let recentTracksDescriptor: FetchDescriptor<Track> = {
        var d = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.addedDate, order: .reverse)])
        d.fetchLimit = 200
        d.relationshipKeyPathsForPrefetching = [\.album]   // recentlyAddedAlbums reads track.album
        return d
    }()

    #if !os(macOS)
    @Query(sort: \Album.title)                        private var allAlbums: [Album]
    @Query(artistsRowDescriptor(prefetchTracks: true)) private var allArtists: [Artist]
    @Query(tracksRowDescriptor(sortByTitle: true))    private var allTracks: [Track]
    @Query(LibraryView.recentTracksDescriptor)        private var recentTracks: [Track]
    @Query(sort: \Playlist.sortIndex)                 private var allPlaylists: [Playlist]
    // Cached, recomputed only when `allTracks` actually changes — the locale-aware sort of the
    // whole table is far too expensive to re-run on every body eval (e.g. each play/pause).
    @State private var sortedSongs: [Track] = []
    #endif

    @State private var filter: LibraryFilter = .albums
    @State private var albumSort: AlbumSort  = .title

    /// The page to show. macOS reads the sidebar's choice DIRECTLY: mirroring it into `filter` via
    /// `.onAppear` meant the first frame after a section switch always built the Alben page, then
    /// threw it away for the real one.
    private var activeFilter: LibraryFilter {
        #if os(macOS)
        macNav.libraryFilter
        #else
        filter
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            // macOS moves these sub-sections (Alben/Künstler/Songs/Gelikte Songs) into the sidebar.
            #if os(iOS) || os(visionOS)
            filterBar
            #endif
            libraryContent
                // Soft fade where content meets the filter bar — no hard scroll edge.
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [Color.lumaBackground, Color.lumaBackground.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 22)
                    .allowsHitTesting(false)
                }
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        .onChange(of: resetSignal) { _, _ in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { filter = .albums }
        }
        #if !os(macOS)
        // Resort the Songs list off-main whenever the library actually changes (add/remove/
        // retag — not playback stats, which keep the same id-order). Runs here at the root so
        // it isn't redone on every visit to the Songs tab.
        .task(id: allTracks) {
            sortedSongs = await lumaSortSongsAsync(allTracks)
        }
        #endif
    }

    // MARK: - Custom Header

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            #if os(macOS)
            // The sidebar now names the section; mirror the selected sub-section as the title.
            Text(macNav.sidebarSelection?.title ?? "Mediathek")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.lumaInk())
            #else
            Text("Mediathek")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.lumaInk())
            #endif
            Spacer()
            #if os(macOS)
            Button { openNowPlaying() } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.lumaInk(0.7))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Warteschlange")
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryFilter.allCases, id: \.self) { f in
                    let isActive = filter == f
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                            filter = f
                        }
                    } label: {
                        Text(f.displayName)
                            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? .lumaInk() : Color.lumaInk(0.4))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                isActive ? Color.lumaInk(0.14) : Color.clear,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        isActive ? Color.lumaInk(0.18) : Color.clear,
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: filter)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 2)
        }
    }

    // MARK: - Content Switching

    @ViewBuilder
    private var libraryContent: some View {
        #if os(macOS)
        switch activeFilter {
        case .albums:  MacLibraryAlbumsPage(albumSort: $albumSort)
        case .artists: MacLibraryArtistsPage()
        case .songs:   MacLibrarySongsPage(cache: app.songOrder)
        case .liked:   LikedSongsView()
        }
        #else
        switch activeFilter {
        case .albums:
            // `allTracks` is already loaded here, so the pinned-playlist covers resolve from it.
            LibraryAlbumsContent(albums: allAlbums, recentTracks: recentTracks, playlists: allPlaylists,
                                 playlistTracks: allTracks, albumSort: $albumSort)
        case .artists:
            LibraryArtistsContent(artists: allArtists)
        case .songs:
            LibrarySongsContent(tracks: allTracks, sortedSongs: sortedSongs)
        case .liked:
            LikedSongsView()
        }
        #endif
    }
}

// MARK: - macOS page hosts (each owns only its own queries)

#if os(macOS)
private struct MacLibraryAlbumsPage: View {
    @Query(sort: \Album.title)                 private var albums: [Album]
    @Query(LibraryView.recentTracksDescriptor) private var recentTracks: [Track]
    @Query(sort: \Playlist.sortIndex)          private var playlists: [Playlist]
    /// Only the tracks that sit in a playlist — enough to resolve the pinned playlists' covers.
    @Query(playlistTracksDescriptor())         private var playlistTracks: [Track]
    @Binding var albumSort: AlbumSort

    var body: some View {
        LibraryAlbumsContent(albums: albums, recentTracks: recentTracks, playlists: playlists,
                             playlistTracks: playlistTracks, albumSort: $albumSort)
    }
}

private struct MacLibraryArtistsPage: View {
    @Query(artistsRowDescriptor()) private var artists: [Artist]

    var body: some View {
        LibraryArtistsContent(artists: artists)
    }
}

private struct MacLibrarySongsPage: View {
    // No SQL sort: the list order comes from `lumaSortSongsAsync` below, so sorting by title in
    // the store first was pure overhead. `album` is prefetched for the rows' artwork key.
    @Query(tracksRowDescriptor(prefetchEntries: false)) private var tracks: [Track]
    @State private var sortedSongs: [Track]
    private let cache: SongOrderCache

    /// Seeds the order from the last visit, so re-entering Songs after a section switch shows the
    /// list on the first frame instead of a spinner. The `.task` below still re-sorts every time
    /// (cheap, off-main) and corrects the order if the library changed meanwhile.
    init(cache: SongOrderCache) {
        self.cache = cache
        _sortedSongs = State(initialValue: cache.songs)
    }

    var body: some View {
        LibrarySongsContent(tracks: tracks, sortedSongs: sortedSongs)
            .task(id: tracks) {
                let sorted = await lumaSortSongsAsync(tracks)
                guard !Task.isCancelled else { return }
                if sorted != sortedSongs { sortedSongs = sorted }
                cache.songs = sorted
            }
    }
}
#endif

/// Remembers the Songs page's sorted order across macOS section switches (the page — and its
/// @State — is destroyed each time). Holds model references only for their identity: the page
/// always filters them against the live query (`LibrarySongsContent.displaySongs`) before
/// rendering, so an entry deleted meanwhile is never shown.
final class SongOrderCache {
    var songs: [Track] = []
}

// MARK: - Albums page

struct LibraryAlbumsContent: View {
    @Environment(AppContainer.self) private var app
    let albums: [Album]
    let recentTracks: [Track]
    let playlists: [Playlist]
    /// Source for resolving the pinned playlists' tracks — any set that contains every track
    /// sitting in a playlist (the whole table on iOS, just the playlist tracks on macOS).
    let playlistTracks: [Track]
    @Binding var albumSort: AlbumSort

    @AppStorage("homeAlbumList")          private var albumAsList = false
    @AppStorage("homeShowRecentlyAdded")  private var showRecentlyAdded = true
    @AppStorage("homePinnedPlaylists")    private var pinnedData = Data()

    private var albumLayout: AlbumLayout { albumAsList ? .list : .gallery }

    private var sortedAlbums: [Album] {
        switch albumSort {
        case .title:     return albums.sorted { lumaTitleBefore($0.title, $1.title) }
        case .artist:    return albums.sorted { lumaTitleBefore($0.artistName, $1.artistName) }
        case .year:      return albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .dateAdded: return albums.sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    private var recentlyAddedAlbums: [Album] {
        var seen = Set<UUID>()
        var result: [Album] = []
        for track in recentTracks {
            guard let album = track.album else { continue }
            if seen.insert(album.id).inserted {
                result.append(album)
                if result.count >= 12 { break }
            }
        }
        return result
    }

    /// Playlists the user pinned to the home screen (Settings → Startseite), in pin order.
    private var pinnedPlaylists: [Playlist] {
        guard let ids = try? JSONDecoder().decode([UUID].self, from: pinnedData), !ids.isEmpty else { return [] }
        let byId = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    var body: some View {
        // Derived once per pass (each was previously computed twice: for the `isEmpty` test and
        // again inside its section).
        let pinned = pinnedPlaylists
        let recent = showRecentlyAdded ? recentlyAddedAlbums : []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !pinned.isEmpty {
                    pinnedSection(pinned)
                        .padding(.top, 28)
                }
                if !recent.isEmpty {
                    recentlyAddedSection(recent)
                        .padding(.top, 28)
                }
                allAlbumsSection
                    .padding(.top, 28)
            }
            .padding(.bottom, 20)
        }
        .lumaScrollClearance(playerActive: app.player.isActive)
    }

    private func pinnedSection(_ pinned: [Playlist]) -> some View {
        let map = validEntryTrackMap(playlistTracks)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Playlists")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.35)
                .foregroundStyle(.lumaInk())
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(pinned) { playlist in
                        NavigationLink(value: playlist) {
                            VStack(alignment: .leading, spacing: 0) {
                                PlaylistArtworkView(playlist: playlist, tracks: playlist.safeSortedTracks(using: map), cornerRadius: 14)
                                    .frame(width: 116, height: 116)
                                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                                Text(playlist.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.lumaInk(0.88))
                                    .lineLimit(1)
                                    .padding(.top, 7)
                                    .frame(width: 116, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
        }
    }

    private func recentlyAddedSection(_ recent: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Zuletzt hinzugefügt")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.35)
                .foregroundStyle(.lumaInk())
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recent) { album in
                        NavigationLink(value: album) {
                            LibraryAlbumCard(album: album, cardWidth: 116)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .albumContextMenu(album)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
        }
    }

    private var allAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Alle Alben (\(albums.count))")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(.lumaInk())
                Spacer()

                Menu {
                    Picker("Sortieren", selection: $albumSort) {
                        ForEach(AlbumSort.allCases) { s in
                            Label(s.label, systemImage: s.icon).tag(s)
                        }
                    }
                } label: {
                    smallIconButton("arrow.up.arrow.down")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        albumAsList.toggle()
                    }
                } label: {
                    smallIconButton(albumLayout == .gallery ? "list.bullet" : "square.grid.2x2")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            if albums.isEmpty {
                LibraryEmptyHint(
                    icon: "music.note.list",
                    text: "Keine Musik vorhanden",
                    sub: "Tippe auf + um Musik zu importieren."
                )
            } else if albumLayout == .gallery {
                albumsGrid
            } else {
                albumsList
            }
        }
    }

    private var albumsGrid: some View {
        LazyVGrid(columns: lumaGalleryColumns(spacing: 18), spacing: 18) {
            ForEach(sortedAlbums) { album in
                NavigationLink(value: album) {
                    LibraryAlbumCard(album: album, cardWidth: nil)
                }
                .buttonStyle(.plain)
                .albumContextMenu(album)
            }
        }
        .padding(.horizontal, 16)
    }

    private var albumsList: some View {
        LazyVStack(spacing: 0) {
            ForEach(sortedAlbums) { album in
                NavigationLink(value: album) {
                    AlbumListRow(album: album)
                }
                .buttonStyle(LumaRowStyle())
                .albumContextMenu(album)
                LumaSeparator(leadingPad: 88)
            }
        }
    }

    private func smallIconButton(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.lumaInk(0.75))
            .frame(width: 32, height: 32)
            .background(Color.lumaInk(0.08), in: Circle())
    }
}

// MARK: - Artists page

struct LibraryArtistsContent: View {
    @Environment(AppContainer.self) private var app
    let artists: [Artist]

    private var sortedArtists: [Artist] {
        artists.sorted { lumaTitleBefore($0.name, $1.name) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if artists.isEmpty {
                    LibraryEmptyHint(icon: "music.microphone", text: "Keine Künstler", sub: "Importiere Musik um Künstler zu sehen.")
                        .padding(.top, 60)
                }
                ForEach(sortedArtists) { artist in
                    NavigationLink(value: artist) {
                        ArtistListRow(artist: artist)
                    }
                    .buttonStyle(LumaRowStyle())
                    LumaSeparator(leadingPad: 82)
                }
            }
            .padding(.bottom, 20)
        }
        .lumaScrollClearance(playerActive: app.player.isActive, top: 20)
    }
}

// MARK: - Songs page

struct LibrarySongsContent: View {
    @Environment(AppContainer.self) private var app
    /// The live query result — the source of truth for which tracks exist.
    let tracks: [Track]
    /// The same tracks in list order (sorted off-main by the owner; may lag `tracks` briefly).
    let sortedSongs: [Track]

    /// `sortedSongs` is an asynchronously refreshed cache; right after a delete (or retag) it still
    /// holds the just-removed Track until the owner re-sorts. Filtering against the live query each
    /// body pass keeps a deleted row from being rendered — rendering it would fault its backing
    /// data ("backing data could no longer be found") and crash. Reading `persistentModelID` is
    /// safe even on a deleted model.
    private var displaySongs: [Track] {
        let liveIDs = Set(tracks.map(\.persistentModelID))
        return sortedSongs.filter { liveIDs.contains($0.persistentModelID) }
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ScrollView {
                    LibraryEmptyHint(icon: "music.note", text: "Keine Songs", sub: "Importiere Musik um Songs zu sehen.")
                        .padding(.top, 60)
                }
            } else if sortedSongs.isEmpty {
                // The (large) table is being sorted off-main — show progress, not a frozen tab.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let songs = displaySongs
                List {
                    PlayShuffleHeader(tracks: songs)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                    ForEach(songs) { track in
                        TrackRow(track: track, showArtwork: true, showsMenu: true,
                                 isCurrent: track.id == app.player.currentTrack?.id,
                                 isPlaying: track.id == app.player.currentTrack?.id && app.player.state.isPlaying, liked: track.isLiked,
                                 onTap: { playSong(track) })
                            .equatable()
                            .lumaSongRowMinHeight(48)
                            .listRowBackground(Color.clear)
                            .trackRowSeparator()
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .trackQueueSwipeTrailing(
                                playNext: { app.playNext([track]) },
                                addLast: { app.addToQueue([track]) }
                            )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // No row selection on macOS: otherwise double-click-to-play left a full-width
                // system selection highlight that bled under the translucent sidebar.
                .selectionDisabled()
                .lumaScrollClearance(playerActive: app.player.isActive, top: 20)
            }
        }
    }

    private func playSong(_ track: Track) {
        let list = displaySongs
        guard let idx = list.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(list, startAt: idx)
        Task { await app.player.play(track: track) }
    }
}

/// Lightweight, Sendable snapshot of the columns the Songs sort needs, so the expensive
/// locale-aware comparison can run OFF the main thread (Track is non-Sendable).
private struct SongSortKey: Sendable {
    /// Position in the caller's array — NOT the persistentModelID: a freshly imported track's id
    /// changes from temporary to permanent when the context saves, and a save landing during the
    /// off-main sort made every id lookup miss (empty result → the Songs tab spun forever).
    let index: Int
    let album: String, artist: String, title: String
    let disc: Int, track: Int
    // nonisolated so the comparator can run inside Task.detached (off the main actor).
    nonisolated static func before(_ a: SongSortKey, _ b: SongSortKey) -> Bool {
        if a.album != b.album { return a.album.localizedStandardCompare(b.album) == .orderedAscending }
        if a.artist != b.artist { return a.artist.localizedStandardCompare(b.artist) == .orderedAscending }
        if a.disc != b.disc { return a.disc < b.disc }
        if a.track != b.track { return a.track < b.track }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}

/// Flat list: album tracks stay contiguous and in track-number order. The locale-aware
/// sort of the whole table (~thousands of `localizedStandardCompare`) is far too slow for
/// the main thread (it froze the tab for ~2s), so snapshot Sendable keys on main, sort
/// off-main, then map back to tracks on main.
@MainActor
func lumaSortSongsAsync(_ tracks: [Track]) async -> [Track] {
    guard !tracks.isEmpty else { return [] }
    let keys = tracks.enumerated().map { index, track in
        SongSortKey(index: index, album: track.albumTitle, artist: track.artistName,
                    title: track.title, disc: track.discNumber, track: track.trackNumber)
    }
    let order = await Task.detached(priority: .userInitiated) {
        keys.sorted(by: SongSortKey.before).map(\.index)
    }.value
    return order.map { tracks[$0] }
}

// MARK: - Helpers

private struct LibraryEmptyHint: View {
    let icon: String
    let text: LocalizedStringKey
    let sub: LocalizedStringKey

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.lumaInk(0.2))
            Text(text)
                .font(.headline)
                .foregroundStyle(.lumaInk(0.4))
            Text(sub)
                .font(.subheadline)
                .foregroundStyle(.lumaInk(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }
}

// MARK: - Play / Shuffle Header

struct PlayShuffleHeader: View {
    @Environment(AppContainer.self) private var app
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 10) {
            button("Abspielen", icon: "play.fill", primary: true) { play(shuffle: false) }
            button("Shuffle", icon: "shuffle", primary: false) { play(shuffle: true) }
            #if os(macOS)
            Spacer(minLength: 0)
            #endif
        }
        #if os(macOS)
        // Cover-less lists (Songs / Liked / smart playlists) sit these buttons right under a plain
        // title instead of an album cover, so the bare row inset left them looking cramped. Give
        // real vertical breathing room above and below, and nudge the leading edge so the play
        // pill lines up with the 20pt title above it (these header rows sit at a 16pt list inset).
        .padding(.top, 14)
        .padding(.bottom, 6)
        .padding(.leading, 4)
        #endif
    }

    private func button(_ label: LocalizedStringKey, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        #if os(macOS)
        let corner: CGFloat = 9
        #else
        let corner: CGFloat = 14
        #endif
        return Button(action: action) {
            Label(label, systemImage: icon)
                #if os(macOS)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .frame(height: 32)
                #else
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.25)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                #endif
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(primary ? Color.lumaAccent : Color.lumaInk(0.1))
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(.lumaInk(0.14), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(primary ? .lumaOnAccent : .lumaInk())
        }
        .buttonStyle(.plain)
    }

    private func play(shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        let start = shuffle ? Int.random(in: 0..<tracks.count) : 0
        app.queue.setQueue(tracks, startAt: start, shuffle: shuffle)
        Task { await app.player.play(track: app.queue.currentTrack ?? tracks[start]) }
    }
}

// MARK: - Artist Row

struct ArtistListRow: View {
    let artist: Artist

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(data: artist.sortedAlbums.first?.artworkData, cacheKey: artist.sortedAlbums.first?.id.uuidString, cornerRadius: 26, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name).font(.body.weight(.semibold)).foregroundStyle(.lumaInk())
                let a = artist.albumCount, t = artist.trackCount
                Text(verbatim: "\(CountText.albums(a)) · \(CountText.songs(t))")
                    .font(.caption).foregroundStyle(.lumaInk(0.45))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.lumaInk(0.25))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
    }
}

// MARK: - Album List Row

struct AlbumListRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 8, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.lumaInk())
                    .lineLimit(1)
                Text(album.artistName + (album.year.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13))
                    .foregroundStyle(.lumaInk(0.45))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.lumaInk(0.25))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(minHeight: 70)
    }
}

// MARK: - Album Card

struct LibraryAlbumCard: View {
    let album: Album
    let cardWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let w = cardWidth {
                ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 14, size: w)
            } else {
                // size: nil → fills the grid column (responsive). maxPixel caps the DECODE at
                // ~512px so the gallery doesn't inflate full ~1024px covers for ~150 cards.
                ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 14, size: nil, maxPixel: 512)
                    .aspectRatio(1, contentMode: .fit)
                    // Cast the drop shadow from a constant rounded-rect shape behind the (opaque)
                    // cover, NOT from the image's own alpha. Same look, but the rasterizer gets a
                    // stable shadow path instead of re-deriving it from cover pixels every redraw —
                    // it adds up across the ~150 cards the macOS adaptive gallery shows at once.
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: cardWidth != nil ? 12 : 13, weight: .medium))
                    .tracking(cardWidth != nil ? 0 : -0.2)
                    .foregroundStyle(cardWidth != nil ? Color.lumaInk(0.88) : .lumaInk())
                    .lineLimit(1)
                Text(album.artistName)
                    .font(.system(size: cardWidth != nil ? 11 : 12))
                    .foregroundStyle(.lumaInk(cardWidth != nil ? 0.4 : 0.42))
                    .lineLimit(1)
            }
            .padding(.top, cardWidth != nil ? 7 : 8)
            .frame(width: cardWidth, alignment: .leading)
        }
    }
}

// MARK: - Liked Songs View

struct LikedSongsView: View {
    @Environment(AppContainer.self) private var app
    @Query(LikedSongsView.likedDescriptor) private var liked: [Track]

    /// Liked songs, with `album` prefetched so the rows don't fault it per-row while scrolling.
    static var likedDescriptor: FetchDescriptor<Track> {
        var d = FetchDescriptor<Track>(
            predicate: #Predicate { $0.isLiked == true },
            sortBy: [SortDescriptor(\.title)]
        )
        d.relationshipKeyPathsForPrefetching = [\.album]
        return d
    }

    var body: some View {
        if liked.isEmpty {
            ScrollView {
                LumaEmptyState(icon: "heart", title: "Keine Liked Songs",
                               subtitle: "Songs die du magst erscheinen hier.")
                    .padding(.vertical, 60)
            }
        } else {
            List {
                PlayShuffleHeader(tracks: liked)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                ForEach(liked) { track in
                    TrackRow(track: track, showArtwork: true, showsMenu: true,
                             isCurrent: track.id == app.player.currentTrack?.id,
                             isPlaying: track.id == app.player.currentTrack?.id && app.player.state.isPlaying, liked: track.isLiked,
                             onTap: {
                        guard let idx = liked.firstIndex(where: { $0.id == track.id }) else { return }
                        app.queue.setQueue(liked, startAt: idx)
                        Task { await app.player.play(track: track) }
                    })
                    .equatable()
                    .lumaSongRowMinHeight(56)
                    .listRowBackground(Color.clear)
                    .trackRowSeparator()
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .trackQueueSwipeTrailing(
                        playNext: { app.playNext([track]) },
                        addLast: { app.addToQueue([track]) }
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .selectionDisabled()   // no full-width selection highlight on double-click-to-play (macOS)
            .lumaScrollClearance(playerActive: app.player.isActive, top: 20)
        }
    }
}

