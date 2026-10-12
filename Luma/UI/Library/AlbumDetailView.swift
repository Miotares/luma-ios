import SwiftUI
import SwiftData
import ImageIO
import CoreImage

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
    /// Identity of the last plain/⌘-clicked track — the pivot for a ⇧-click range (macOS). Stored by
    /// id (not index) so it survives any list mutation; resolved to the current index at range time.
    @State private var selectAnchor: UUID?
    @State private var showingPlaylistPicker = false
    /// macOS in-album song filter (driven by the toolbar search field via `lumaDetailSongSearch`).
    /// Stays empty on iOS (no search field there), so the filtering below is a no-op on iOS.
    @State private var searchText = ""

    private struct ArtistRoute: Hashable { let artist: Artist }

    /// Live filter over the album's tracks. Empty query → the full list, so this is a no-op while
    /// not searching (and always on iOS).
    private func filtered(_ tracks: [Track]) -> [Track] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.artistName.localizedCaseInsensitiveContains(q) ||
            $0.albumTitle.localizedCaseInsensitiveContains(q)
        }
    }
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // This view can be deleted out from under itself: deleting its last track (track-row menu)
        // or moving its last track to another album (metadata editor) prunes this now-empty album
        // and saves, republishing @Query and re-evaluating this body while it is still mounted →
        // reading album.title/.tracks/.artworkData then faults. (The whole-album delete avoids this
        // via pendingDeletion+onDisappear below; this guard covers the paths that delete it
        // indirectly.) `modelContext` goes nil once deleted+saved and is safe to read.
        Group {
            if album.modelContext != nil {
                content
            } else {
                Color.lumaBackground.ignoresSafeArea()
            }
        }
        .onChange(of: album.modelContext == nil) { _, deleted in
            if deleted { dismiss() }
        }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            // Background
            DetailBackground(artworkData: album.artworkData)

            // Scrollable content — a List; macOS gets native ⌘/⇧-click multi-select.
            trackListView

            // iOS floating top bar (back / select / options). macOS uses the native back button
            // and an inline options menu in the header — no glass overlay.
            #if os(iOS) || os(visionOS)
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
                            .foregroundStyle(.lumaInk())
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                            .glassEffect(.regular, in: .circle)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .overlay {
                if isSelecting {
                    Text(selectionTitleKey)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.lumaInk())
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
            #endif
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
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                if !selection.isEmpty {
                    // One roomy pill: fixedSize stops the count text from clipping inside the glass,
                    // and the explicit spacing/padding gives it breathing room (the old group rendered
                    // too tight, so "N ausgewählt" bled past the capsule edge).
                    HStack(spacing: 12) {
                        Text("\(selection.count) ausgewählt")
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(.secondary)
                        Button { showingPlaylistPicker = true } label: {
                            Image(systemName: "text.badge.plus")
                        }
                        .help("Auswahl zur Playlist hinzufügen")
                        Button { likeSelected() } label: {
                            Image(systemName: "heart")
                        }
                        .help("Auswahl liken")
                    }
                    .padding(.horizontal, 6)
                }
            }
            #endif
        }
        .lumaDetailSongSearch($searchText, prompt: "Im Album suchen")
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

    // MARK: - Track List

    /// macOS gets a native multi-select `List(selection:)` (⌘/⇧-click) bound to the same
    /// `selection` set; iOS keeps its tap-to-select mode. Rows are shared via `listRows`.
    @ViewBuilder
    private var trackListView: some View {
        #if os(macOS)
        // Plain List (NOT List(selection:)): selection is custom (single click toggles, ⇧ extends),
        // so we draw our own inset accent pill in TrackRow instead of the native full-width blue
        // highlight that bled past the row edges. Right-click uses the row's own context menu.
        List { listRows }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .lumaScrollClearance(playerActive: app.player.isActive)
        #else
        List { listRows }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .lumaScrollClearance(playerActive: app.player.isActive)
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        albumHeader
            .clearSongSelectionOnTap { clearSelection() }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .selectionDisabled()

        // Sort once per body eval (not once per row): `trackRow` used to re-read `album.sortedTracks`
        // for every row, re-sorting the album each time. Cheap per album, but the same per-row-recompute
        // shape that froze playlists — keep it hoisted here and pass the result into the row.
        let sortedTracks = album.sortedTracks
        // macOS toolbar search filters which rows show (no-op while not searching / on iOS).
        let displayTracks = filtered(sortedTracks)
        // Row position by id, built once per pass (a per-row `firstIndex(where:)` was O(rows²)).
        let rowIndex = Dictionary(displayTracks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        ForEach(displayTracks) { track in
            // macOS: plain click selects only this song, ⌘ toggles, ⇧ ranges; double-click / glyph
            // plays. The selected block is the row background (merges adjacent rows) — see trackRow.
            trackRow(track, at: rowIndex[track.id], in: displayTracks)
        }

        if isSearching && displayTracks.isEmpty {
            noResultsRow
        }

        // The album-total footer would contradict a filtered list ("15 Songs" over 1 shown), so
        // hide it while searching.
        if !isSearching {
            trackListFooter
                .clearSongSelectionOnTap { clearSelection() }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .selectionDisabled()
        }
    }

    /// Shown in place of the rows when a search matches nothing.
    private var noResultsRow: some View {
        Text("Keine Treffer")
            .font(.system(size: 13))
            .foregroundStyle(.lumaInk(0.4))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 32)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .selectionDisabled()
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
        #if os(iOS) || os(visionOS)
        // iOS uses an explicit tap-to-select mode; macOS selects natively (⌘/⇧-click).
        Button {
            enterSelection()
        } label: {
            Label("Auswählen", systemImage: "checkmark.circle")
        }
        #endif
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
                        .strokeBorder(.lumaInk(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(album.title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.lumaInk())
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
                    .foregroundStyle(.lumaInk(0.4))
                    .padding(.top, 6)

                LumaDetailActionBar(onPlay: { playAll(shuffle: false) },
                                    onShuffle: { playAll(shuffle: true) }) { albumMenu }
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Leading 16 so the cover's left edge lines up with the track rows below (their
        // listRowInsets leading is 16) — the cover and the track-number column share one margin.
        .padding(.leading, 16)
        .padding(.trailing, 28)
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
                        .strokeBorder(.lumaInk(0.07), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 30, y: 20)
                .padding(.top, 112)

            // Info
            VStack(spacing: 0) {
                Text(album.title)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.45)
                    .foregroundStyle(.lumaInk())
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
                    .foregroundStyle(.lumaInk(0.35))
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
                .foregroundStyle(album.artist != nil ? Color.lumaAccent : Color.lumaInk(0.52))
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

    // MARK: - Track List Footer

    private var trackListFooter: some View {
        // Playtime is already shown next to the year up top, so only the count here.
        Text(CountText.songs(album.tracks.count))
            .font(.system(size: 13))
            .foregroundStyle(.lumaInk(0.35))
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
    private func trackRow(_ track: Track, at idx: Int?, in tracks: [Track]) -> some View {
        let isSel = selection.contains(track.id)
        // Neighbour-selected flags drive the block's corner rounding (see trackSelectionRowBackground).
        let selAbove = idx.map { $0 > 0 && selection.contains(tracks[$0 - 1].id) } ?? false
        let selBelow = idx.map { $0 < tracks.count - 1 && selection.contains(tracks[$0 + 1].id) } ?? false
        // macOS: drop the hairline between two selected rows so a selection reads as one block.
        #if os(macOS)
        let separatorVisible = !(isSel && selBelow)
        #else
        let separatorVisible = true
        #endif
        let row = TrackRow(
            track: track,
            showArtistName: false,
            showsMenu: !isSelecting,
            selectionMode: isSelecting,
            isSelected: isSel,
            isCurrent: track.id == app.player.currentTrack?.id,
            isPlaying: track.id == app.player.currentTrack?.id && app.player.state.isPlaying,
            liked: track.isLiked,
            // macOS: plain click selects only this song, ⌘ toggles, ⇧ ranges; double-click / glyph plays.
            onPlay: { play(track: track) },
            onSelect: { gesture in selectClicked(track, gesture, in: tracks) }
        ) {
            // iOS tap-to-select mode (and macOS fallback): toggle while selecting, else play.
            if isSelecting { toggleSelection(track) } else { play(track: track) }
        }
        .equatable()
        .frame(maxWidth: .infinity)
        .lumaSongRowMinHeight(44)
        .trackSelectionRowBackground(isSelected: isSel, selectedAbove: selAbove, selectedBelow: selBelow)
        .trackRowSeparator(showsLine: separatorVisible)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

        row.lumaApplyIf(!isSelecting) {
            $0.trackQueueSwipeTrailing(
                playNext: { app.queue.playNext([track]) },
                addLast: { app.queue.append([track]) }
            )
        }
    }

    /// Single-click selection for the macOS list (Finder/Music semantics): a plain click selects ONLY
    /// this song, ⌘ toggles it in/out, ⇧ selects the contiguous range from the anchor. Defined for all
    /// platforms so the shared `onSelect` closure compiles; only invoked on macOS.
    private func selectClicked(_ track: Track, _ gesture: TrackSelectGesture, in tracks: [Track]) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        switch gesture {
        case .replace:
            selection = [track.id]
            selectAnchor = track.id
        case .toggle:
            if selection.contains(track.id) { selection.remove(track.id) }
            else { selection.insert(track.id) }
            selectAnchor = track.id
        case .range:
            // Resolve the anchor by identity (survives reorder/remove); fall back to this row.
            let anchorIdx = selectAnchor.flatMap { id in tracks.firstIndex { $0.id == id } } ?? i
            selection = Set(tracks[min(anchorIdx, i)...max(anchorIdx, i)].map(\.id))
        }
    }

    /// Clear the selection when the user clicks outside the song rows (header / footer / background).
    private func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.removeAll()
        selectAnchor = nil
    }

    private var selectAllButton: some View {
        pillButton(allSelected ? "Keine" : "Alle") { toggleSelectAll() }
    }

    private func pillButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.lumaInk())
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

    /// Shared GPU context for the one-time backdrop pre-blur. Thread-safe; reused across decodes
    /// so we don't spin up a CIContext per navigation.
    nonisolated(unsafe) private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        // Color drives the layout size (screen-bounded). The blurred artwork is an
        // OVERLAY so its aspect-fill overflow never inflates the layout width — a
        // plain ZStack child would report a width ≈ screen height and push the whole
        // detail view wider than the screen (horizontal overflow).
        Color.lumaBackground
            .overlay {
                if let image {
                    // No live `.blur` here: the gaussian is baked into `image` once in `decode`.
                    // A radius-80 blur on a window-sized surface was re-rasterized EVERY window-
                    // resize frame (a top macOS resize-CPU spike); now resizing just upscales an
                    // already-blurred ~400px bitmap. Look is unchanged at 0.3 opacity.
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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
        return await Task.detached(priority: .utility) {
            // The backdrop is heavily blurred (radius 80) at 0.3 opacity, so a downsampled thumbnail
            // is visually identical to the full ~1024px cover — but decoding ~400px via ImageIO costs
            // a fraction of the CPU and holds ~6× less bitmap memory per detail view (the old full
            // UIImage/NSImage(data:) decode spiked the CPU on every navigation). Runs at .utility so
            // it yields to playback. `.blur` works on the rendered view size, so the look is unchanged.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 400,
                  ] as CFDictionary)
            else { return nil }
            // Bake the heavy gaussian in HERE (once, off-main) instead of as a live `.blur` the
            // renderer re-runs on every window-resize frame. `clampedToExtent` replicates edges so
            // the blur doesn't darken/feather the border (matching the old `opaque: true`).
            let ci = CIImage(cgImage: cg)
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: ci.extent)
            let outCG = Self.ciContext.createCGImage(blurred, from: ci.extent) ?? cg
            #if os(iOS) || os(visionOS)
            return Image(uiImage: UIImage(cgImage: outCG))
            #elseif os(macOS)
            return Image(nsImage: NSImage(cgImage: outCG, size: .zero))
            #else
            return nil
            #endif
        }.value
    }
}
