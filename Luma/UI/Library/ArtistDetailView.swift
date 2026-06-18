import SwiftUI

struct ArtistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let artist: Artist

    private var artworkData: Data? { artist.sortedAlbums.first?.artworkData }

    var body: some View {
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
                        TrackRow(track: track, showArtistName: false, showsMenu: true) {
                            play(track: track, album: album)
                        }
                        .frame(minHeight: 54)
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
            .ignoresSafeArea(.container, edges: .top)
            .lumaScrollClearance(playerActive: app.player.state.isActive)

            LumaBackButton { dismiss() }
                .padding(.leading, 18)
                .padding(.top, 18)
        }
        // Transparent (not hidden) bar keeps the native interactive swipe-back.
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
    }

    // MARK: - Artist Header

    private var artistHeader: some View {
        VStack(spacing: 0) {
            ArtistArtworkView(albums: Array(artist.sortedAlbums.prefix(4)))
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.5), radius: 36, y: 16)
                .padding(.top, 112)

            VStack(spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.45)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                let a = artist.albumCount, t = artist.trackCount
                Text(verbatim: "\(CountText.albums(a)) · \(CountText.songs(t))")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.45))
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
                        .fill(primary ? Color.lumaAccent : Color.white.opacity(0.1))
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    }
                }
                // Primary fill is now white, so its label must be dark to stay readable.
                .foregroundStyle(primary ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Album Header Row

    private func albumNavRow(_ album: Album) -> some View {
        HStack(spacing: 14) {
            ArtworkView(data: album.artworkData, cornerRadius: 8, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    if let year = album.year { Text(String(year)) }
                    Text(verbatim: "· \(CountText.songs(album.tracks.count))")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
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
                        ArtworkView(data: albums[0].artworkData, cornerRadius: 0, size: half)
                        ArtworkView(data: albums[1].artworkData, cornerRadius: 0, size: half)
                    }
                    HStack(spacing: 2) {
                        ArtworkView(data: albums[2].artworkData, cornerRadius: 0, size: half)
                        ArtworkView(data: albums[3].artworkData, cornerRadius: 0, size: half)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            ArtworkView(data: albums.first?.artworkData, cornerRadius: 16, size: nil)
                .aspectRatio(1, contentMode: .fit)
        }
    }
}
