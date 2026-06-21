import SwiftUI
import SwiftData

// MARK: - Smart Playlist Kinds

/// Auto-generated "smart" lists surfaced in the Playlists tab. Pure dynamic queries —
/// no persisted model, so there's nothing to migrate or keep in sync.
enum SmartPlaylistKind: Hashable {
    case mostPlayed
    case recentlyPlayed
    case recentlyAdded
    case liked
    case genre(String)
    case decade(Int)   // decade start year, e.g. 1990 → "1990s"

    var title: String {
        switch self {
        case .mostPlayed:     return String(localized: "Meistgespielt")
        case .recentlyPlayed: return String(localized: "Zuletzt gespielt")
        case .recentlyAdded:  return String(localized: "Zuletzt hinzugefügt")
        case .liked:          return String(localized: "Liked")
        case .genre(let g):   return g
        case .decade(let d):  return lumaDecadeLabel(d)
        }
    }

    var systemImage: String {
        switch self {
        case .mostPlayed:     return "flame.fill"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .recentlyAdded:  return "tray.and.arrow.down.fill"
        case .liked:          return "heart.fill"
        case .genre:          return "guitars.fill"
        case .decade:         return "calendar"
        }
    }

    var emptyText: LocalizedStringKey {
        switch self {
        case .liked: return "Songs die du magst erscheinen hier."
        default:     return "Noch keine Titel hier."
        }
    }

    /// Bounded fetch (like LibraryView.recentTracksDescriptor) so a smart list never
    /// scans the whole tracks table on the rolling sections.
    var descriptor: FetchDescriptor<Track> {
        // All these feed TrackRows, so prefetch `album` to avoid per-row main-thread faults.
        var d: FetchDescriptor<Track>
        switch self {
        case .mostPlayed:
            d = FetchDescriptor<Track>(
                predicate: #Predicate { $0.playCount > 0 },
                sortBy: [SortDescriptor(\.playCount, order: .reverse)]
            )
            d.fetchLimit = 100
        case .recentlyPlayed:
            d = FetchDescriptor<Track>(
                predicate: #Predicate { $0.lastPlayedDate != nil },
                sortBy: [SortDescriptor(\.lastPlayedDate, order: .reverse)]
            )
            d.fetchLimit = 100
        case .recentlyAdded:
            d = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.addedDate, order: .reverse)])
            d.fetchLimit = 100
        case .liked:
            d = FetchDescriptor<Track>(
                predicate: #Predicate { $0.isLiked == true },
                sortBy: [SortDescriptor(\.title)]
            )
        case .genre(let g):
            d = FetchDescriptor<Track>(
                predicate: #Predicate { $0.genre == g },
                sortBy: [SortDescriptor(\.artistName), SortDescriptor(\.albumTitle),
                         SortDescriptor(\.discNumber), SortDescriptor(\.trackNumber)]
            )
        case .decade(let dec):
            let lo = dec
            let hi = dec + 9
            d = FetchDescriptor<Track>(
                predicate: #Predicate { ($0.year ?? -1) >= lo && ($0.year ?? -1) <= hi },
                sortBy: [SortDescriptor(\.year), SortDescriptor(\.artistName),
                         SortDescriptor(\.albumTitle), SortDescriptor(\.trackNumber)]
            )
        }
        d.relationshipKeyPathsForPrefetching = [\.album]
        return d
    }
}

/// Decade label, e.g. 1990 → "1990er" (de) / "1990s" (en). Avoids a fiddly plural key.
func lumaDecadeLabel(_ decade: Int) -> String {
    let suffix = Locale.current.language.languageCode?.identifier == "de" ? "er" : "s"
    return "\(decade)\(suffix)"
}

/// Drill-down hubs (a list of genres / decades), pushed from the smart section.
enum SmartHub: Hashable { case genre, decade }

// MARK: - Configurable section kinds + visibility

/// The smart-list tiles the user can individually show/hide in Settings. Each maps to a
/// destination (a SmartPlaylistKind list, or a genre/decade hub).
enum SmartSectionKind: String, CaseIterable, Identifiable {
    case mostPlayed, recentlyPlayed, recentlyAdded, liked, genre, decade

    static let masterKey = "smartPlaylistsEnabled"

    var id: String { rawValue }
    var defaultsKey: String { "smartShow_" + rawValue }

    var title: String {
        switch self {
        case .mostPlayed:     return String(localized: "Meistgespielt")
        case .recentlyPlayed: return String(localized: "Zuletzt gespielt")
        case .recentlyAdded:  return String(localized: "Zuletzt hinzugefügt")
        case .liked:          return String(localized: "Liked")
        case .genre:          return String(localized: "Nach Genre")
        case .decade:         return String(localized: "Nach Jahrzehnt")
        }
    }

    var systemImage: String {
        switch self {
        case .mostPlayed:     return "flame.fill"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .recentlyAdded:  return "tray.and.arrow.down.fill"
        case .liked:          return "heart.fill"
        case .genre:          return "guitars.fill"
        case .decade:         return "calendar"
        }
    }
}

