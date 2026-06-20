import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(AppContainer.self) private var app
    @State private var query = ""
    @Query(sort: \Track.title)  private var allTracks: [Track]
    @Query(sort: \Album.title)  private var allAlbums: [Album]
    @Query(sort: \Artist.name)  private var allArtists: [Artist]

    @FocusState private var searchFocused: Bool

    // Debounced results, recomputed off the query via .task(id:) instead of three computed
    // getters that each re-scanned the whole library on every keystroke AND every re-render.
    @State private var filteredTracks: [Track] = []
    @State private var filteredAlbums: [Album] = []
    @State private var filteredArtists: [Artist] = []

    /// Runs the (debounced) filter whenever the query changes. `.task(id:)` cancels the prior
    /// run, so the sleep both debounces typing and prevents overlapping full-library scans.
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            filteredTracks = []; filteredAlbums = []; filteredArtists = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        filteredTracks = allTracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artistName.lowercased().contains(q) ||
            $0.albumTitle.lowercased().contains(q)
        }
        filteredAlbums = allAlbums.filter {
            $0.title.lowercased().contains(q) ||
            $0.artistName.lowercased().contains(q)
        }
        filteredArtists = allArtists.filter { $0.name.lowercased().contains(q) }
    }

    private var hasResults: Bool {
        !filteredTracks.isEmpty || !filteredAlbums.isEmpty || !filteredArtists.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            searchContent
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        .task(id: query) { await runSearch() }
    }

    // MARK: - Header

    private var searchHeader: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Suchen")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 20)

            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.35))
                    .font(.system(size: 15))
                TextField("Titel, Künstler, Alben", text: $query)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .tint(Color.lumaAccent)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.horizontal, 16)
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

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
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.15))
            Text("Suche nach Musik")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.35))
            Text("Songs, Künstler oder Alben eingeben.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.2))
            Spacer()
        }
    }

    private var noResults: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(.system(size: 52))
                .foregroundStyle(.white.opacity(0.15))
            Text("Keine Ergebnisse")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.35))
            Text("Keine Treffer für \"\(query)\"")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.2))
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
                                ArtworkView(data: artist.sortedAlbums.first?.artworkData, cacheKey: artist.sortedAlbums.first?.id.uuidString, cornerRadius: 22, size: 44)
                                Text(artist.name).font(.body).foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 58)
                        }
                        .buttonStyle(LumaRowStyle())
                        LumaSeparator(leadingPad: 76)
                    }
                }

                if !filteredAlbums.isEmpty {
                    resultSectionHeader("Alben")
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            HStack(spacing: 12) {
                                ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 8, size: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.title).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                                    Text(album.artistName).font(.caption).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.25))
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
                        TrackRow(track: track, showArtwork: true, showsMenu: true) {
                            guard let idx = filteredTracks.firstIndex(where: { $0.id == track.id }) else { return }
                            app.queue.setQueue(filteredTracks, startAt: idx)
                            Task { await app.player.play(track: track) }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 60)
                        LumaSeparator()
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .lumaScrollClearance(playerActive: app.player.state.isActive)
    }

    private func resultSectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
