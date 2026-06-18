#if os(macOS)
import SwiftUI

enum MacSection: Hashable {
    case library, search, playlists, statistics, settings
}

/// macOS shell: a sidebar (NavigationSplitView) replacing the iOS tab bar, with a
/// full-width now-playing bar pinned to the bottom. The content views are shared with iOS.
struct MacRootView: View {
    @Environment(AppContainer.self) private var app
    @State private var section: MacSection? = .library
    @State private var showingPlayer = false
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var didInitialScan = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Mediathek", systemImage: "square.grid.2x2").tag(MacSection.library)
                Label("Suchen", systemImage: "magnifyingglass").tag(MacSection.search)
                Label("Playlists", systemImage: "list.bullet").tag(MacSection.playlists)
                Label("Statistiken", systemImage: "chart.bar").tag(MacSection.statistics)
                Label("Einstellungen", systemImage: "gearshape").tag(MacSection.settings)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
            .scrollContentBackground(.hidden)
            .background(Color.lumaBackground)
        } detail: {
            detail
                .background(Color.lumaBackground.ignoresSafeArea())
        }
        .environment(\.openNowPlaying) { showingPlayer = true }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if app.player.state.isActive {
                MacNowPlayingBar(onOpen: { showingPlayer = true })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.smooth(duration: 0.3), value: app.player.state.isActive)
        .sheet(isPresented: $showingPlayer) {
            PlayerView()
                .frame(minWidth: 440, idealWidth: 480, minHeight: 660, idealHeight: 720)
        }
        .onAppear {
            guard !didInitialScan else { return }
            didInitialScan = true
            app.rescan()
        }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .library {
        case .library:    NavigationStack(path: $libraryPath) { LibraryView(resetSignal: 0) }
        case .search:     NavigationStack(path: $searchPath) { SearchView() }
        case .playlists:  NavigationStack(path: $playlistsPath) { PlaylistsView() }
        case .statistics: NavigationStack { StatisticsView() }
        case .settings:   NavigationStack(path: $settingsPath) { SettingsView() }
        }
    }
}
#endif
