import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct PlaylistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var allTracks: [Track]
    let playlist: Playlist

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var isEditing = false
    @State private var showingDeleteConfirm = false

    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showingPlaylistPicker = false
    @State private var showingExporter = false
    @State private var exportDocument: PlaylistBackupDocument?

    /// (entry, track) pairs resolved through the track→entry inverse, so entries whose
    /// track was deleted are skipped instead of crashing on `entry.track`.
    /// Resolves the playlist's entries against the library in a SINGLE pass over one
    /// `validEntryTrackMap(allTracks)` build — pairs, placeholders and the unresolved flag at
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
        let map = validEntryTrackMap(allTracks)
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

    var body: some View {
        let r = resolved
        let trackList = r.tracks
        return ZStack(alignment: .topLeading) {
            DetailBackground(artworkData: trackList.first?.album?.artworkData)

            List {
                playlistHeader(tracks: trackList)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())

                ForEach(trackList) { track in
                    trackRow(track)
                }
                .onMove(perform: moveTracks)
                .onDelete(perform: deleteAction)

                if !r.placeholders.isEmpty {
                    Text("Nicht in der Mediathek")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 20, leading: 18, bottom: 8, trailing: 16))
                    ForEach(r.placeholders) { entry in
                        placeholderRow(entry)
                            .frame(minHeight: 56)
                            .listRowBackground(Color.clear)
                            .trackRowSeparator()
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS) || os(visionOS)
            .ignoresSafeArea(.container, edges: .top)
            #endif
            .lumaScrollClearance(playerActive: app.player.state.isActive)
            #if os(iOS) || os(visionOS)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            #endif
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    TrackSelectionBar(
                        count: selection.count,
                        onAddToPlaylist: { showingPlaylistPicker = true },
                        onLike: likeSelected
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: isSelecting)

            // Floating top bar: back / select-all (left) + options / done (right)
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
        // Transparent (not hidden) bar keeps the native interactive swipe-back.
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
        .onAppear { editedName = playlist.name }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistPickerSheet(onPick: addSelected(to:))
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
    }

    // MARK: - Options Menu

    @ViewBuilder
    private var playlistMenu: some View {
        Button {
            app.queue.playNext(tracks)
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.queue.append(tracks)
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
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
        Button {
            editedName = playlist.name
            isEditingName = true
        } label: {
            Label("Umbenennen", systemImage: "pencil")
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
        var entries = validPairs.map(\.entry)
        entries.move(fromOffsets: source, toOffset: destination)
        try? app.library.reorderEntries(entries)
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
            PlaylistArtworkView(tracks: tracks, cornerRadius: 12)
                .frame(width: 220, height: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)

            VStack(alignment: .leading, spacing: 0) {
                if isEditingName {
                    TextField("Playlist Name", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .onSubmit { saveRename() }
                } else {
                    Text(playlist.name)
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .onTapGesture { isEditingName = true; editedName = playlist.name }
                }

                Text(verbatim: "\(CountText.songs(tracks.count)) · \(tracksDuration(tracks))")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    playlistActionButton(label: "Abspielen", icon: "play.fill", primary: true) { playAll(shuffle: false) }
                        .frame(width: 160)
                    playlistActionButton(label: "Shuffle", icon: "shuffle", primary: false) { playAll(shuffle: true) }
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
    #endif

    private func iosPlaylistHeader(tracks: [Track]) -> some View {
        VStack(spacing: 18) {
            PlaylistArtworkView(tracks: tracks, cornerRadius: 20)
                .frame(width: 210, height: 210)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.55), radius: 30, y: 20)
                .padding(.top, 112)

            VStack(spacing: 6) {
                if isEditingName {
                    TextField("Playlist Name", text: $editedName)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .onSubmit { saveRename() }
                } else {
                    Text(playlist.name)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .onTapGesture {
                            isEditingName = true
                            editedName = playlist.name
                        }
                }

                let count = tracks.count
                Text(verbatim: "\(CountText.songs(count)) · \(tracksDuration(tracks))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
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
                    primary ? Color.white : Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .foregroundStyle(primary ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection

    private var selectedTracks: [Track] {
        tracks.filter { selection.contains($0.id) }
    }

    /// `nil` while selecting so the list's swipe-to-delete is suppressed in selection mode.
    private var deleteAction: ((IndexSet) -> Void)? {
        if isSelecting { return nil }
        return { offsets in deleteTracks(offsets) }
    }

    private var allSelected: Bool {
        !tracks.isEmpty && selection.count == tracks.count
    }

    private var selectionTitleKey: LocalizedStringKey {
        selection.isEmpty ? "Auswählen" : "\(selection.count) ausgewählt"
    }

    /// One playlist track row — selectable while in selection mode (tap toggles, no
    /// swipe/remove), otherwise the normal play row with remove + queue-swipe actions.
    @ViewBuilder
    private func trackRow(_ track: Track) -> some View {
        let row = TrackRow(
            track: track,
            showArtwork: true,
            showAlbum: true,
            showsMenu: !isSelecting,
            selectionMode: isSelecting,
            isSelected: selection.contains(track.id)
        ) {
            if isSelecting {
                toggleSelection(track)
            } else {
                guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
                app.queue.setQueue(tracks, startAt: idx)
                Task { await app.player.play(track: track) }
            }
        }
        .frame(minHeight: 60)
        .listRowBackground(Color.clear)
        .trackRowSeparator()
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

        row
            .lumaApplyIf(!isSelecting) {
                $0.contextMenu {
                    Button(role: .destructive) {
                        removeTrack(track)
                    } label: {
                        Label("Aus Playlist entfernen", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }
            }
            .lumaApplyIf(!isSelecting) {
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
        else { selection = Set(tracks.map(\.id)) }
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

    private func saveRename() {
        isEditingName = false
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
                .fill(.white.opacity(0.05))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.3))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.trackTitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                if !entry.trackArtist.isEmpty {
                    Text(entry.trackArtist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.28))
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
