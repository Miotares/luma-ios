import SwiftUI
import SwiftData

struct PlaylistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var allTracks: [Track]
    let playlist: Playlist

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var isEditing = false
    @State private var showingDeleteConfirm = false

    /// (entry, track) pairs resolved through the track→entry inverse, so entries whose
    /// track was deleted are skipped instead of crashing on `entry.track`.
    private var validPairs: [(entry: PlaylistEntry, track: Track)] {
        let map = validEntryTrackMap(allTracks)
        return playlist.entries
            .sorted { $0.order < $1.order }
            .compactMap { entry in map[entry.persistentModelID].map { (entry, $0) } }
    }
    private var tracks: [Track] { validPairs.map(\.track) }

    /// Duration of the VALID tracks only — `playlist.formattedDuration` would walk
    /// `sortedTracks` and crash on a dangling entry.
    private var tracksDuration: String {
        DurationText.hoursMinutes(tracks.reduce(0) { $0 + $1.duration })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DetailBackground(artworkData: tracks.first?.album?.artworkData)

            List {
                playlistHeader
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())

                ForEach(tracks) { track in
                    TrackRow(track: track, showArtwork: true, showAlbum: true, showsMenu: true) {
                        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
                        app.queue.setQueue(tracks, startAt: idx)
                        Task { await app.player.play(track: track) }
                    }
                    .frame(minHeight: 60)
                    .listRowBackground(Color.clear)
                    .trackRowSeparator()
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .contextMenu {
                        Button(role: .destructive) {
                            removeTrack(track)
                        } label: {
                            Label("Aus Playlist entfernen", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .tint(.red)
                    }
                    .trackQueueSwipeTrailing(
                        playNext: { app.queue.playNext([track]) },
                        addLast: { app.queue.append([track]) }
                    )
                }
                .onMove(perform: moveTracks)
                .onDelete(perform: deleteTracks)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .ignoresSafeArea(.container, edges: .top)
            .lumaScrollClearance(playerActive: app.player.state.isActive)
            #if os(iOS) || os(visionOS)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            #endif

            // Floating top bar: back (left) + options / done (right)
            HStack {
                LumaBackButton { dismiss() }
                Spacer()
                if isEditing {
                    Button("Fertig") { withAnimation { isEditing = false } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glassEffect(.regular, in: .capsule)
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
        .confirmationDialog("Playlist löschen?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Playlist löschen", role: .destructive) {
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

    private var playlistHeader: some View {
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
                Text(verbatim: "\(CountText.songs(count)) · \(tracksDuration)")
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
}
