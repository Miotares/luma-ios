import SwiftUI
import SwiftData

// MARK: - Conditional modifier helper

extension View {
    /// Applies `transform` only when `condition` is true, otherwise returns the view
    /// unchanged. Lets a single modifier (a context menu, a swipe action) be gated on
    /// a flag without duplicating the whole row in an if/else.
    @ViewBuilder
    func lumaApplyIf<V: View>(_ condition: Bool, _ transform: (Self) -> V) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Bulk-selection action bar

/// Floating bottom bar shown while multi-selecting tracks in an album or playlist.
/// Offers the two bulk actions — add the selection to a playlist, or like it. Both
/// stay disabled until at least one track is selected.
struct TrackSelectionBar: View {
    let count: Int
    let onAddToPlaylist: () -> Void
    let onLike: () -> Void

    private var isEmpty: Bool { count == 0 }

    var body: some View {
        HStack(spacing: 10) {
            actionButton(title: "Zur Playlist", icon: "text.badge.plus", action: onAddToPlaylist)
            actionButton(title: "Liken", icon: "heart", action: onLike)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func actionButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    Color.lumaInk(isEmpty ? 0.04 : 0.12),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .foregroundStyle(isEmpty ? Color.lumaInk(0.3) : .lumaInk())
        }
        .buttonStyle(.plain)
        .disabled(isEmpty)
    }
}

// MARK: - Playlist picker (add selection to a playlist)

/// Sheet that lets the user drop the current selection into an existing playlist or a
/// freshly created one. `onPick` receives the chosen playlist; the caller performs the
/// actual add (so it owns which tracks are selected).
struct PlaylistPickerSheet: View {
    let onPick: (Playlist) -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    @Query(playlistTracksDescriptor()) private var playlistTracks: [Track]
    @State private var showingCreate = false
    @State private var newName = ""

    var body: some View {
        // Resolve entries through the safe inverse so the count matches the gallery/detail (which
        // show resolved tracks), not all entries incl. unimported placeholders.
        let map = validEntryTrackMap(playlistTracks)
        return NavigationStack {
            List {
                Section {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("Neue Playlist", systemImage: "plus")
                            .foregroundStyle(Color.lumaAccent)
                    }
                }
                .listRowBackground(Color.lumaInk(0.05))

                if !playlists.isEmpty {
                    Section {
                        ForEach(playlists) { playlist in
                            Button {
                                onPick(playlist)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(playlist.name)
                                        .foregroundStyle(.lumaInk())
                                    Spacer()
                                    Text(CountText.songs(playlist.safeSortedTracks(using: map).count))
                                        .font(.subheadline)
                                        .foregroundStyle(.lumaInk(0.4))
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.lumaInk(0.05))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Zur Playlist hinzufügen")
            .lumaInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .alert("Neue Playlist", isPresented: $showingCreate) {
                TextField("Name", text: $newName)
                Button("Erstellen") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    guard !name.isEmpty, let created = try? app.library.createPlaylist(name: name) else { return }
                    onPick(created)
                    dismiss()
                }
                Button("Abbrechen", role: .cancel) { newName = "" }
            }
        }
        .lumaForcedAppearance()
        .presentationDetents([.medium, .large])
    }
}
