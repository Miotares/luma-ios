import SwiftUI
import SwiftData

struct TrackRow: View, Equatable {
    let track: Track
    var showArtwork: Bool = false
    var showArtistName: Bool = true
    var showAlbum: Bool = false
    var showsMenu: Bool = false
    /// When true the row shows a leading selection circle and its tap is expected to
    /// toggle membership (the parent owns the actual selection set). Other affordances
    /// (trailing menu, context menu) are suppressed by the caller while selecting.
    var selectionMode: Bool = false
    var isSelected: Bool = false
    /// Playback-derived state, passed in by the parent (NOT read from `app.player` inside the
    /// row). Reading the player here subscribed EVERY row to playback, so starting a track
    /// re-ran all ~1500 row bodies (a multi-second freeze). With these as plain values + the
    /// `Equatable` conformance below, `.equatable()` lets SwiftUI skip every row whose inputs
    /// didn't change — so a track change re-renders only the 2 affected rows.
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    /// Snapshot of `track.isLiked` (a value, so Equatable can detect a like toggling).
    var liked: Bool = false
    var onTap: (() -> Void)?

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var modelContext

    @State private var albumSheet: Album?
    @State private var artistSheet: Artist?
    @State private var showMetadataEditor = false
    @State private var showDeleteConfirm = false
    @State private var isHovered = false

    // Compared by `.equatable()` — closures and @State are intentionally excluded. Title/artist
    // edits are rare and refresh on navigation; the keys here cover everything that changes live.
    static func == (l: TrackRow, r: TrackRow) -> Bool {
        l.track.persistentModelID == r.track.persistentModelID &&
        l.isCurrent == r.isCurrent && l.isPlaying == r.isPlaying && l.liked == r.liked &&
        l.selectionMode == r.selectionMode && l.isSelected == r.isSelected &&
        l.showArtwork == r.showArtwork && l.showAlbum == r.showAlbum &&
        l.showArtistName == r.showArtistName && l.showsMenu == r.showsMenu
    }

    var body: some View {
        let isCurrentTrack = isCurrent

        HStack(spacing: 4) {
            #if os(macOS)
            // A Button inside a List on macOS often needs the list focused before its
            // first click registers; a plain tap gesture fires immediately.
            rowLabel(isCurrentTrack: isCurrentTrack)
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
            #else
            Button { onTap?() } label: {
                rowLabel(isCurrentTrack: isCurrentTrack)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #endif

            if showsMenu {
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, isCurrentTrack ? 8 : 0)
        .background(
            isCurrentTrack ? Color.white.opacity(0.07)
                : (isHovered ? Color.white.opacity(0.05) : Color.clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, isCurrentTrack ? -8 : 0)
        .onHover { isHovered = $0 }
        .lumaApplyIf(!selectionMode) { $0.contextMenu { menuContent } }
        .sheet(item: $albumSheet) { album in
            NavigationStack { AlbumDetailView(album: album) }
        }
        .sheet(item: $artistSheet) { artist in
            NavigationStack { ArtistDetailView(artist: artist) }
        }
        .sheet(isPresented: $showMetadataEditor) {
            MetadataEditorView(track: track)
        }
        .alert("Titel löschen?", isPresented: $showDeleteConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                try? app.library.delete(track: track)
            }
        } message: {
            Text("\"\(track.title)\" wird endgültig aus der Mediathek entfernt.")
        }
    }

    /// Song artist from the track's own metadata (includes features); falls back to
    /// the album artist when the track has no song-artist tag.
    private var subtitleArtist: String {
        let a = track.artistName.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { return a }
        return (track.album?.artistName ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func rowLabel(isCurrentTrack: Bool) -> some View {
        HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? Color.lumaAccent : .white.opacity(0.30))
                    .transition(.scale.combined(with: .opacity))
            }
            leadingView(isCurrentTrack: isCurrentTrack)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 16))
                    .tracking(-0.25)
                    .foregroundStyle(.white)
                    .fontWeight(isCurrentTrack ? .bold : .regular)
                    .lineLimit(1)
                if showArtistName, !subtitleArtist.isEmpty {
                    Text(showAlbum && !track.albumTitle.isEmpty
                         ? "\(subtitleArtist) · \(track.albumTitle)"
                         : subtitleArtist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            if liked {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
            }

            Text(track.formattedDuration)
                .font(.system(size: 14).monospacedDigit())
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    // MARK: - Shared Menu

    @ViewBuilder
    private var menuContent: some View {
        // Fetch playlists lazily, only when a menu is actually opened — a per-row @Query
        // here meant thousands of live queries that all re-ran on every context save.
        let playlists = (try? modelContext.fetch(
            FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        Button {
            app.queue.playNext([track])
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            app.queue.append([track])
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        try? app.library.addTracks([track], to: playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zu Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }

        Button {
            try? app.library.toggleLike(track: track)
        } label: {
            Label(
                track.isLiked ? "Aus Favoriten entfernen" : "Titel speichern",
                systemImage: track.isLiked ? "heart.slash" : "heart"
            )
        }

        Button {
            showMetadataEditor = true
        } label: {
            Label("Informationen bearbeiten", systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Titel löschen", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .tint(.red)

        Button("Abbrechen", role: .cancel) {}
    }

    @ViewBuilder
    private func leadingView(isCurrentTrack: Bool) -> some View {
        if showArtwork {
            ZStack {
                ArtworkView(data: track.album?.artworkData, cacheKey: track.album?.id.uuidString, cornerRadius: 6, size: 44)
                if isCurrentTrack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.5))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        } else {
            Group {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.lumaAccent)
                } else {
                    Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "–")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.38))
                }
            }
            .frame(width: 34, alignment: .center)
        }
    }
}
