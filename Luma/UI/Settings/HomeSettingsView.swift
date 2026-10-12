import SwiftUI
import SwiftData

/// Home (Library tab) customization: default album layout, show/hide the Recently-Added
/// section, and which playlists are pinned to the top of the home screen — and in which order.
/// All settings live in UserDefaults and are read live by LibraryView via @AppStorage.
struct HomeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]

    @AppStorage("homeAlbumList")         private var albumAsList = false
    @AppStorage("homeShowRecentlyAdded") private var showRecentlyAdded = true
    /// JSON `[UUID]` — the pinned playlists IN THE ORDER they appear on the home screen.
    @AppStorage("homePinnedPlaylists")   private var pinnedData = Data()

    /// Stored order, without repeats (a repeat would show the playlist twice).
    private var pinnedIDs: [UUID] {
        var seen = Set<UUID>()
        return ((try? JSONDecoder().decode([UUID].self, from: pinnedData)) ?? []).filter { seen.insert($0).inserted }
    }

    /// The pinned playlists that still exist, in home-screen order.
    private var pinned: [Playlist] {
        let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pinnedIDs.compactMap { byID[$0] }
    }

    private var unpinned: [Playlist] {
        let ids = Set(pinnedIDs)
        return playlists.filter { !ids.contains($0.id) }
    }

    /// Always written from the playlists that still exist, so ids of deleted ones drop out.
    private func store(_ list: [Playlist]) {
        pinnedData = (try? JSONEncoder().encode(list.map(\.id))) ?? Data()
    }

    private func pin(_ playlist: Playlist) {
        // A quick second tap can land on the row before it has moved up to the pinned section.
        guard !pinnedIDs.contains(playlist.id) else { return }
        withAnimation { store(pinned + [playlist]) }
    }

    private func unpin(_ playlist: Playlist) {
        withAnimation { store(pinned.filter { $0.id != playlist.id }) }
    }

    private func movePinned(from source: IndexSet, to destination: Int) {
        var list = pinned
        list.move(fromOffsets: source, toOffset: destination)
        store(list)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $albumAsList) {
                            Text("Kachel").tag(false)
                            Text("Liste").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Wie Alben auf der Startseite standardmäßig angezeigt werden.")
                            .font(.caption)
                            .foregroundStyle(.lumaInk(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.lumaSurface)
                } header: {
                    header("Album-Ansicht")
                }

                Section {
                    Toggle(isOn: $showRecentlyAdded) {
                        Text("Zuletzt hinzugefügt anzeigen").foregroundStyle(.lumaInk())
                    }
                    .tint(Color.lumaToggle)
                    .listRowBackground(Color.lumaSurface)
                } header: {
                    header("Abschnitte")
                }

                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { playlist in
                            playlistRow(playlist, isPinned: true)
                        }
                        .onMove(perform: movePinned)
                    } header: {
                        header("Angeheftete Playlists")
                    } footer: {
                        footer("Ziehe eine Playlist am Griff, um die Reihenfolge auf der Startseite zu ändern.")
                    }
                }

                if !unpinned.isEmpty {
                    Section {
                        ForEach(unpinned) { playlist in
                            playlistRow(playlist, isPinned: false)
                        }
                    } header: {
                        header(pinned.isEmpty ? "Playlists anheften" : "Weitere Playlists")
                    } footer: {
                        footer("Angeheftete Playlists erscheinen oben auf der Startseite.")
                    }
                }
            }
            #if os(iOS) || os(visionOS)
            .listStyle(.insetGrouped)
            // Permanently in "edit" mode so the pinned rows always show their drag handle —
            // sorting them is what that section is for.
            .environment(\.editMode, .constant(.active))
            #endif
            .scrollContentBackground(.hidden)
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Startseite")
            .lumaInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .lumaForcedAppearance()
        .presentationDetents([.medium, .large])
    }

    private func playlistRow(_ playlist: Playlist, isPinned: Bool) -> some View {
        HStack {
            Text(playlist.name).foregroundStyle(.lumaInk()).lineLimit(1)
            Spacer(minLength: 12)
            Button {
                if isPinned { unpin(playlist) } else { pin(playlist) }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 15))
                    .foregroundStyle(isPinned ? Color.lumaToggle : .lumaInk(0.28))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            // Borderless: only the pin reacts, not the whole row (which is being dragged).
            .buttonStyle(.borderless)
            .accessibilityLabel(isPinned ? "Nicht mehr anheften" : "Anheften")
        }
        .listRowBackground(Color.lumaSurface)
    }

    private func header(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key).uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.lumaInk(0.4))
    }

    private func footer(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.lumaInk(0.35))
    }
}
