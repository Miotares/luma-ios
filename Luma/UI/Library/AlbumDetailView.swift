import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.createdDate, order: .reverse) private var playlists: [Playlist]
    let album: Album

    @State private var navArtist: ArtistRoute?
    @State private var showingAlbumEditor = false
    @State private var showingDeleteConfirm = false

    private struct ArtistRoute: Hashable { let artist: Artist }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            DetailBackground(artworkData: album.artworkData)

            // Scrollable content — a List so track rows get native swipe actions.
            List {
                albumHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())

                ForEach(album.sortedTracks) { track in
                    TrackRow(track: track, showArtistName: false, showsMenu: true) { play(track: track) }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .listRowBackground(Color.clear)
                        .trackRowSeparator()
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .trackQueueSwipeTrailing(
                            playNext: { app.queue.playNext([track]) },
                            addLast: { app.queue.append([track]) }
                        )
                }

                trackListFooter
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .lumaScrollClearance(playerActive: app.player.state.isActive)

            // Floating top bar: back (left) + options menu (right)
            HStack {
                LumaBackButton { dismiss() }
                Spacer()
                Menu {
                    albumMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .glassEffect(.regular, in: .circle)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
        }
        // Keep the bar PRESENT (transparent) so iOS's native interactive
        // swipe-back stays enabled — hiding it entirely disables the gesture.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(item: $navArtist) { route in
            ArtistDetailView(artist: route.artist)
        }
        .sheet(isPresented: $showingAlbumEditor) {
            AlbumMetadataEditorView(album: album)
        }
        .confirmationDialog("Album löschen?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Album löschen", role: .destructive) {
                try? app.library.removeAlbum(album)
                dismiss()
            }
        } message: {
            Text("\"\(album.title)\" und alle \(album.tracks.count) Titel werden entfernt.")
        }
    }

    // MARK: - Options Menu

    @ViewBuilder
    private var albumMenu: some View {
        Button {
            app.queue.playNext(album.sortedTracks)
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.queue.append(album.sortedTracks)
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        try? app.library.addTracks(album.sortedTracks, to: playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zur Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }
        Button {
            showingAlbumEditor = true
        } label: {
            Label("Albuminformationen bearbeiten", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            Label("Album löschen", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .tint(.red)
    }

    // MARK: - Header

    private var albumHeader: some View {
        VStack(spacing: 0) {
            // Artwork — fixed square (matches mockup `size={210}`); a flexible
            // size inside the vertical ScrollView would grow unbounded.
            ArtworkView(data: album.artworkData, cornerRadius: 20, size: 210)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 30, y: 20)
                .padding(.top, 112)

            // Info
            VStack(spacing: 0) {
                Text(album.title)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.45)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)

                if let artist = album.artist {
                    // A Button (not a NavigationLink) avoids the second, system-drawn
                    // disclosure chevron that a List adds — we keep our own in artistLabel.
                    Button {
                        navArtist = ArtistRoute(artist: artist)
                    } label: {
                        artistLabel
                    }
                    .buttonStyle(.plain)
                } else {
                    artistLabel
                }

                Text(metaLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 3)
            }
            .multilineTextAlignment(.center)

            // Play / Shuffle
            HStack(spacing: 10) {
                actionButton(label: "Abspielen", icon: "play.fill", primary: true) {
                    playAll(shuffle: false)
                }
                actionButton(label: "Shuffle", icon: "shuffle", primary: false) {
                    playAll(shuffle: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var artistLabel: some View {
        HStack(spacing: 4) {
            Text(album.artistName)
                .font(.system(size: 16, weight: .medium))
                .tracking(-0.2)
                .foregroundStyle(album.artist != nil ? Color.lumaAccent : Color.white.opacity(0.52))
            if album.artist != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.lumaAccent.opacity(0.7))
            }
        }
        .padding(.top, 5)
    }

    private var metaLine: String {
        let duration = DurationText.hoursMinutes(album.totalDuration)
        return [album.year.map(String.init), duration].compactMap { $0 }.joined(separator: " · ")
    }

    private func actionButton(label: LocalizedStringKey, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
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

    // MARK: - Track List Footer

    private var trackListFooter: some View {
        // Playtime is already shown next to the year up top, so only the count here.
        Text(CountText.songs(album.tracks.count))
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }

    // MARK: - Actions

    private func play(track: Track) {
        let sorted = album.sortedTracks
        guard let idx = sorted.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(sorted, startAt: idx)
        Task { await app.player.play(track: track) }
    }

    private func playAll(shuffle: Bool) {
        let tracks = album.sortedTracks
        guard !tracks.isEmpty else { return }
        let start = shuffle ? Int.random(in: 0..<tracks.count) : 0
        app.queue.setQueue(tracks, startAt: start, shuffle: shuffle)
        Task { await app.player.play(track: app.queue.currentTrack ?? tracks[0]) }
    }
}

// MARK: - Detail Background (reusable)

struct DetailBackground: View {
    let artworkData: Data?
    @State private var image: Image?

    var body: some View {
        // Color drives the layout size (screen-bounded). The blurred artwork is an
        // OVERLAY so its aspect-fill overflow never inflates the layout width — a
        // plain ZStack child would report a width ≈ screen height and push the whole
        // detail view wider than the screen (horizontal overflow).
        Color.lumaBackground
            .overlay {
                if let image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 80, opaque: true)
                        .opacity(0.3)
                }
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, Color.lumaBackground.opacity(0.6)],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.5)
                )
            }
            .clipped()
            .ignoresSafeArea()
            .task(id: artworkData) { image = await decode(artworkData) }
    }

    private func decode(_ data: Data?) async -> Image? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            #if os(iOS) || os(visionOS)
            guard let ui = UIImage(data: data) else { return nil }
            return Image(uiImage: ui)
            #elseif os(macOS)
            guard let ns = NSImage(data: data) else { return nil }
            return Image(nsImage: ns)
            #else
            return nil
            #endif
        }.value
    }
}
