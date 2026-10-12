import SwiftUI
import SwiftData

// Long-press (iOS) / right-click (macOS) menu for an album card or row — mirrors the options menu
// behind the three-dots button in AlbumDetailView (play next / append / add to playlist / edit
// info / delete), so an album offers the same actions wherever it appears, without opening it
// first. ("Auswählen" stays in the album page: it is a mode of that page.)

private struct AlbumContextMenuModifier: ViewModifier {
    let album: Album
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var showingEditor = false
    @State private var showingDeleteConfirm = false

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .sheet(isPresented: $showingEditor) {
                AlbumMetadataEditorView(album: album)
            }
            // Direct delete is safe here (unlike AlbumDetailView, which defers to onDisappear): the
            // album lives in a @Query-backed ForEach, so removeAlbum just drops the card on the next
            // fetch — there is no detail view faulting the album's blobs mid-pop.
            .alert("Album löschen?", isPresented: $showingDeleteConfirm) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    try? app.library.removeAlbum(album)
                }
            } message: {
                // The album may already be gone when the alert's content is re-evaluated mid-dismiss.
                if album.modelContext != nil {
                    Text("\"\(album.title)\" und alle \(album.tracks.count) Titel werden entfernt.")
                }
            }
    }

    @ViewBuilder private var menu: some View {
        // Fetch playlists lazily — only when the menu actually opens — via the context. A per-card
        // @Query here meant ~150 live queries on the albums grid, all re-running on every context
        // save (the same trap TrackRow.menuContent documents).
        let playlists = (try? modelContext.fetch(
            FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        Button {
            app.playNext(album.sortedTracks)
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.addToQueue(album.sortedTracks)
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        app.addToPlaylist(album.sortedTracks, playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zur Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }
        Button {
            showingEditor = true
        } label: {
            Label("Albuminformationen bearbeiten", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            Label("Album löschen", systemImage: "trash")
        }
    }
}

extension View {
    /// Attaches the album options as a long-press / right-click menu (with its own edit-info
    /// sheet + delete confirmation). Goes on the NavigationLink's LABEL, not on the link — see the
    /// note in PlaylistContextMenu.swift.
    func albumContextMenu(_ album: Album) -> some View {
        modifier(AlbumContextMenuModifier(album: album))
    }
}
