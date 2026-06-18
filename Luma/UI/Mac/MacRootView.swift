#if os(macOS)
import SwiftUI

enum MacSection: Hashable, CaseIterable, Identifiable {
    case library, search, playlists, statistics, settings
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .library:    return "Mediathek"
        case .search:     return "Suchen"
        case .playlists:  return "Playlists"
        case .statistics: return "Statistiken"
        case .settings:   return "Einstellungen"
        }
    }
    var icon: String {
        switch self {
        case .library:    return "square.grid.2x2"
        case .search:     return "magnifyingglass"
        case .playlists:  return "list.bullet"
        case .statistics: return "chart.bar"
        case .settings:   return "gearshape"
        }
    }
}

/// macOS shell: a sidebar (NavigationSplitView) replacing the iOS tab bar, with a
/// full-width now-playing bar pinned to the bottom. The content views are shared with iOS.
struct MacRootView: View {
    @Environment(AppContainer.self) private var app
    @State private var section: MacSection = .library
    @State private var showingQueue = false
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var didInitialScan = false

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(MacSection.allCases) { item in
                    Button { selectSection(item) } label: {
                        Label(item.title, systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(section == item ? 0.1 : 0))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
            .scrollContentBackground(.hidden)
            .background(Color.lumaBackground)
        } detail: {
            detail
                .background(Color.lumaBackground.ignoresSafeArea())
        }
        .environment(\.openNowPlaying) { showingQueue = true }
        .inspector(isPresented: $showingQueue) {
            QueueView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if app.player.state.isActive {
                MacNowPlayingBar(onOpen: { showingQueue.toggle() })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.smooth(duration: 0.3), value: app.player.state.isActive)
        .onAppear {
            guard !didInitialScan else { return }
            didInitialScan = true
            app.rescan()
        }
    }

    private func selectSection(_ s: MacSection) {
        resetPath(s)
        section = s
    }

    private func resetPath(_ s: MacSection) {
        switch s {
        case .library:    libraryPath = NavigationPath()
        case .search:     searchPath = NavigationPath()
        case .playlists:  playlistsPath = NavigationPath()
        case .settings:   settingsPath = NavigationPath()
        case .statistics: break
        }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .library:    NavigationStack(path: $libraryPath) { LibraryView(resetSignal: 0) }
        case .search:     NavigationStack(path: $searchPath) { SearchView() }
        case .playlists:  NavigationStack(path: $playlistsPath) { PlaylistsView() }
        case .statistics: NavigationStack { StatisticsView() }
        case .settings:   NavigationStack(path: $settingsPath) { SettingsView() }
        }
    }
}
#endif
