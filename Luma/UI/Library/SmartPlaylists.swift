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
            // Higher cap than the other rolling lists so the genre filter has real coverage:
            // "Meistgespielt · Rock" should surface played Rock tracks even when they sit below
            // the very top of the global play-count ranking (still bounded + lazily rendered).
            d.fetchLimit = 500
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

/// The secondary axis a smart list can be narrowed by. Genre-agnostic lists (most-played,
/// liked, a decade) narrow by **genre**; a single-genre list narrows by **decade** — the
/// same "Rock aus den 80ern" result, just reached from the other direction.
enum SmartFilterAxis { case genre, decade }

extension SmartPlaylistKind {
    /// Which axis the detail view offers as an in-list filter (nil = no filter rail).
    var filterAxis: SmartFilterAxis? {
        switch self {
        case .mostPlayed, .liked, .decade:    return .genre
        case .genre:                          return .decade
        case .recentlyPlayed, .recentlyAdded: return nil
        }
    }
}

private extension Track {
    /// Trimmed, non-empty genre (matches the hub's aggregation), or nil.
    var lumaFilterGenre: String? {
        guard let g = genre?.trimmingCharacters(in: .whitespaces), !g.isEmpty else { return nil }
        return g
    }
    /// Decade start year, e.g. 1987 → 1980 (matches the hub's `(y / 10) * 10`).
    var lumaFilterDecade: Int? { year.map { ($0 / 10) * 10 } }
}

/// Drill-down hubs (a list of genres / decades), pushed from the smart section.
enum SmartHub: Hashable { case genre, decade }

// MARK: - Configurable section kinds + visibility

/// The smart-list tiles the user can individually show/hide in Settings. Each maps to a
/// destination (a SmartPlaylistKind list, or a genre/decade hub).
enum SmartSectionKind: String, CaseIterable, Identifiable {
    // Declaration order is the default tile order (used by `lumaSmartOrderedKinds` until the
    // user drags a custom order in Settings). `recentlyPlayed` isn't in the requested default
    // five, so it trails at the end. Raw values stay fixed, so persistence is unaffected.
    case mostPlayed, genre, decade, recentlyAdded, liked, recentlyPlayed

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

    private var orderedKinds: [SmartSectionKind] { lumaSmartOrderedKinds(orderData) }

    /// Full-bleed row separators. The native List separators are inset by the row's content
    /// margins (and the edit-mode reorder grip), so they don't reach the screen edges. Drawing
    /// them into the row background instead — which spans the whole cell width — makes them run
    /// edge-to-edge, matching the surface box. `topSeparator` adds a line above a section's
    /// first row so the block is capped top and bottom.
    private func rowBackground(topSeparator: Bool = false) -> some View {
        Color.lumaSurface
            .overlay(alignment: .top) { separatorLine.opacity(topSeparator ? 1 : 0) }
            .overlay(alignment: .bottom) { separatorLine }
    }

