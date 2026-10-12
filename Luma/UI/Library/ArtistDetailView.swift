import SwiftUI
import SwiftData

struct ArtistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    let artist: Artist

    private var artworkData: Data? { artist.sortedAlbums.first?.artworkData }
    private var allTracks: [Track] { artist.sortedAlbums.flatMap { $0.sortedTracks } }

    var body: some View {
        // The artist can be deleted out from under this view: removing its last album in the
        // pushed AlbumDetailView (its onDisappear → removeAlbum → delete(track:) prunes the now
        // empty artist) saves the context, which republishes @Query and re-evaluates this body
        // while it is still mounted during the pop. Reading any attribute of the deleted artist
        // then faults ("backing data could no longer be found"). `modelContext` goes nil once the
        // model is deleted+saved and is safe to read, so guard on it and pop instead of rendering.
        Group {
            if artist.modelContext != nil {
                content
            } else {
                Color.lumaBackground.ignoresSafeArea()
            }
        }
        .onChange(of: artist.modelContext == nil) { _, deleted in
            if deleted { dismiss() }
        }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            DetailBackground(artworkData: artworkData)

            List {
                artistHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())

                ForEach(artist.sortedAlbums) { album in
                    NavigationLink(destination: AlbumDetailView(album: album)) {
                        albumNavRow(album)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 4, trailing: 16))

                    ForEach(album.sortedTracks) { track in
                        TrackRow(track: track, showArtistName: false, showsMenu: true,
                                 isCurrent: track.id == app.player.currentTrack?.id,
                                 isPlaying: track.id == app.player.currentTrack?.id && app.player.state.isPlaying, liked: track.isLiked,
                                 onTap: {
                            play(track: track, album: album)
                        })
                        .equatable()
                        .lumaSongRowMinHeight(54)
                        .listRowBackground(Color.clear)
                        .trackRowSeparator()
                        // Indented so the tracks read as nested under the album header.
                        .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 16))
                        .trackQueueSwipeTrailing(
                            playNext: { app.queue.playNext([track]) },
                            addLast: { app.queue.append([track]) }
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS) || os(visionOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .lumaScrollClearance(playerActive: app.player.isActive)

            // iOS floating back/options bar; macOS uses the native back button + the inline
            // options menu in the header.
            #if os(iOS) || os(visionOS)
            HStack {
                LumaBackButton { dismiss() }
                Spacer()
                Menu {
                    artistMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.lumaInk())
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .glassEffect(.regular, in: .circle)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            #endif
        }
        // Transparent (not hidden) bar keeps the native interactive swipe-back.
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
    }

    // MARK: - Options Menu

    @ViewBuilder
    private var artistMenu: some View {
        Button {
            app.queue.playNext(allTracks)
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.queue.append(allTracks)
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        try? app.library.addTracks(allTracks, to: playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zur Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }
    }

    // MARK: - Artist Header

    private var artistHeader: some View {
        #if os(macOS)
        macArtistHeader
        #else
        iosArtistHeader
        #endif
    }

    #if os(macOS)
    private var macArtistHeader: some View {
        HStack(alignment: .bottom, spacing: 28) {
            ArtistArtworkView(albums: Array(artist.sortedAlbums.prefix(4)))
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(artist.name)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.lumaInk())
                    .lineLimit(2)
                let a = artist.albumCount, t = artist.trackCount
                Text(verbatim: "\(CountText.albums(a)) · \(CountText.songs(t))")
                    .font(.system(size: 13))
                    .foregroundStyle(.lumaInk(0.45))
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    LumaDetailActionButton(label: "Abspielen", icon: "play.fill", primary: true) { playAll(shuffle: false) }
                    LumaDetailActionButton(label: "Shuffle", icon: "shuffle") { playAll(shuffle: true) }
                    LumaDetailOptionsMenu { artistMenu }
                    Spacer(minLength: 0)
                }
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
    }
    #endif

    private var iosArtistHeader: some View {
        VStack(spacing: 0) {
            ArtistArtworkView(albums: Array(artist.sortedAlbums.prefix(4)))
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.5), radius: 36, y: 16)
                .padding(.top, 112)

            VStack(spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.45)
                    .foregroundStyle(.lumaInk())
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                let a = artist.albumCount, t = artist.trackCount
                Text(verbatim: "\(CountText.albums(a)) · \(CountText.songs(t))")
                    .font(.system(size: 14))
                    .foregroundStyle(.lumaInk(0.45))
            }

            HStack(spacing: 10) {
                artistActionButton(label: "Abspielen", icon: "play.fill", primary: true) {
                    playAll(shuffle: false)
                }
                artistActionButton(label: "Shuffle", icon: "shuffle", primary: false) {
                    playAll(shuffle: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func artistActionButton(label: LocalizedStringKey, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 16, weight: primary ? .semibold : .medium))
                .tracking(-0.25)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primary ? Color.lumaAccent : Color.lumaInk(0.1))
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.lumaInk(0.14), lineWidth: 0.5)
                    }
                }
                // Primary fill is now white, so its label must be dark to stay readable.
                .foregroundStyle(primary ? .lumaOnAccent : .lumaInk())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Album Header Row

    private func albumNavRow(_ album: Album) -> some View {
        HStack(spacing: 14) {
            ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 8, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.lumaInk())
                HStack(spacing: 6) {
                    if let year = album.year { Text(String(year)) }
                    Text(verbatim: "· \(CountText.songs(album.tracks.count))")
                }
                .font(.caption)
                .foregroundStyle(.lumaInk(0.45))
            }
            Spacer()
        }
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func play(track: Track, album: Album) {
        let sorted = album.sortedTracks
        guard let idx = sorted.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(sorted, startAt: idx)
        Task { await app.player.play(track: track) }
    }

    private func playAll(shuffle: Bool) {
        let all = artist.sortedAlbums.flatMap { $0.sortedTracks }
        guard !all.isEmpty else { return }
        let start = shuffle ? Int.random(in: 0..<all.count) : 0
        app.queue.setQueue(all, startAt: start, shuffle: shuffle)
        Task { await app.player.play(track: app.queue.currentTrack ?? all[start]) }
    }
}

// MARK: - Artist Artwork (single or 2×2 mosaic)

private struct ArtistArtworkView: View {
    let albums: [Album]

    var body: some View {
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
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            // Single album → one cover fills the artist header. macOS caps the decode below the
            // stored ~1024px (512 stays crisp at the header's @2x backing) rather than caching a
            // ~4 MB full bitmap. iOS keeps the default (nil = full-res) so it stays unchanged.
            #if os(macOS)
            let fallbackMax: Int? = 512
            #else
            let fallbackMax: Int? = nil
            #endif
            ArtworkView(data: albums.first?.artworkData, cacheKey: albums.first?.id.uuidString,
                        cornerRadius: 16, size: nil, maxPixel: fallbackMax)
                .aspectRatio(1, contentMode: .fit)
        }
    }
}
