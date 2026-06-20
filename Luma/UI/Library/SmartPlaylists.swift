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
    case year(Int)

    var title: String {
        switch self {
        case .mostPlayed:     return String(localized: "Meistgespielt")
        case .recentlyPlayed: return String(localized: "Zuletzt gespielt")
        case .recentlyAdded:  return String(localized: "Zuletzt hinzugefügt")
        case .liked:          return String(localized: "Liked")
        case .genre(let g):   return g
        case .year(let y):    return String(y)
        }
    }

    var systemImage: String {
        switch self {
        case .mostPlayed:     return "flame.fill"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .recentlyAdded:  return "clock.badge.plus.fill"
        case .liked:          return "heart.fill"
        case .genre:          return "guitars.fill"
        case .year:           return "calendar"
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
        switch self {
        case .mostPlayed:
            var d = FetchDescriptor<Track>(
                predicate: #Predicate { $0.playCount > 0 },
                sortBy: [SortDescriptor(\.playCount, order: .reverse)]
            )
            d.fetchLimit = 100
            return d
        case .recentlyPlayed:
            var d = FetchDescriptor<Track>(
                predicate: #Predicate { $0.lastPlayedDate != nil },
                sortBy: [SortDescriptor(\.lastPlayedDate, order: .reverse)]
            )
            d.fetchLimit = 100
            return d
        case .recentlyAdded:
            var d = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.addedDate, order: .reverse)])
            d.fetchLimit = 100
            return d
        case .liked:
            return FetchDescriptor<Track>(
                predicate: #Predicate { $0.isLiked == true },
                sortBy: [SortDescriptor(\.title)]
            )
        case .genre(let g):
            return FetchDescriptor<Track>(
                predicate: #Predicate { $0.genre == g },
                sortBy: [SortDescriptor(\.artistName), SortDescriptor(\.albumTitle),
                         SortDescriptor(\.discNumber), SortDescriptor(\.trackNumber)]
            )
        case .year(let y):
            let target: Int? = y
            return FetchDescriptor<Track>(
                predicate: #Predicate { $0.year == target },
                sortBy: [SortDescriptor(\.artistName), SortDescriptor(\.albumTitle),
                         SortDescriptor(\.discNumber), SortDescriptor(\.trackNumber)]
            )
        }
    }
}

/// Drill-down hubs (a list of genres / years), pushed from the smart section.
enum SmartHub: Hashable { case genre, year }

// MARK: - Smart Playlists Section (Playlists tab)

/// Horizontal rail of smart-list tiles shown above the user's own playlists. Genre/Year
/// tiles are gated on whether any track actually carries that metadata (flags passed in
/// from the parent, which already holds the tracks @Query — no extra fetch here).
struct SmartPlaylistsSection: View {
    let hasGenres: Bool
    let hasYears: Bool

    private var fixedKinds: [SmartPlaylistKind] {
        [.mostPlayed, .recentlyPlayed, .recentlyAdded, .liked]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Smart-Playlists")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.35)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(fixedKinds, id: \.self) { kind in
                        NavigationLink(value: kind) {
                            SmartPlaylistTile(title: kind.title, systemImage: kind.systemImage)
                        }
                        .buttonStyle(.plain)
                    }
                    if hasGenres {
                        NavigationLink(value: SmartHub.genre) {
                            SmartPlaylistTile(title: String(localized: "Nach Genre"), systemImage: "guitars.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    if hasYears {
                        NavigationLink(value: SmartHub.year) {
                            SmartPlaylistTile(title: String(localized: "Nach Jahr"), systemImage: "calendar")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
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
                        .listRowInsets(EdgeInsets(top: 70, leading: 20, bottom: 6, trailing: 20))
                    PlayShuffleHeader(tracks: tracks)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
                    ForEach(tracks) { track in
                        TrackRow(track: track, showArtwork: true, showsMenu: true) { play(track) }
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
                .lumaScrollClearance(playerActive: app.player.state.isActive)
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private func play(_ track: Track) {
        guard let idx = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        app.queue.setQueue(tracks, startAt: idx)
        Task { await app.player.play(track: track) }
    }
}

// MARK: - Genre / Year Hub

/// Lists the distinct genres (or years) in the library, each linking to its smart list.
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
        case .year:
            var counts: [Int: Int] = [:]
            for t in allTracks {
                guard let y = t.year else { continue }
                counts[y, default: 0] += 1
            }
            return counts.keys.sorted(by: >)
                .map { HubEntry(title: String($0), kind: .year($0), count: counts[$0] ?? 0) }
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
            .lumaScrollClearance(playerActive: app.player.state.isActive)

            HStack {
                LumaBackButton { dismiss() }
                Spacer()
                Text(hub == .genre ? "Nach Genre" : "Nach Jahr")
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
