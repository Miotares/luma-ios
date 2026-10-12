import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(AppContainer.self) private var app
    @State private var query = ""
    // Prefetch `album` so the result TrackRows don't fault it per-row on the main thread.
    @Query(tracksRowDescriptor(sortByTitle: true, prefetchEntries: false)) private var allTracks: [Track]
    @Query(albumsRowDescriptor()) private var allAlbums: [Album]
    @Query(artistsRowDescriptor()) private var allArtists: [Artist]
    @Query(sort: \Playlist.sortIndex) private var allPlaylists: [Playlist]

    @FocusState private var searchFocused: Bool

    // Debounced results, recomputed off the query via .task(id:) instead of three computed
    // getters that each re-scanned the whole library on every keystroke AND every re-render.
    @State private var filteredTracks: [Track] = []
    @State private var filteredAlbums: [Album] = []
    @State private var filteredArtists: [Artist] = []
    @State private var filteredPlaylists: [Playlist] = []

    /// Case- AND diacritic-insensitive fold, so "joao"/"jose" match "João"/"José".
    private func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Runs the filter. The query path debounces (`.task(id:)` cancels the prior run, so the sleep
    /// both debounces typing and prevents overlapping full-library scans). The data path
    /// (`debounce: false`) re-filters IMMEDIATELY when the library changes, so deleting/importing/
    /// editing a track refreshes the snapshot at once — otherwise a deleted row lingered and tapping
    /// it played a dangling SwiftData object (crash), and new items didn't appear until a keystroke.
    private func runSearch(debounce: Bool = true) async {
        let q = norm(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else {
            filteredTracks = []; filteredAlbums = []; filteredArtists = []; filteredPlaylists = []
            return
        }
        if debounce {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        filteredTracks = allTracks.filter {
            norm($0.title).contains(q) ||
            norm($0.artistName).contains(q) ||
            norm($0.albumTitle).contains(q)
        }
        filteredAlbums = allAlbums.filter {
            norm($0.title).contains(q) ||
            norm($0.artistName).contains(q)
        }
        filteredArtists = allArtists.filter { norm($0.name).contains(q) }
        filteredPlaylists = allPlaylists.filter { norm($0.name).contains(q) }
    }

    private var hasResults: Bool {
        !filteredTracks.isEmpty || !filteredAlbums.isEmpty || !filteredArtists.isEmpty || !filteredPlaylists.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS) || os(visionOS)
            searchHeader
            #elseif os(macOS)
            // macOS gets a prominent in-content search bar (not the tiny toolbar field) so the
            // search surface reads as a real page with its results laid out below it.
            macSearchHeader
            #endif
            searchContent
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        .task(id: query) { await runSearch() }
        // Re-filter (no debounce) when the underlying library changes, so results never hold a
        // deleted/dangling track and newly imported or edited items appear without a keystroke.
        .onChange(of: allTracks) { Task { await runSearch(debounce: false) } }
        .onChange(of: allAlbums) { Task { await runSearch(debounce: false) } }
        .onChange(of: allArtists) { Task { await runSearch(debounce: false) } }
        .onChange(of: allPlaylists) { Task { await runSearch(debounce: false) } }
    }

    // MARK: - Header

    private var searchHeader: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Suchen")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.lumaInk())
                Spacer()
            }
            .padding(.horizontal, 20)

            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.lumaInk(0.35))
                    .font(.system(size: 15))
                TextField("Titel, Künstler, Alben, Playlists", text: $query)
                    .font(.system(size: 16))
                    .foregroundStyle(.lumaInk())
                    .tint(Color.lumaAccent)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.lumaInk(0.35))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suche löschen")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.lumaInk(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.horizontal, 16)
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    #if os(macOS)
    /// macOS in-content search bar: a large title + a prominent rounded field with a focus ring,
    /// auto-focused on appear so the user can type immediately. Replaces the toolbar `.searchable`.
    private var macSearchHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suchen")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.lumaInk())
                .padding(.horizontal, 24)

            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.lumaInk(0.4))
                    .font(.system(size: 16, weight: .medium))
                TextField("Titel, Künstler, Alben, Playlists", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(.lumaInk())
                    .tint(Color.lumaAccent)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.lumaInk(0.4))
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suche löschen")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color.lumaInk(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(searchFocused ? Color.lumaAccent.opacity(0.55) : .lumaInk(0.08),
                                  lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
        .padding(.top, 26)
        .padding(.bottom, 16)
        .onAppear { searchFocused = true }
    }
    #endif

    // MARK: - Content

    @ViewBuilder
    private var searchContent: some View {
        if query.isEmpty {
            emptyPrompt
        } else if !hasResults {
            noResults
        } else {
            results
        }
    }

    private var emptyPrompt: some View {
        VStack {
            Spacer()
            LumaEmptyState(icon: "magnifyingglass", title: "Suche nach Musik",
                           subtitle: "Songs, Künstler, Alben oder Playlists eingeben.")
            Spacer()
        }
    }

    private var noResults: some View {
        VStack {
            Spacer()
            LumaEmptyState(icon: "questionmark.circle", title: "Keine Ergebnisse",
                           subtitle: "Keine Treffer für \"\(query)\"")
            Spacer()
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                if !filteredArtists.isEmpty {
                    resultSectionHeader("Künstler")
                    ForEach(filteredArtists) { artist in
                        NavigationLink(value: artist) {
                            HStack(spacing: 12) {
                                ArtworkView(data: artist.sortedAlbums.first?.artworkData, cacheKey: artist.sortedAlbums.first?.artworkCacheKey, cornerRadius: 22, size: 44)
                                Text(artist.name).font(.body).foregroundStyle(.lumaInk())
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.lumaInk(0.25))
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 58)
                        }
                        .buttonStyle(LumaRowStyle())
                        LumaSeparator(leadingPad: 76)
                    }
                }

                if !filteredPlaylists.isEmpty {
                    resultSectionHeader("Playlists")
                    ForEach(filteredPlaylists) { playlist in
                        NavigationLink(value: playlist) {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.lumaInk(0.08))
                                    .frame(width: 48, height: 48)
                                    .overlay {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(.lumaInk(0.5))
                                    }
                                Text(playlist.name).font(.body).foregroundStyle(.lumaInk()).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.lumaInk(0.25))
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 62)
                        }
                        .buttonStyle(LumaRowStyle())
                        LumaSeparator(leadingPad: 80)
                    }
                }

                if !filteredAlbums.isEmpty {
                    resultSectionHeader("Alben")
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(data: album.artworkData, cacheKey: album.artworkCacheKey, cornerRadius: 8, size: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.title).font(.body.weight(.medium)).foregroundStyle(.lumaInk()).lineLimit(1)
                                    Text(album.artistName).font(.caption).foregroundStyle(.lumaInk(0.5))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.lumaInk(0.25))
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 62)
                        }
                        .buttonStyle(LumaRowStyle())
                        LumaSeparator(leadingPad: 80)
                    }
                }

                if !filteredTracks.isEmpty {
                    resultSectionHeader("Songs")
                    ForEach(filteredTracks) { track in
                        TrackRow(track: track, showArtwork: true, showsMenu: true,
                                 isCurrent: track.id == app.player.currentTrack?.id,
                                 isPlaying: track.id == app.player.currentTrack?.id && app.player.state.isPlaying, liked: track.isLiked,
                                 onTap: {
                            guard let idx = filteredTracks.firstIndex(where: { $0.id == track.id }) else { return }
                            app.queue.setQueue(filteredTracks, startAt: idx)
                            Task { await app.player.play(track: track) }
                        })
                        .equatable()
                        .padding(.horizontal, 16)
                        .lumaSongRowMinHeight(60)
                        LumaSeparator()
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .lumaScrollClearance(playerActive: app.player.isActive)
    }

    private func resultSectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.lumaInk(0.45))
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