    private var separatorLine: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $enabled) {
                        Text("Smart-Playlists anzeigen").foregroundStyle(.white)
                    }
                    .tint(Color.lumaToggle)
                    .listRowSeparator(.hidden)
                    .listRowBackground(rowBackground(topSeparator: true))
                }

                if enabled {
                    Section {
                        // Native List reorder (same as the Queue): the rows shift and you can
                        // grab a whole row to move it. The Toggle switch stays tappable.
                        ForEach(orderedKinds, id: \.self) { kind in
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
                            .listRowSeparator(.hidden)
                            .listRowBackground(rowBackground(topSeparator: kind == orderedKinds.first))
                        }
                        .onMove(perform: move)
                    } header: {
                        Text("Sichtbare Listen").foregroundStyle(.white.opacity(0.45))
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

// MARK: - Filter chip

/// Pill toggle for the smart-list filter rail. "On" mirrors the primary play button
/// (white fill / black text) so the active filter reads at a glance on the dark UI.
private struct LumaFilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(isOn ? .black : .white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOn ? Color.lumaAccent : Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(isOn ? 0 : 0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

// MARK: - Smart Playlist Detail

/// Read-only track list for a smart playlist. Mirrors LikedSongsView's list, with a
/// detail header + floating back button so it works pushed onto the Playlists stack.
///
/// Kinds with a `filterAxis` (most-played / liked / decade → genre; genre → decade) gain a
/// horizontal filter rail. Filtering is done **in-memory over the already-fetched set**, so
/// the chip options are exactly the genres/decades present in this list — no empty surprises,
/// no extra SwiftData queries, and it works uniformly for every kind without a predicate per
/// combination. Selection is multi-select (union) and resets when the view is left.
struct SmartPlaylistDetailView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let kind: SmartPlaylistKind
    @Query private var tracks: [Track]

    /// One selection store keyed by each chip's stable key (a genre string, or a decade as a
    /// string). Folding both axes into a single set keeps the body's handling uniform — only
    /// the active axis is ever populated. Resets when the view is left.
    @State private var selectedKeys: Set<String> = []

    init(kind: SmartPlaylistKind) {
        self.kind = kind
        _tracks = Query(kind.descriptor)
    }

    // MARK: Filter derivation

    /// A filter chip: a stable key for selection plus its display label.
    private struct FilterOption: Identifiable {
        let key: String
        let title: String
        var id: String { key }
    }

    /// Distinct filter options present in the fetched set for this kind's axis — genres A→Z,
    /// or decades newest-first; [] for kinds without an axis (so no scan happens). Called once
    /// per body pass and the result is reused, so the set isn't re-derived on every read.
    private func filterOptions(for axis: SmartFilterAxis?) -> [FilterOption] {
        switch axis {
        case .genre:
            var set = Set<String>()
            for t in tracks { if let g = t.lumaFilterGenre { set.insert(g) } }
            return set.sorted(by: lumaTitleBefore).map { FilterOption(key: $0, title: $0) }
        case .decade:
            var set = Set<Int>()
            for t in tracks { if let d = t.lumaFilterDecade { set.insert(d) } }
            return set.sorted(by: >).map { FilterOption(key: String($0), title: lumaDecadeLabel($0)) }
        case .none:
            return []
        }
    }

    /// The track's value on the active axis, as the same key the options use.
    private func filterKey(_ t: Track, axis: SmartFilterAxis?) -> String? {
        switch axis {
        case .genre:  return t.lumaFilterGenre
        case .decade: return t.lumaFilterDecade.map { String($0) }
        case .none:   return nil
        }
    }

    var body: some View {
        let axis = kind.filterAxis
        let options = filterOptions(for: axis)
        let optionKeys = options.map(\.key)
        let shown: [Track] = selectedKeys.isEmpty
            ? tracks
            : tracks.filter { filterKey($0, axis: axis).map(selectedKeys.contains) ?? false }
        let activeTitles = options.filter { selectedKeys.contains($0.key) }.map(\.title)

        ZStack(alignment: .topLeading) {
            Color.lumaBackground.ignoresSafeArea()

            if tracks.isEmpty {
                emptyState
            } else {
                List {
                    header(count: shown.count, activeTitles: activeTitles)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 116, leading: 20, bottom: 6, trailing: 20))
                    if options.count >= 2 {
                        filterRail(options)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                    }
                    if shown.isEmpty {
                        // Only reachable transiently — the filter options are derived from this
                        // very set, so clicking chips can't empty it; but if the library mutates
                        // under an active selection, keep the rail usable instead of a blank list.
                        Text("Keine Titel für diese Auswahl")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 40, leading: 20, bottom: 20, trailing: 20))
                    } else {
                        PlayShuffleHeader(tracks: shown)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                        ForEach(shown) { track in
                            TrackRow(track: track, showArtwork: true, showsMenu: true,
                                     isCurrent: track.id == app.player.currentTrack?.id,
                                     isPlaying: app.player.state.isPlaying, liked: track.isLiked) { play(track, in: shown) }
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
        // If the library changes under us, drop any selection whose chip has vanished so the
        // filter can't stick on an option that's no longer offered. Driven off the keys we
        // already computed above (no extra scan); only the active axis ever has selections.
        .onChange(of: optionKeys) { _, keys in
            if !selectedKeys.isEmpty { selectedKeys.formIntersection(Set(keys)) }
        }
    }

    // MARK: Filter rail

    private func filterRail(_ options: [FilterOption]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LumaFilterChip(title: String(localized: "Alle"), isOn: selectedKeys.isEmpty) { clearFilter() }
                ForEach(options) { opt in
                    LumaFilterChip(title: opt.title, isOn: selectedKeys.contains(opt.key)) { toggle(opt.key) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func clearFilter() {
        withAnimation(.easeInOut(duration: 0.2)) { selectedKeys.removeAll() }
    }
    private func toggle(_ key: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if selectedKeys.contains(key) { selectedKeys.remove(key) } else { selectedKeys.insert(key) }
        }
    }

    // MARK: Header / empty / play

    private func header(count: Int, activeTitles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(activeTitles.isEmpty
                 ? CountText.songs(count)
                 : activeTitles.joined(separator: ", ") + " · " + CountText.songs(count))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
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

    private func play(_ track: Track, in list: [Track]) {
        guard let idx = list.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(list, startAt: idx)
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
                        LumaSeparator(leadingPad: 0)
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
