import SwiftUI
import SwiftData

struct TrackRow: View {
    let track: Track
    var showArtwork: Bool = false
    var showArtistName: Bool = true
    var showAlbum: Bool = false
    var showsMenu: Bool = false
    var onTap: (() -> Void)?

    @Environment(AppContainer.self) private var app
    @Query(sort: \Playlist.createdDate, order: .reverse) private var playlists: [Playlist]

    @State private var albumSheet: Album?
    @State private var artistSheet: Artist?
    @State private var showMetadataEditor = false
    @State private var showDeleteConfirm = false

    var body: some View {
        let isCurrentTrack = track.id == app.player.currentTrack?.id

        HStack(spacing: 4) {
            Button { onTap?() } label: {
                rowLabel(isCurrentTrack: isCurrentTrack)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
            isCurrentTrack ? Color.white.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, isCurrentTrack ? -8 : 0)
        .contextMenu { menuContent }
        .sheet(item: $albumSheet) { album in
            NavigationStack { AlbumDetailView(album: album) }
        }
        .sheet(item: $artistSheet) { artist in
            NavigationStack { ArtistDetailView(artist: artist) }
        }
        .sheet(isPresented: $showMetadataEditor) {
            MetadataEditorView(track: track)
        }
        .confirmationDialog("Titel löschen?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                try? app.library.delete(track: track)
            }
            Button("Abbrechen", role: .cancel) {}
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

            if track.isLiked {
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
                ArtworkView(data: track.album?.artworkData, cornerRadius: 6, size: 44)
                if isCurrentTrack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.5))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: app.player.state.isPlaying)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        } else {
            Group {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: app.player.state.isPlaying)
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
