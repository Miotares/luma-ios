import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(MacNavigationState.self) private var macNav
    #endif
    /// Tracks that are in some playlist — all the entry→track map needs. (Was the whole tracks
    /// table: a 36–62 ms main-thread fetch on every open and after every save.)
    @Query(playlistTracksDescriptor()) private var playlistTracks: [Track]
    let playlist: Playlist

    @State private var showingRename = false
    @State private var editedName = ""
    @State private var isEditing = false
    @State private var showingDeleteConfirm = false
    @State private var showingCoverEditor = false

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    /// Identity of the last plain/⌘-clicked track — pivot for a ⇧-click range (macOS). Stored by id
    /// (not index) so it survives reorder/remove; resolved to the current index at range time.
    @State private var selectAnchor: UUID?
    @State private var showingPlaylistPicker = false
    @State private var showingExporter = false
    @State private var exportDocument: PlaylistBackupDocument?
    /// macOS in-playlist song filter (driven by the toolbar search field via `lumaDetailSongSearch`).
    /// Stays empty on iOS (no search field there), so the filtering below is a no-op on iOS.
    @State private var searchText = ""

    /// (entry, track) pairs resolved through the track→entry inverse, so entries whose
    /// track was deleted are skipped instead of crashing on `entry.track`.
    /// Resolves the playlist's entries against the library in a SINGLE pass over one
    /// `validEntryTrackMap(playlistTracks)` build — pairs, placeholders and the unresolved flag at
    /// once. `body` computes this ONCE and reuses it, instead of the old getters that each
    /// rebuilt the full-library map (6–8× per body evaluation). Entries whose track was
    /// deleted are skipped instead of crashing on `entry.track`.
    private struct Resolved {
        let pairs: [(entry: PlaylistEntry, track: Track)]
        let placeholders: [PlaylistEntry]
        let hasUnresolved: Bool
        var tracks: [Track] { pairs.map(\.track) }
    }
    private var resolved: Resolved {
        let map = validEntryTrackMap(playlistTracks)
        var pairs: [(entry: PlaylistEntry, track: Track)] = []
        var placeholders: [PlaylistEntry] = []
        var hasUnresolved = false
        for entry in playlist.entries.sorted(by: { $0.order < $1.order }) {
            if let track = map[entry.persistentModelID] {
                pairs.append((entry, track))
            } else {
                hasUnresolved = true
                // Grayed placeholder rows show denormalized metadata, never `entry.track`.
                if !entry.trackTitle.isEmpty { placeholders.append(entry) }
            }
        }
        return Resolved(pairs: pairs, placeholders: placeholders, hasUnresolved: hasUnresolved)
    }
    // Convenience accessors for the action handlers (run on tap, not per-render).
    private var validPairs: [(entry: PlaylistEntry, track: Track)] { resolved.pairs }
    private var tracks: [Track] { resolved.tracks }
    private var placeholderEntries: [PlaylistEntry] { resolved.placeholders }
    private var hasUnresolvedEntries: Bool { resolved.hasUnresolved }

    /// Sanitized suggested export filename — playlist names allow `/` and `:`, which
    /// break a file name; fall back to a constant when the name is empty.
    private var exportFilename: String {
        let cleaned = playlist.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Playlist" : cleaned
    }

    /// Duration of the given (valid) tracks — `playlist.formattedDuration` would walk
    /// `sortedTracks` and crash on a dangling entry.
    private func tracksDuration(_ tracks: [Track]) -> String {
        DurationText.hoursMinutes(tracks.reduce(0) { $0 + $1.duration })
    }

    /// Live filter over the playlist's tracks. Empty query → the full list, so this is a no-op
    /// while not searching (and always on iOS, where no search field is shown).
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

    #if os(macOS)
    /// True when this playlist is the ROOT of the playlists navigation stack (opened from the
    /// sidebar) — i.e. it has no native NavigationStack back button. Only then do we show our own
    /// "back to Mediathek" toolbar button; a playlist PUSHED from a gallery already has the native
    /// back chevron, so we'd otherwise double it up.
    private var isPlaylistStackRoot: Bool {
        macNav.section == .playlists && macNav.playlistID == playlist.id && macNav.playlistsPath.isEmpty
    }
    #endif

    var body: some View {
        let r = resolved
        let trackList = r.tracks
        return ZStack(alignment: .topLeading) {
            DetailBackground(artworkData: trackList.first?.album?.artworkData)

            trackListView(r, trackList)

            // iOS floating top bar (back / select / edit / options). macOS uses the native back
            // button and an inline options menu in the header — no glass overlay.
            #if os(iOS) || os(visionOS)
            HStack {
                if isSelecting {
                    selectAllButton
                } else {
                    LumaBackButton { dismiss() }
                }
                Spacer()
                if isEditing {
                    pillButton("Fertig") { withAnimation { isEditing = false } }
                } else if isSelecting {
                    pillButton("Fertig") { exitSelection() }
                } else {
                    Menu {
                        playlistMenu
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
        // Transparent (not hidden) bar keeps the native interactive swipe-back.
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
        .toolbar {
            #if os(macOS)
            // A sidebar-opened playlist is its stack root, so it has no native back button — give it
            // one (leading, where the native chevron sits) that returns to the Mediathek home (Alben).
            if isPlaylistStackRoot {
                ToolbarItem(placement: .navigation) {
                    Button { macNav.goToLibraryHome() } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .help("Zurück zur Mediathek")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if !selection.isEmpty {
                    // One roomy pill: fixedSize stops the count text clipping inside the glass; the
                    // spacing/padding give it breathing room (the old group rendered too tight).
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
                        Button { removeSelectedMac() } label: {
                            Image(systemName: "trash")
                        }
                        .help("Auswahl aus Playlist entfernen")
                    }
                    .padding(.horizontal, 6)
                }
            }
            #endif
        }
        .lumaDetailSongSearch($searchText, prompt: "In Playlist suchen")
        .onAppear { editedName = playlist.name }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerSheet(onPick: addSelected(to:))
        }
        .sheet(isPresented: $showingCoverEditor) {
            PlaylistCoverEditor(playlist: playlist, tracks: tracks)
                .environment(app)
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { _ in }
        .alert("Playlist löschen?", isPresented: $showingDeleteConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                try? app.library.deletePlaylist(playlist)
                dismiss()
            }
        } message: {
            Text("\"\(playlist.name)\" wird gelöscht. Die Titel bleiben in der Mediathek.")
        }
        // Rename via a system alert (auto-focuses the field, pops the keyboard reliably). The old
        // inline title-swap relied on an unfocused TextField that looked identical to the title and
        // never became first responder, so on iOS tapping "Umbenennen" produced no visible change.
        .alert("Playlist umbenennen", isPresented: $showingRename) {
            TextField("Name", text: $editedName)
            Button("Sichern") { saveRename() }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    // MARK: - Track List

    /// macOS gets a native multi-select `List(selection:)` (⌘/⇧-click, ⌫ to remove) bound to the
    /// same `selection` set; iOS keeps its tap-to-select edit mode. Rows are shared via `listRows`.
    @ViewBuilder
    private func trackListView(_ r: Resolved, _ trackList: [Track]) -> some View {
        #if os(macOS)
        // Plain List (NOT List(selection:)): selection is custom (single click toggles, ⇧ extends),
        // drawn as an inset accent pill in TrackRow — no native full-width blue highlight. ⌫ still
        // removes the current selection via onDeleteCommand.
        List { listRows(r, trackList) }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .lumaScrollClearance(playerActive: app.player.isActive)
            .onDeleteCommand { removeSelectedMac() }
        #else
        List { listRows(r, trackList) }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .lumaScrollClearance(playerActive: app.player.isActive)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        #endif
    }

    @ViewBuilder
    private func listRows(_ r: Resolved, _ trackList: [Track]) -> some View {
        playlistHeader(tracks: trackList)
            .clearSongSelectionOnTap { clearSelection() }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .selectionDisabled()

        // macOS toolbar search filters which rows show (no-op while not searching / on iOS).
        let displayList = filtered(trackList)
        // Row position by id, built ONCE per pass. Each row needs its index (for the neighbour-
        // selected flags); a `firstIndex(where:)` per row made that O(rows²) on every body pass —
        // and a pass runs on every selection click.
        let rowIndex = Dictionary(displayList.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        ForEach(displayList) { track in
            // macOS: plain click selects only this song, ⌘ toggles, ⇧ ranges; double-click / glyph
            // plays. Drag-reorder + per-track remove still work. The selected block is the row bg.
            // Pass `displayList` in: it IS `resolved.tracks` (or its search subset), already built
            // once by `body`. The row must NOT re-read the computed `tracks` — that rebuilds the
            // full-library map per row (an O(rows × library) main-thread storm that froze a
            // 350-entry playlist for seconds).
            trackRow(track, at: rowIndex[track.id], in: displayList)
        }
        // Reorder/swipe-delete index into the FULL list, so disable both while a search filters the
        // rows (the visible indices wouldn't map back to the real entries) — see moveAction /
        // deleteAction.
        .onMove(perform: moveAction)
        .onDelete(perform: deleteAction)

        if isSearching && displayList.isEmpty {
            noResultsRow
        }

        if !isSearching, !r.placeholders.isEmpty {
            Text("Nicht in der Mediathek")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.lumaInk(0.4))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 20, leading: 18, bottom: 8, trailing: 16))
                .selectionDisabled()
            ForEach(r.placeholders) { entry in
                placeholderRow(entry)
                    .frame(minHeight: 56)
                    .listRowBackground(Color.clear)
                    .trackRowSeparator()
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .selectionDisabled()
            }
        }

        if trackList.isEmpty && r.placeholders.isEmpty {
            LumaEmptyState(icon: "music.note", title: "Keine Titel",
                           subtitle: "Diese Playlist ist noch leer.")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 60, leading: 20, bottom: 20, trailing: 20))
                .selectionDisabled()
        }
    }

    #if os(macOS)
    /// Removes the multi-selected tracks from this playlist (⌫ key / toolbar).
    private func removeSelectedMac() {
        for pair in validPairs where selection.contains(pair.track.id) {
            try? app.library.removeEntry(pair.entry, from: playlist)
        }
        selection.removeAll()
    }
    #endif

    // MARK: - Options Menu

    @ViewBuilder
    private var playlistMenu: some View {
        Button {
            app.playNext(tracks)
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.addToQueue(tracks)
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        #if os(iOS) || os(visionOS)
        // iOS uses an explicit tap-to-select mode and a reorder mode; macOS selects natively
        // (⌘/⇧-click in the list) and reorders by dragging rows directly.
        Button {
            enterSelection()
        } label: {
            Label("Auswählen", systemImage: "checkmark.circle")
        }
        Button {
            withAnimation { isEditing = true }
        } label: {
            Label("Bearbeiten", systemImage: "arrow.up.arrow.down")
        }
        #endif
        Button {
            startRename()
        } label: {
            Label("Umbenennen", systemImage: "pencil")
        }
        Button {
            showingCoverEditor = true
        } label: {
            Label("Cover ändern", systemImage: "photo")
        }
        Button {
            exportThis()
        } label: {
            Label("Playlist exportieren", systemImage: "square.and.arrow.up")
        }
        if hasUnresolvedEntries {
            Button {
                try? app.library.removePlaceholders(from: playlist)
            } label: {
                Label("Leere Einträge entfernen", systemImage: "wand.and.sparkles")
            }
        }
        Divider()
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            Label("Playlist löschen", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .tint(.red)
    }

    private func moveTracks(from source: IndexSet, to destination: Int) {
        var reordered = validPairs.map(\.entry)
        reordered.move(fromOffsets: source, toOffset: destination)
        // Re-index ALL entries, not just the valid ones the user dragged. Placeholder / dangling
        // entries (not shown in the reorderable list) keep their old `order` otherwise — colliding
        // with the freshly assigned 0..k range, so the saved (and EXPORTED) order becomes
        // non-canonical. Append the others (in their current order) after the reordered valid ones.
        let reorderedIDs = Set(reordered.map(\.id))
        let others = playlist.entries
            .filter { !reorderedIDs.contains($0.id) }
            .sorted { $0.order < $1.order }
        try? app.library.reorderEntries(reordered + others)
    }

    private func deleteTracks(_ offsets: IndexSet) {
        let pairs = validPairs
        for index in offsets where pairs.indices.contains(index) {
            try? app.library.removeEntry(pairs[index].entry, from: playlist)
        }
    }

    // MARK: - Header

    private func playlistHeader(tracks: [Track]) -> some View {
        #if os(macOS)
        macPlaylistHeader(tracks: tracks)
        #else
        iosPlaylistHeader(tracks: tracks)
        #endif
    }

    #if os(macOS)
    private func macPlaylistHeader(tracks: [Track]) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            PlaylistArtworkView(playlist: playlist, tracks: tracks, cornerRadius: 12)
                .frame(width: 220, height: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.lumaInk(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                .onTapGesture { showingCoverEditor = true }

            VStack(alignment: .leading, spacing: 0) {
                Text(playlist.name)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.lumaInk())
                    .lineLimit(2)
                    .onTapGesture { startRename() }

                Text(verbatim: "\(CountText.songs(tracks.count)) · \(tracksDuration(tracks))")
                    .font(.system(size: 13))
                    .foregroundStyle(.lumaInk(0.45))
                    .padding(.top, 6)

                LumaDetailActionBar(onPlay: { playAll(shuffle: false) },
                                    onShuffle: { playAll(shuffle: true) }) { playlistMenu }
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Leading 16 so the cover's left edge lines up with the track rows below (their
        // listRowInsets leading is 16) — the cover and the row album thumbnails share one margin.
        .padding(.leading, 16)
        .padding(.trailing, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
    }
    #endif

    private func iosPlaylistHeader(tracks: [Track]) -> some View {
        VStack(spacing: 18) {
            PlaylistArtworkView(playlist: playlist, tracks: tracks, cornerRadius: 20)
                .frame(width: 210, height: 210)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.lumaInk(0.07), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 30, y: 20)
                .padding(.top, 112)
                .onTapGesture { showingCoverEditor = true }

            VStack(spacing: 6) {
                Text(playlist.name)
                    .font(.title2.bold())
                    .foregroundStyle(.lumaInk())
                    .multilineTextAlignment(.center)
                    .onTapGesture { startRename() }

                let count = tracks.count
                Text(verbatim: "\(CountText.songs(count)) · \(tracksDuration(tracks))")
                    .font(.subheadline)
                    .foregroundStyle(.lumaInk(0.45))
            }

            HStack(spacing: 12) {
                playlistActionButton(label: "Abspielen", icon: "play.fill", primary: true) {
                    playAll(shuffle: false)
                }
                playlistActionButton(label: "Shuffle", icon: "shuffle", primary: false) {
                    playAll(shuffle: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func playlistActionButton(label: LocalizedStringKey, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    primary ? Color.lumaAccent : Color.lumaInk(0.1),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .foregroundStyle(primary ? Color.lumaOnAccent : Color.lumaInk())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection

    private var selectedTracks: [Track] {
        tracks.filter { selection.contains($0.id) }
    }

    /// `nil` while selecting (suppresses swipe-to-delete in selection mode) and while a search
    /// filters the rows (the visible indices wouldn't map back to the real playlist entries).
    private var deleteAction: ((IndexSet) -> Void)? {
        if isSelecting || isSearching { return nil }
        return { offsets in deleteTracks(offsets) }
    }

    /// `nil` while a search filters the rows, so drag-reorder is disabled (filtered indices
    /// wouldn't map back to the real entries); otherwise reorders via `moveTracks`.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        if isSearching { return nil }
        return moveTracks
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

    private var allSelected: Bool {
        !tracks.isEmpty && selection.count == tracks.count
    }

    private var selectionTitleKey: LocalizedStringKey {
        selection.isEmpty ? "Auswählen" : "\(selection.count) ausgewählt"
    }

    /// One playlist track row — selectable while in selection mode (tap toggles, no
    /// swipe/remove), otherwise the normal play row with remove + queue-swipe actions.
    /// `list` is the body-resolved track list (`resolved.tracks`), passed in so the row never
    /// re-derives it: reading the computed `tracks` here rebuilt the whole-library entry map on
    /// every row, which is what made large playlists beach-ball on open and stutter on scroll.
    @ViewBuilder
    private func trackRow(_ track: Track, at idx: Int?, in list: [Track]) -> some View {
        let isSel = selection.contains(track.id)
        let selAbove = idx.map { $0 > 0 && selection.contains(list[$0 - 1].id) } ?? false
        let selBelow = idx.map { $0 < list.count - 1 && selection.contains(list[$0 + 1].id) } ?? false
        // macOS: drop the hairline between two selected rows so a selection reads as one block.
        #if os(macOS)
        let separatorVisible = !(isSel && selBelow)
        #else
        let separatorVisible = true
        #endif
        let row = TrackRow(
            track: track,
            showArtwork: true,
            showAlbum: true,
            showsMenu: !isSelecting,
            selectionMode: isSelecting,
            isSelected: isSel,
            isCurrent: track.id == app.player.currentTrack?.id,
            isPlaying: track.id == app.player.currentTrack?.id && app.player.state.isPlaying,
            liked: track.isLiked,
            // "Aus Playlist entfernen" in the row menu + macOS hover-✕ (was an outer
            // contextMenu, which TrackRow's own menu shadowed). Library-delete stays separate.
            remove: isSelecting ? nil : TrackRowRemove(label: "Aus Playlist entfernen",
                                                       systemImage: "trash") {
                removeTrack(track)
            },
            // macOS: plain click selects only this song, ⌘ toggles, ⇧ ranges; double-click / glyph plays.
            onPlay: { playFromList(track) },
            onSelect: { gesture in selectClicked(track, gesture, in: list) }
        ) {
            // iOS tap-to-select mode (and macOS fallback): toggle while selecting, else play.
            if isSelecting { toggleSelection(track) } else { playFromList(track) }
        }
        .equatable()
        .lumaSongRowMinHeight(50)
        .trackSelectionRowBackground(isSelected: isSel, selectedAbove: selAbove, selectedBelow: selBelow)
        .trackRowSeparator(showsLine: separatorVisible)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

        row
            .lumaApplyIf(!isSelecting) {
                $0.trackQueueSwipeTrailing(
                    playNext: { app.playNext([track]) },
                    addLast: { app.addToQueue([track]) }
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

    /// Plays a track from the playlist: sets the playlist as the queue starting at this track.
    private func playFromList(_ track: Track) {
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(tracks, startAt: idx)
        Task { await app.player.play(track: track) }
    }

    /// Single-click selection for the macOS list (Finder/Music semantics): plain click selects only
    /// this song, ⌘ toggles it in/out, ⇧ selects the contiguous range from the anchor. Mirrors the
    /// album list. (Defined for all platforms so the shared `onSelect` closure compiles; macOS-only.)
    private func selectClicked(_ track: Track, _ gesture: TrackSelectGesture, in list: [Track]) {
        guard let i = list.firstIndex(where: { $0.id == track.id }) else { return }
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
            let anchorIdx = selectAnchor.flatMap { id in list.firstIndex { $0.id == id } } ?? i
            selection = Set(list[min(anchorIdx, i)...max(anchorIdx, i)].map(\.id))
        }
    }

    /// Clear the selection when the user clicks outside the song rows (header / footer / background).
    private func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.removeAll()
        selectAnchor = nil
    }

    private func toggleSelectAll() {
        if allSelected { selection.removeAll() }
        else { selection = Set(tracks.map(\.id)) }
    }

    private func enterSelection() {
        withAnimation { selection.removeAll(); isSelecting = true }
    }

    private func exitSelection() {
        withAnimation { isSelecting = false; selection.removeAll() }
    }

    private func likeSelected() {
        app.like(selectedTracks)
        exitSelection()
    }

    private func addSelected(to playlist: Playlist) {
        app.addToPlaylist(selectedTracks, playlist)
        exitSelection()
    }

    // MARK: - Actions

    private func startRename() {
        editedName = playlist.name
        showingRename = true
    }

    private func saveRename() {
        guard !editedName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? app.library.renamePlaylist(playlist, to: editedName)
    }

    private func removeTrack(_ track: Track) {
        guard let pair = validPairs.first(where: { $0.track.id == track.id }) else { return }
        try? app.library.removeEntry(pair.entry, from: playlist)
    }

    private func playAll(shuffle: Bool) {
        guard !tracks.isEmpty else { return }
        let start = shuffle ? Int.random(in: 0..<tracks.count) : 0
        app.queue.setQueue(tracks, startAt: start, shuffle: shuffle)
        Task { await app.player.play(track: app.queue.currentTrack ?? tracks[0]) }
    }

    private func placeholderRow(_ entry: PlaylistEntry) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.lumaInk(0.05))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 16))
                        .foregroundStyle(.lumaInk(0.3))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.trackTitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.lumaInk(0.4))
                    .lineLimit(1)
                if !entry.trackArtist.isEmpty {
                    Text(entry.trackArtist)
                        .font(.system(size: 13))
                        .foregroundStyle(.lumaInk(0.28))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private func exportThis() {
        exportDocument = PlaylistBackupDocument(data: app.library.makeBackupData(playlists: [playlist]) ?? Data())
        showingExporter = true
    }
}