/// The smart-section kinds in the user's manual order (Settings drag-to-reorder), with any
/// newly added kinds appended in their default position.
func lumaSmartOrderedKinds(_ orderData: Data) -> [SmartSectionKind] {
    let raws = (try? JSONDecoder().decode([String].self, from: orderData)) ?? []
    var result = raws.compactMap(SmartSectionKind.init(rawValue:))
    for kind in SmartSectionKind.allCases where !result.contains(kind) { result.append(kind) }
    return result
}

func lumaEncodeSmartOrder(_ kinds: [SmartSectionKind]) -> Data {
    (try? JSONEncoder().encode(kinds.map(\.rawValue))) ?? Data()
}

// MARK: - Smart Playlists Section (Playlists tab)

/// Horizontal rail of smart-list tiles above the user's own playlists. Each tile is gated
/// on its per-kind visibility setting; genre/decade tiles also require that metadata to
/// exist (flags from the parent, which already holds the tracks @Query). The whole section
/// is hidden by the parent when the master switch is off.
struct SmartPlaylistsSection: View {
    let hasGenres: Bool
    let hasYears: Bool

    @AppStorage("smartShow_mostPlayed")     private var showMostPlayed = true
    @AppStorage("smartShow_recentlyPlayed") private var showRecentlyPlayed = true
    @AppStorage("smartShow_recentlyAdded")  private var showRecentlyAdded = true
    @AppStorage("smartShow_liked")          private var showLiked = true
    @AppStorage("smartShow_genre")          private var showGenre = true
    @AppStorage("smartShow_decade")         private var showDecade = true
    @AppStorage("smartOrder")               private var orderData = Data()

    private func isOn(_ k: SmartSectionKind) -> Bool {
        switch k {
        case .mostPlayed:     return showMostPlayed
        case .recentlyPlayed: return showRecentlyPlayed
        case .recentlyAdded:  return showRecentlyAdded
        case .liked:          return showLiked
        case .genre:          return showGenre
        case .decade:         return showDecade
        }
    }

    private var visibleKinds: [SmartSectionKind] {
        lumaSmartOrderedKinds(orderData).filter { k in
            guard isOn(k) else { return false }
            switch k {
            case .genre:  return hasGenres
            case .decade: return hasYears
            default:      return true
            }
        }
    }

    var body: some View {
        let kinds = visibleKinds
        if kinds.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Smart-Playlists")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.35)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(kinds) { kind in
                            tile(for: kind)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for k: SmartSectionKind) -> some View {
        let label = SmartPlaylistTile(title: k.title, systemImage: k.systemImage)
        switch k {
        case .mostPlayed:     NavigationLink(value: SmartPlaylistKind.mostPlayed) { label }.buttonStyle(.plain)
        case .recentlyPlayed: NavigationLink(value: SmartPlaylistKind.recentlyPlayed) { label }.buttonStyle(.plain)
        case .recentlyAdded:  NavigationLink(value: SmartPlaylistKind.recentlyAdded) { label }.buttonStyle(.plain)
        case .liked:          NavigationLink(value: SmartPlaylistKind.liked) { label }.buttonStyle(.plain)
        case .genre:          NavigationLink(value: SmartHub.genre) { label }.buttonStyle(.plain)
        case .decade:         NavigationLink(value: SmartHub.decade) { label }.buttonStyle(.plain)
        }
    }
}

private struct SmartPlaylistTile: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.lumaSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                    )
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 112, height: 112)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .padding(.top, 7)
                .frame(width: 112, alignment: .leading)
        }
    }
}

// MARK: - Smart Playlist Settings

/// Sheet: master switch for the smart section + a toggle per list.
struct SmartPlaylistSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SmartSectionKind.masterKey) private var enabled = true
    @AppStorage("smartShow_mostPlayed")     private var showMostPlayed = true
    @AppStorage("smartShow_recentlyPlayed") private var showRecentlyPlayed = true
    @AppStorage("smartShow_recentlyAdded")  private var showRecentlyAdded = true
    @AppStorage("smartShow_liked")          private var showLiked = true
    @AppStorage("smartShow_genre")          private var showGenre = true
    @AppStorage("smartShow_decade")         private var showDecade = true
    @AppStorage("smartOrder")               private var orderData = Data()

    private func binding(for k: SmartSectionKind) -> Binding<Bool> {
        switch k {
        case .mostPlayed:     return $showMostPlayed
        case .recentlyPlayed: return $showRecentlyPlayed
        case .recentlyAdded:  return $showRecentlyAdded
        case .liked:          return $showLiked
        case .genre:          return $showGenre
        case .decade:         return $showDecade
        }
    }

    /// Native List reorder — shift the kinds and persist the new order.
    private func move(from source: IndexSet, to destination: Int) {
        var kinds = lumaSmartOrderedKinds(orderData)
        kinds.move(fromOffsets: source, toOffset: destination)
        orderData = lumaEncodeSmartOrder(kinds)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $enabled) {
                        Text("Smart-Playlists anzeigen").foregroundStyle(.white)
                    }
                    .tint(Color.lumaToggle)
                    .listRowBackground(Color.lumaSurface)
                }

                if enabled {
                    Section {
                        // Native List reorder (same as the Queue): the rows shift and you can
                        // grab a whole row to move it. The Toggle switch stays tappable.
                        ForEach(lumaSmartOrderedKinds(orderData), id: \.self) { kind in
                            Toggle(isOn: binding(for: kind)) {
                                HStack(spacing: 12) {
                                    Image(systemName: kind.systemImage)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .frame(width: 24)
                                    Text(kind.title).foregroundStyle(.white)
                                }
                            }
                            .tint(Color.lumaToggle)
                            .listRowBackground(Color.lumaSurface)
                        }
                        .onMove(perform: move)
                    } header: {
                        Text("Sichtbare Listen").foregroundStyle(.white.opacity(0.45))
                    } footer: {
                        Text("Ziehe eine Liste am Griff, um die Reihenfolge zu ändern.")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.lumaBackground.ignoresSafeArea())
            #if os(iOS) || os(visionOS)
            // Always-on edit mode so the reorder grips show (matches the Queue); macOS reorders
            // via .onMove without it.
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Smart-Playlists")
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
}

