import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Long-press (iOS) / right-click (macOS) menus for a playlist and an artist wherever they appear
// as a card or row — the same actions as the "…" menu on their detail page, without opening it
// first. (Modes that only exist inside the detail page — "Auswählen", "Bearbeiten" — stay there.)
//
// APPLY THESE INSIDE THE NavigationLink's LABEL, not on the link: attached to the link itself, a
// long press on the playlist cards (a link in a plain VStack inside a ScrollView) never opened
// the menu on iOS — it just followed the link on release. Inside the label (with a contentShape)
// it opens. Verified in the simulator, cause not understood.
// The album counterpart is `albumContextMenu` (AlbumContextMenu.swift); track rows carry their
// own (TrackRow).

private struct PlaylistContextMenuModifier: ViewModifier {
    let playlist: Playlist
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var modelContext
    @State private var showingRename = false
    @State private var editedName = ""
    @State private var showingCoverEditor = false
    @State private var showingDeleteConfirm = false
    @State private var showingExporter = false
    @State private var exportDocument: PlaylistBackupDocument?

    func body(content: Content) -> some View {
        content
            .contextMenu { menu }
            .sheet(isPresented: $showingCoverEditor) {
                PlaylistCoverEditor(playlist: playlist, tracks: resolvedTracks())
                    .environment(app)
            }
            .fileExporter(isPresented: $showingExporter, document: exportDocument,
                          contentType: .json, defaultFilename: playlist.modelContext == nil ? "Playlist" : playlist.name) { _ in }
            .alert("Playlist löschen?", isPresented: $showingDeleteConfirm) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    try? app.library.deletePlaylist(playlist)
                }
            } message: {
                Text("\"\(playlist.modelContext == nil ? "" : playlist.name)\" wird gelöscht. Die Titel bleiben in der Mediathek.")
            }
            .alert("Playlist umbenennen", isPresented: $showingRename) {
                TextField("Name", text: $editedName)
                Button("Sichern") {
                    guard !editedName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    try? app.library.renamePlaylist(playlist, to: editedName)
                }
                Button("Abbrechen", role: .cancel) {}
            }
    }

    /// The playlist's tracks in order, resolved when an action needs them (not while the card is
    /// built) and through the safe track→entry path, so an entry whose track is gone is skipped.
    private func resolvedTracks() -> [Track] {
        let inPlaylists = (try? modelContext.fetch(playlistTracksDescriptor())) ?? []
        return playlist.safeSortedTracks(using: validEntryTrackMap(inPlaylists))
    }

    @ViewBuilder private var menu: some View {
        Button {
            app.playNext(resolvedTracks())
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.addToQueue(resolvedTracks())
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Button {
            editedName = playlist.name
            showingRename = true
        } label: {
            Label("Umbenennen", systemImage: "pencil")
        }
        Button {
            showingCoverEditor = true
        } label: {
            Label("Cover ändern", systemImage: "photo")
        }
        Button {
            exportDocument = PlaylistBackupDocument(data: app.library.makeBackupData(playlists: [playlist]) ?? Data())
            showingExporter = true
        } label: {
            Label("Playlist exportieren", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            Label("Playlist löschen", systemImage: "trash")
        }
    }
}

private struct ArtistContextMenuModifier: ViewModifier {
    let artist: Artist
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.contextMenu { menu }
    }

    private func allTracks() -> [Track] {
        artist.sortedAlbums.flatMap { $0.sortedTracks }
    }

    @ViewBuilder private var menu: some View {
        let playlists = (try? modelContext.fetch(
            FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        Button {
            app.playNext(allTracks())
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.addToQueue(allTracks())
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        app.addToPlaylist(allTracks(), playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zur Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }
    }
}

extension View {
    /// The playlist options as a long-press / right-click menu (with its own rename, cover,
    /// export and delete-confirmation UI). Goes on the link's LABEL — see the note at the top.
    func playlistContextMenu(_ playlist: Playlist) -> some View {
        modifier(PlaylistContextMenuModifier(playlist: playlist))
    }

    /// The artist options as a long-press / right-click menu.
    func artistContextMenu(_ artist: Artist) -> some View {
        modifier(ArtistContextMenuModifier(artist: artist))
    }
}
