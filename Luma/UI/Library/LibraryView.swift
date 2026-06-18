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

struct LibraryView: View {
    @Environment(AppContainer.self) private var app
    var resetSignal: Int = 0

    @Query(sort: \Album.title)                        private var allAlbums: [Album]
    @Query(sort: \Artist.name)                        private var allArtists: [Artist]
    @Query(sort: \Track.title)                        private var allTracks: [Track]
    @Query(sort: \Track.addedDate, order: .reverse)   private var recentTracks: [Track]

    @State private var filter: LibraryFilter = .albums
    @State private var albumSort: AlbumSort  = .title
    @State private var albumLayout: AlbumLayout = .gallery

    private var sortedAlbums: [Album] {
        switch albumSort {
        case .title:     return allAlbums.sorted { lumaTitleBefore($0.title, $1.title) }
        case .artist:    return allAlbums.sorted { lumaTitleBefore($0.artistName, $1.artistName) }
        case .year:      return allAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .dateAdded: return allAlbums.sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    private var sortedArtists: [Artist] {
        allArtists.sorted { lumaTitleBefore($0.name, $1.name) }
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

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            filterBar
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
        #if os(macOS)
        // Clip to the detail column so the horizontal "recently added" carousel can't
        // overscroll out under the translucent sidebar.
        .clipped()
        #endif
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        .onChange(of: resetSignal) { _, _ in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { filter = .albums }
        }
    }

    // MARK: - Custom Header

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Mediathek")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.white)
            Spacer()
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
                            .foregroundStyle(isActive ? .white : Color.white.opacity(0.4))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                isActive ? Color.white.opacity(0.14) : Color.clear,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        isActive ? Color.white.opacity(0.18) : Color.clear,
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
        switch filter {
        case .albums:  albumsContent
        case .artists: artistsContent
        case .songs:   songsContent
        case .liked:   likedContent
        }
    }

    // MARK: Albums

    private var albumsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !recentlyAddedAlbums.isEmpty {
                    recentlyAddedSection
                        .padding(.top, 28)
                }
                allAlbumsSection
                    .padding(.top, 28)
            }
            .padding(.bottom, 20)
        }
        .lumaScrollClearance(playerActive: app.player.state.isActive)
    }

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Zuletzt hinzugefügt")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.35)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(recentlyAddedAlbums) { album in
                        NavigationLink(value: album) {
                            LibraryAlbumCard(album: album, cardWidth: 116)
                        }
                        .buttonStyle(.plain)
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
                Text("Alle Alben (\(allAlbums.count))")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(.white)
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
                        albumLayout = albumLayout == .gallery ? .list : .gallery
                    }
                } label: {
                    smallIconButton(albumLayout == .gallery ? "list.bullet" : "square.grid.2x2")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            if allAlbums.isEmpty {
                emptyHint(
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
                LumaSeparator(leadingPad: 88)
            }
        }
    }

    private func smallIconButton(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.08), in: Circle())
    }

    // MARK: Artists

    private var artistsContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if allArtists.isEmpty {
                    emptyHint(icon: "music.microphone", text: "Keine Künstler", sub: "Importiere Musik um Künstler zu sehen.")
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
        .lumaScrollClearance(playerActive: app.player.state.isActive, top: 20)
    }

    // MARK: Songs

    private var songsContent: some View {
        Group {
            if allTracks.isEmpty {
                ScrollView {
                    emptyHint(icon: "music.note", text: "Keine Songs", sub: "Importiere Musik um Songs zu sehen.")
                        .padding(.top, 60)
                }
            } else {
                List {
                    PlayShuffleHeader(tracks: sortedSongs)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                    ForEach(sortedSongs) { track in
                        TrackRow(track: track, showArtwork: true, showsMenu: true) { playSong(track) }
                            .frame(minHeight: 56)
                            .listRowBackground(Color.clear)
                            .trackRowSeparator()
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .trackQueueSwipeTrailing(
                                playNext: { app.queue.playNext([track]) },
                                addLast: { app.queue.append([track]) }
                            )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .lumaScrollClearance(playerActive: app.player.state.isActive, top: 20)
            }
        }
    }

    /// Flat list: album tracks stay contiguous and in track-number order, but with
    /// no album section headers — just one continuous list.
    private var sortedSongs: [Track] {
        allTracks.sorted { a, b in
            let albumA = a.album?.title ?? a.albumTitle
            let albumB = b.album?.title ?? b.albumTitle
            if albumA != albumB {
                return albumA.localizedStandardCompare(albumB) == .orderedAscending
            }
            let artistA = a.album?.artistName ?? a.artistName
            let artistB = b.album?.artistName ?? b.artistName
            if artistA != artistB {
                return artistA.localizedStandardCompare(artistB) == .orderedAscending
            }
            if a.discNumber != b.discNumber { return a.discNumber < b.discNumber }
            if a.trackNumber != b.trackNumber { return a.trackNumber < b.trackNumber }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private func playSong(_ track: Track) {
        let list = sortedSongs
        guard let idx = list.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(list, startAt: idx)
        Task { await app.player.play(track: track) }
    }

    // MARK: Liked

    private var likedContent: some View {
        LikedSongsView()
    }

    // MARK: - Helpers

    private func emptyHint(icon: String, text: LocalizedStringKey, sub: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text(text)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.4))
            Text(sub)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }

    private func play(track: Track) {
        guard let idx = allTracks.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(allTracks, startAt: idx)
        Task { await app.player.play(track: track) }
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
        }
    }

    private func button(_ label: LocalizedStringKey, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.25)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primary ? Color.lumaAccent : Color.white.opacity(0.1))
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(primary ? .black : .white)
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
            ArtworkView(data: artist.sortedAlbums.first?.artworkData, cornerRadius: 26, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                let a = artist.albumCount, t = artist.trackCount
                Text(verbatim: "\(CountText.albums(a)) · \(CountText.songs(t))")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.25))
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
            ArtworkView(data: album.artworkData, cornerRadius: 8, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(album.artistName + (album.year.map { " · \($0)" } ?? ""))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.25))
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
                ArtworkView(data: album.artworkData, cornerRadius: 14, size: w)
            } else {
                ArtworkView(data: album.artworkData, cornerRadius: 14, size: nil)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: cardWidth != nil ? 12 : 13, weight: .medium))
                    .tracking(cardWidth != nil ? 0 : -0.2)
                    .foregroundStyle(cardWidth != nil ? Color.white.opacity(0.88) : .white)
                    .lineLimit(1)
                Text(album.artistName)
                    .font(.system(size: cardWidth != nil ? 11 : 12))
                    .foregroundStyle(.white.opacity(cardWidth != nil ? 0.4 : 0.42))
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
    @Query(
        filter: #Predicate<Track> { $0.isLiked == true },
        sort: \Track.title
    ) private var liked: [Track]

    var body: some View {
        if liked.isEmpty {
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "heart")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.2))
                    Text("Keine Liked Songs")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Songs die du magst erscheinen hier.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.25))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            }
        } else {
            List {
                PlayShuffleHeader(tracks: liked)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                ForEach(liked) { track in
                    TrackRow(track: track, showArtwork: true, showsMenu: true) {
                        guard let idx = liked.firstIndex(where: { $0.id == track.id }) else { return }
                        app.queue.setQueue(liked, startAt: idx)
                        Task { await app.player.play(track: track) }
                    }
                    .frame(minHeight: 56)
                    .listRowBackground(Color.clear)
                    .trackRowSeparator()
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .trackQueueSwipeTrailing(
                        playNext: { app.queue.playNext([track]) },
                        addLast: { app.queue.append([track]) }
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .lumaScrollClearance(playerActive: app.player.state.isActive, top: 20)
        }
    }
}