// MARK: - Smart Playlist Detail

/// Read-only track list for a smart playlist. Mirrors LikedSongsView's list, with a
/// detail header + floating back button so it works pushed onto the Playlists stack.
struct SmartPlaylistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let kind: SmartPlaylistKind
    @Query private var tracks: [Track]

    init(kind: SmartPlaylistKind) {
        self.kind = kind
        _tracks = Query(kind.descriptor)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.lumaBackground.ignoresSafeArea()

            if tracks.isEmpty {
                emptyState
            } else {
                List {
                    header
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 116, leading: 20, bottom: 6, trailing: 20))
                    PlayShuffleHeader(tracks: tracks)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                    ForEach(tracks) { track in
                        TrackRow(track: track, showArtwork: true, showsMenu: true,
                                 isCurrent: track.id == app.player.currentTrack?.id,
                                 isPlaying: app.player.state.isPlaying, liked: track.isLiked) { play(track) }
                            .equatable()
                            .frame(minHeight: 56)
                            .listRowBackground(Color.clear)
                            .trackRowSeparator()
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .trackQueueSwipeTrailing(
                                playNext: { app.queue.playNext([track]) },
                                addLast: { app.queue.append([track]) }
                            )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #if os(iOS) || os(visionOS)
                .ignoresSafeArea(.container, edges: .top)
                #endif
                .lumaScrollClearance(playerActive: app.player.isActive)
            }

            HStack {
                LumaBackButton { dismiss() }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(CountText.songs(tracks.count))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.2))
            Text(kind.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.4))
            Text(kind.emptyText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private func play(_ track: Track) {
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(tracks, startAt: idx)
        Task { await app.player.play(track: track) }
    }
}

// MARK: - Genre / Decade Hub

/// Lists the distinct genres (or decades) in the library, each linking to its smart list.
struct SmartHubView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var allTracks: [Track]
    let hub: SmartHub

    private struct HubEntry: Identifiable {
        let title: String
        let kind: SmartPlaylistKind
        let count: Int
        var id: SmartPlaylistKind { kind }
    }

    private var entries: [HubEntry] {
        switch hub {
        case .genre:
            var counts: [String: Int] = [:]
            for t in allTracks {
                guard let g = t.genre?.trimmingCharacters(in: .whitespaces), !g.isEmpty else { continue }
                counts[g, default: 0] += 1
            }
            return counts.keys.sorted(by: lumaTitleBefore)
                .map { HubEntry(title: $0, kind: .genre($0), count: counts[$0] ?? 0) }
        case .decade:
            var counts: [Int: Int] = [:]
            for t in allTracks {
                guard let y = t.year else { continue }
                counts[(y / 10) * 10, default: 0] += 1
            }
            return counts.keys.sorted(by: >)
                .map { HubEntry(title: lumaDecadeLabel($0), kind: .decade($0), count: counts[$0] ?? 0) }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.lumaBackground.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry.kind) {
                            HStack(spacing: 14) {
                                Text(entry.title)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(CountText.songs(entry.count))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.4))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 54)
                        }
                        .buttonStyle(LumaRowStyle())
                        LumaSeparator(leadingPad: 20)
                    }
                }
                .padding(.top, 64)
                .padding(.bottom, 20)
            }
            .lumaScrollClearance(playerActive: app.player.isActive)

            HStack {
                LumaBackButton { dismiss() }
                Spacer()
                Text(hub == .genre ? "Nach Genre" : "Nach Jahrzehnt")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .lumaInlineNavTitle()
        .lumaHiddenNavBarBackground()
        .lumaHideBackButton()
        .interactiveSwipeBack()
        .background(Color.lumaBackground.ignoresSafeArea())
    }
}
