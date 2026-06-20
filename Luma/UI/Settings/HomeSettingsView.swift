import SwiftUI
import SwiftData

/// Home (Library tab) customization: default album layout, show/hide the Recently-Added
/// section, and which playlists are pinned to the top of the home screen. All settings live
/// in UserDefaults and are read live by LibraryView via @AppStorage.
struct HomeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]

    @AppStorage("homeAlbumList")         private var albumAsList = false
    @AppStorage("homeShowRecentlyAdded") private var showRecentlyAdded = true
    @AppStorage("homePinnedPlaylists")   private var pinnedData = Data()

    private var pinnedIDs: [UUID] {
        (try? JSONDecoder().decode([UUID].self, from: pinnedData)) ?? []
    }

    private func togglePin(_ id: UUID) {
        var ids = pinnedIDs
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        pinnedData = (try? JSONEncoder().encode(ids)) ?? Data()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    label("Album-Ansicht")
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $albumAsList) {
                            Text("Kachel").tag(false)
                            Text("Liste").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Text("Wie Alben auf der Startseite standardmäßig angezeigt werden.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)

                    label("Abschnitte")
                    Toggle(isOn: $showRecentlyAdded) {
                        Text("Zuletzt hinzugefügt anzeigen").foregroundStyle(.white)
                    }
                    .tint(Color.lumaToggle)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
                    .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)

                    if !playlists.isEmpty {
                        label("Angeheftete Playlists")
                        VStack(spacing: 0) {
                            ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                                Button { togglePin(playlist.id) } label: {
                                    HStack {
                                        Text(playlist.name).foregroundStyle(.white).lineLimit(1)
                                        Spacer(minLength: 12)
                                        Image(systemName: pinnedIDs.contains(playlist.id) ? "pin.fill" : "pin")
                                            .font(.system(size: 15))
                                            .foregroundStyle(pinnedIDs.contains(playlist.id) ? Color.lumaToggle : .white.opacity(0.28))
                                    }
                                    .padding(.horizontal, 20)
                                    .frame(minHeight: 50)
                                }
                                .buttonStyle(LumaRowStyle())
                                if index < playlists.count - 1 { LumaSeparator(leadingPad: 20) }
                            }
                        }
                        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 16)

                        Text("Angeheftete Playlists erscheinen oben auf der Startseite.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                }
                .padding(.vertical, 12)
                .padding(.bottom, 20)
            }
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
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func label(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key).uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}
