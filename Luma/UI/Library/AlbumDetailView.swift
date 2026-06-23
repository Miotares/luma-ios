import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    let album: Album

    @State private var navArtist: ArtistRoute?
    @State private var showingAlbumEditor = false
    @State private var showingDeleteConfirm = false
    /// Set when the user confirms deletion; the album is actually removed in onDisappear,
    /// once this view (which reads album.artworkData / album.tracks) is off screen.
    @State private var pendingDeletion = false

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showingPlaylistPicker = false

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
                    trackRow(track)
                }

                trackListFooter
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS) || os(visionOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .lumaScrollClearance(playerActive: app.player.isActive)

            // Floating top bar: back / select-all (left) + options / done (right)
            HStack {
                if isSelecting {
                    selectAllButton
                } else {
                    LumaBackButton { dismiss() }
                }
                Spacer()
                if isSelecting {
                    pillButton("Fertig") { exitSelection() }
                } else {
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
                    #if os(macOS)
                    .menuStyle(.borderlessButton)
                    #endif
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .overlay {
                if isSelecting {
                    Text(selectionTitleKey)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
        }
        // Bulk-selection action bar. MUST be applied here (right after the ZStack, BEFORE the
        // .background(…ignoresSafeArea) below) — applied later it loses the safe area and renders
        // off-screen. The mini-player floats via a NavigationStack-level safeAreaInset that does
        // NOT reduce this view's safe area, so add explicit bottom clearance for it (same reason
        // lumaScrollClearance exists); ~64pt mini-player + a small gap. Verified on device.
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                TrackSelectionBar(
                    count: selection.count,
                    onAddToPlaylist: { showingPlaylistPicker = true },
                    onLike: likeSelected
                )
                .padding(.bottom, app.player.isActive ? 72 : 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: isSelecting)
        // Keep the bar PRESENT (transparent) so iOS's native interactive
        // swipe-back stays enabled — hiding it entirely disables the gesture.
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(item: $navArtist) { route in
            ArtistDetailView(artist: route.artist)
        }
        .sheet(isPresented: $showingAlbumEditor) {
            AlbumMetadataEditorView(album: album)
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerSheet(onPick: addSelected(to:))
        }
        .alert("Album löschen?", isPresented: $showingDeleteConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                // Don't delete inline: this view's body reads album.artworkData (externalStorage)
                // and album.sortedTracks/tracks. Deleting now — even after dismiss() — lets the
                // save republish @Query and re-evaluate this view's body WHILE it is still mounted
                // during the pop transition, faulting the just-deleted Album (crash). Instead flag
                // it and pop; the actual removeAlbum runs in onDisappear, once we're fully gone.
                pendingDeletion = true
                dismiss()
            }
        } message: {
            Text("\"\(album.title)\" und alle \(album.tracks.count) Titel werden entfernt.")
        }
        .onDisappear {
            guard pendingDeletion else { return }
            try? app.library.removeAlbum(album)
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
        Button {
            enterSelection()
        } label: {
            Label("Auswählen", systemImage: "checkmark.circle")
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
        #if os(macOS)
        macAlbumHeader
        #else
        iosAlbumHeader
        #endif
    }

    #if os(macOS)
    private var macAlbumHeader: some View {
        HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 12, size: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(album.title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let artist = album.artist {
                    Button { navArtist = ArtistRoute(artist: artist) } label: { artistLabel }
                        .buttonStyle(.plain)
                } else {
                    artistLabel
                }

                Text(macMetaLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    actionButton(label: "Abspielen", icon: "play.fill", primary: true) { playAll(shuffle: false) }
                        .frame(width: 160)
                    actionButton(label: "Shuffle", icon: "shuffle", primary: false) { playAll(shuffle: true) }
                        .frame(width: 160)
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
    }

    private var macMetaLine: String {
        [album.year.map(String.init),
         DurationText.hoursMinutes(album.totalDuration),
         CountText.songs(album.tracks.count)].compactMap { $0 }.joined(separator: " · ")
    }
    #endif

    private var iosAlbumHeader: some View {
        VStack(spacing: 0) {
            // Artwork — fixed square (matches mockup `size={210}`); a flexible
            // size inside the vertical ScrollView would grow unbounded.
            ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 20, size: 210)
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

    // MARK: - Selection

    private var selectedTracks: [Track] {
        album.sortedTracks.filter { selection.contains($0.id) }
    }

    private var allSelected: Bool {
        !album.sortedTracks.isEmpty && selection.count == album.sortedTracks.count
    }

    private var selectionTitleKey: LocalizedStringKey {
        selection.isEmpty ? "Auswählen" : "\(selection.count) ausgewählt"
    }

    /// One album track row — selectable while in selection mode (tap toggles, no swipe),
    /// otherwise the normal play row with trailing queue-swipe actions.
    @ViewBuilder
    private func trackRow(_ track: Track) -> some View {
        let row = TrackRow(
            track: track,
            showArtistName: false,
            showsMenu: !isSelecting,
            selectionMode: isSelecting,
            isSelected: selection.contains(track.id),
            isCurrent: track.id == app.player.currentTrack?.id,
            isPlaying: app.player.state.isPlaying,
            liked: track.isLiked
        ) {
            if isSelecting { toggleSelection(track) } else { play(track: track) }
        }
        .equatable()
        .frame(maxWidth: .infinity, minHeight: 52)
        .listRowBackground(Color.clear)
        .trackRowSeparator()
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

        row.lumaApplyIf(!isSelecting) {
            $0.trackQueueSwipeTrailing(
                playNext: { app.queue.playNext([track]) },
                addLast: { app.queue.append([track]) }
            )
        }
    }

    private var selectAllButton: some View {
        pillButton(allSelected ? "Keine" : "Alle") { toggleSelectAll() }
    }

    private func pillButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func toggleSelection(_ track: Track) {
        if selection.contains(track.id) { selection.remove(track.id) }
        else { selection.insert(track.id) }
    }

    private func toggleSelectAll() {
        if allSelected { selection.removeAll() }
        else { selection = Set(album.sortedTracks.map(\.id)) }
    }

    private func enterSelection() {
        withAnimation { selection.removeAll(); isSelecting = true }
    }

    private func exitSelection() {
        withAnimation { isSelecting = false; selection.removeAll() }
    }

    private func likeSelected() {
        try? app.library.setLiked(selectedTracks, liked: true)
        exitSelection()
    }

    private func addSelected(to playlist: Playlist) {
        try? app.library.addTracks(selectedTracks, to: playlist)
        exitSelection()
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
