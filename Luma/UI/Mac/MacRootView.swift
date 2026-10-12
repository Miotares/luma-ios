#if os(macOS)
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum MacSection: Int, Hashable, CaseIterable, Identifiable {
    case library, search, playlists, statistics, settings
    var id: Self { self }

    /// 1-based index for the ⌘1…⌘5 menu shortcuts.
    var shortcut: Character { Character("\(rawValue + 1)") }

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

/// Sidebar entries for the macOS source list. The library is split into its sub-sections here
/// (Alben / Künstler / Songs / Gelikte Songs) instead of an in-view filter bar; each maps to a
/// `MacSection` (+ a `LibraryFilter` for the library ones) via `MacNavigationState.selectSidebar`.
enum MacSidebarItem: Hashable, Identifiable {
    case search
    case albums, artists, songs, liked
    case playlists           // the "Alle Playlists" overview (PlaylistsView)
    case playlist(UUID)      // a specific user playlist, listed under the Playlists section
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .search:    return "Suchen"
        case .albums:    return "Alben"
        case .artists:   return "Künstler"
        case .songs:     return "Songs"
        case .liked:     return "Gelikte Songs"
        case .playlists: return "Alle Playlists"
        case .playlist:  return ""   // rendered with the playlist's real name, not this
        }
    }
    var icon: String {
        switch self {
        case .search:    return "magnifyingglass"
        case .albums:    return "square.stack"
        case .artists:   return "music.microphone"
        case .songs:     return "music.note"
        case .liked:     return "heart"
        case .playlists: return "music.note.list"
        case .playlist:  return "music.note.list"
        }
    }
}

struct PlaylistExportRequest: Identifiable {
    let id = UUID()
    /// nil = all playlists.
    var playlistID: UUID?
}

/// Window-level navigation state for the macOS shell. Held once and shared with the menu-bar
/// commands (`LumaCommands`) so View-menu items (⌘1…⌘5, toggle queue) drive the same window.
@MainActor @Observable final class MacNavigationState {
    /// Opens on the user's preferred startup section (Settings → "Start-Ansicht").
    var section: MacSection = {
        let raw = UserDefaults.standard.object(forKey: MainTabView.startupTabKey) as? Int
        return raw == LumaTab.playlists.rawValue ? .playlists : .library
    }()
    var showingQueue = false
    /// The equalizer has no dedicated player surface on macOS, so it opens as a window sheet
    /// driven from the Playback menu (and Settings).
    var showingEqualizer = false
    /// Playlist import/export are triggered from the File menu (and the sidebar context menu), so
    /// the panels are hosted by `MacRootView` and work from any section.
    var showingPlaylistImporter = false
    /// Non-nil = export just these playlists; empty array = export all (menu-bar "alle").
    var playlistExportRequest: PlaylistExportRequest?
    /// Which library sub-section the sidebar has selected (Alben / Künstler / Songs / Gelikte
    /// Songs). Drives `LibraryView`'s content on macOS in place of its in-view filter bar.
    var libraryFilter: LibraryFilter = .albums
    /// The user playlist selected from the sidebar (nil = the "Alle Playlists" overview). Drives the
    /// playlists section's stack ROOT, so a sidebar pick replaces the root (no back button) the same
    /// way picking "Songs" does — see `MacRootView.detail`.
    var playlistID: UUID? = nil

    // Per-section navigation stacks, so each section remembers its own drill-down.
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var playlistsPath = NavigationPath()
    var settingsPath = NavigationPath()

    func select(_ s: MacSection) {
        // Re-selecting the active section pops it to its root (Finder-sidebar feel).
        if s == section { popToRoot(s) }
        section = s
    }

    func popToRoot(_ s: MacSection) {
        switch s {
        case .library:    libraryPath = NavigationPath()
        case .search:     searchPath = NavigationPath()
        case .playlists:  playlistsPath = NavigationPath()
        case .settings:   settingsPath = NavigationPath()
        case .statistics: break
        }
    }

    /// Maps a sidebar row to the section (and, for the library rows, the `LibraryFilter`) it drives.
    func selectSidebar(_ item: MacSidebarItem) {
        switch item {
        case .search:           select(.search)
        case .playlists:        selectPlaylistsOverview()
        case .playlist(let id): selectPlaylist(id)
        case .albums:           selectLibrary(.albums)
        case .artists:          selectLibrary(.artists)
        case .songs:            selectLibrary(.songs)
        case .liked:            selectLibrary(.liked)
        }
    }

    private func selectLibrary(_ f: LibraryFilter) {
        // Re-selecting the active library sub-section pops it to root (Finder-sidebar feel).
        if section == .library, libraryFilter == f { popToRoot(.library) }
        section = .library
        libraryFilter = f
    }

    /// Jump to the library "home" — the Alben grid at the root of the library stack. Used by the
    /// playlist detail's back button (a sidebar-opened playlist is its stack root and so has no
    /// native NavigationStack back button) to return to the Mediathek start page (= Alben).
    func goToLibraryHome() {
        section = .library
        libraryFilter = .albums
        libraryPath = NavigationPath()
    }

    /// "Alle Playlists" — the gallery overview (which also hosts the smart playlists).
    private func selectPlaylistsOverview() {
        if section == .playlists, playlistID == nil { popToRoot(.playlists) }
        section = .playlists
        playlistID = nil
    }

    /// A specific user playlist picked in the sidebar — shown as the playlists stack ROOT.
    private func selectPlaylist(_ id: UUID) {
        section = .playlists
        playlistID = id
        playlistsPath = NavigationPath()
    }

    /// The sidebar row reflecting the current section + library filter (nil for the menu-only
    /// Statistiken / Einstellungen sections, which have no sidebar entry).
    var sidebarSelection: MacSidebarItem? {
        switch section {
        case .search:    return .search
        case .playlists: return playlistID.map { .playlist($0) } ?? .playlists
        case .library:
            switch libraryFilter {
            case .albums:  return .albums
            case .artists: return .artists
            case .songs:   return .songs
            case .liked:   return .liked
            }
        case .statistics, .settings: return nil
        }
    }
}

/// Live geometry of the shell, written by the detail column's background GeometryReader and read
/// ONLY by `MacPillHost`. It lives in an @Observable box rather than `@State` on `MacRootView` so a
/// window resize / sidebar drag / inspector animation (which changes the frame every frame)
/// re-evaluates just the small pill host — not the whole shell body (sidebar + detail switch).
@MainActor @Observable final class MacShellMetrics {
    var detailFrame: CGRect = .zero
}

/// macOS shell: a native source-list sidebar (NavigationSplitView) replacing the iOS tab bar,
/// with a full-width now-playing bar pinned to the bottom and the queue as a trailing inspector.
/// The content views are shared with iOS; the chrome around them is desktop-native.
struct MacRootView: View {
    @Environment(AppContainer.self) private var app
    @Environment(MacNavigationState.self) private var nav
    /// User playlists shown directly in the sidebar's "Playlists" section (and resolved to the
    /// selected detail). Sorted like everywhere else by `sortIndex`.
    @Query(sort: \Playlist.sortIndex) private var playlists: [Playlist]
    @State private var didInitialScan = false
    /// Live frame of the detail column (in the shell's coordinate space), so the floating pill —
    /// which is hosted on the WHOLE split view (see body) — can be pinned to exactly this column
    /// and never the sidebar or the queue inspector. Re-measured on sidebar drag / window resize /
    /// inspector open-close. `body` must only WRITE it (never read) — see `MacShellMetrics`.
    @State private var metrics = MacShellMetrics()
    private static let shellSpace = "lumaMacShell"
    /// Pre-click snapshot of the sidebar selection, captured on mouse-DOWN (before the List mutates
    /// its selection) so a click that lands on the ALREADY-active row can be told apart from one
    /// that switches rows — see `reselectGesture`. `sidebarMirror` lags `nav.sidebarSelection` by a
    /// render (it's updated via `.onChange`), so reading it inside the down-gesture reliably yields
    /// the value as it was BEFORE this click, regardless of binding/gesture ordering.
    @State private var sidebarMirror: MacSidebarItem?
    @State private var preClickSidebar: MacSidebarItem?
    @State private var exportDocument: PlaylistBackupDocument?
    @State private var showingExporter = false
    @State private var exportFilename = "Luma Playlists"
    @State private var importMessage = ""
    @State private var showingImportResult = false

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .background(Color.lumaBackground.ignoresSafeArea())
                // Measure the detail column so the floating pill (overlaid on the WHOLE split view
                // below) can be pinned to exactly this column. A background GeometryReader doesn't
                // perturb layout and tracks every resize.
                .background {
                    // Measure the detail column into `metrics` (read by the pill host below).
                    // NOTE: this MUST be a direct write, not a PreferenceKey — preferences do NOT
                    // propagate out of the NavigationSplitView/NavigationStack to the outer overlay,
                    // so a preference-based version left the frame at .zero and the pill never
                    // appeared.
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { metrics.detailFrame = proxy.frame(in: .named(Self.shellSpace)) }
                            .onChange(of: proxy.frame(in: .named(Self.shellSpace))) { _, f in
                                metrics.detailFrame = f
                            }
                    }
                }
        }
        .coordinateSpace(.named(Self.shellSpace))
        // Floating Liquid-Glass pill (Apple-Music style). It is overlaid on the ENTIRE
        // NavigationSplitView — one host ABOVE every column and every pushed destination — rather
        // than on the detail NavigationStack itself. WHY: on macOS a NavigationStack push re-hosts
        // the pushed destination (e.g. AlbumDetailView's NSTableView-backed List) in its OWN AppKit
        // hosting context that does NOT inherit the container's safe-area reduction, so a
        // detail-level .safeAreaInset / ZStack-sibling / overlay is painted over by the pushed
        // List and the pill vanishes on push — every prior attempt failed for this reason. (The
        // root showed it fine because the stack ROOT does inherit the inset — even a root List,
        // e.g. "Songs", keeps the pill.) Hosting the pill on the split view itself puts it strictly
        // above all column hosts, so it survives any push. It is pinned to the measured detail
        // frame (leading = detailFrame.minX) so it stays in the detail column and shrinks with the
        // sidebar AND the queue inspector — never drawn over either. Scroll content still clears it
        // via lumaScrollClearance; this overlay reserves no layout space of its own.
        .overlay(alignment: .bottomLeading) { MacPillHost(metrics: metrics) }
        // Queue toggles from the now-playing bar, the ⌥⌘Q shortcut, and per-view header buttons.
        .environment(\.openNowPlaying) { nav.showingQueue.toggle() }
        .inspector(isPresented: $nav.showingQueue) {
            QueueView()
                .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
        }
        .sheet(isPresented: $nav.showingEqualizer) {
            EqualizerView()
                .environment(app)
        }
        .fileImporter(isPresented: $nav.showingPlaylistImporter, allowedContentTypes: [.json]) { handlePlaylistImport($0) }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { _ in }
        .onChange(of: nav.playlistExportRequest?.id) { _, _ in
            guard let request = nav.playlistExportRequest else { return }
            nav.playlistExportRequest = nil
            let selected = request.playlistID.map { id in playlists.filter { $0.id == id } }
            exportFilename = selected?.first?.name ?? "Luma Playlists"
            exportDocument = PlaylistBackupDocument(
                data: app.library.makeBackupData(playlists: selected) ?? Data())
            showingExporter = true
        }
        .alert("Playlists importiert", isPresented: $showingImportResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage)
        }
        .onAppear {
            guard !didInitialScan else { return }
            didInitialScan = true
            app.rescan()
        }
    }

    private func handlePlaylistImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url),
           let outcome = try? app.library.importBackup(data) {
            importMessage = outcome.created == 0
                ? String(localized: "Diese Playlists sind bereits vorhanden.")
                : String(localized: "\(outcome.created) Playlists importiert, \(outcome.placeholders) Titel noch nicht in der Mediathek.")
        } else {
            importMessage = String(localized: "Import fehlgeschlagen.")
        }
        showingImportResult = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var nav = nav
        return List(selection: Binding(
            get: { nav.sidebarSelection },
            set: { if let item = $0 { nav.selectSidebar(item) } }
        )) {
            // Suchen sits above the library (its own group → a divider before Mediathek).
            Section {
                sidebarRow(.search)
            }
            // The library's sub-sections live here now, not in an in-view filter bar.
            Section("Mediathek") {
                sidebarRow(.albums)
                sidebarRow(.artists)
                sidebarRow(.songs)
                sidebarRow(.liked)
            }
            // Playlists live in the sidebar by default: the "Alle Playlists" overview (which also
            // hosts the smart playlists) plus every user playlist, each opening its detail directly.
            Section("Playlists") {
                sidebarRow(.playlists)
                ForEach(playlists) { playlist in
                    playlistSidebarRow(playlist)
                }
            }
            // Statistiken + Einstellungen are intentionally NOT in the sidebar — they're reachable
            // from the menu bar (⌘, Einstellungen, and the "Ansicht" menu's ⌘4/⌘5).
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
        .listStyle(.sidebar)
        // Mirror the live selection (lagging by a render) so `reselectGesture` can snapshot the
        // PRE-click value on mouse-down — the List binding doesn't report a click on the already-
        // selected row, so that's the only way to detect a "click the active item again" re-click.
        .onAppear { sidebarMirror = nav.sidebarSelection }
        .onChange(of: nav.sidebarSelection) { _, new in sidebarMirror = new }
    }

    private func sidebarRow(_ item: MacSidebarItem) -> some View {
        Label(item.title, systemImage: item.icon)
            .tag(item)
            .simultaneousGesture(reselectGesture(item))
    }

    /// A user playlist row — labelled with the playlist's real name and tagged by its id so the
    /// selection binding routes to it via `MacNavigationState.selectPlaylist`.
    private func playlistSidebarRow(_ playlist: Playlist) -> some View {
        Label(playlist.name, systemImage: "music.note.list")
            .lineLimit(1)
            .tag(MacSidebarItem.playlist(playlist.id))
            .simultaneousGesture(reselectGesture(.playlist(playlist.id)))
            .contextMenu {
                Button {
                    nav.playlistExportRequest = PlaylistExportRequest(playlistID: playlist.id)
                } label: {
                    Label("Playlist exportieren", systemImage: "square.and.arrow.up")
                }
            }
    }

    /// "Click the already-selected sidebar item again → pop it to its root" (Finder/Music home-
    /// button feel). The `List(selection:)` binding never fires for a click on the active row (the
    /// value is unchanged), so this can't be driven from the binding. We snapshot the selection on
    /// mouse-DOWN (`onChanged`, before the List mutates it) and, on mouse-up, pop only when the
    /// click started on the row that was already active. A click that CHANGES the selection is left
    /// to the binding (`selectSidebar`), so each section keeps its own drill-down. Runs alongside
    /// the native selection click via `simultaneousGesture`, so normal selection is unaffected.
    private func reselectGesture(_ item: MacSidebarItem) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if preClickSidebar == nil { preClickSidebar = sidebarMirror }
            }
            .onEnded { value in
                let wasActive = (preClickSidebar == item)
                preClickSidebar = nil
                // Only a genuine click (not a drag, e.g. scrolling the sidebar) counts.
                let isTap = abs(value.translation.width) < 5 && abs(value.translation.height) < 5
                if wasActive && isTap { nav.selectSidebar(item) }
            }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        @Bindable var nav = nav
        switch nav.section {
        case .library:    NavigationStack(path: $nav.libraryPath) { LibraryView(resetSignal: 0) }
        case .search:     NavigationStack(path: $nav.searchPath) { SearchView() }
        case .playlists:
            NavigationStack(path: $nav.playlistsPath) {
                // A sidebar-selected playlist is the stack root; otherwise the overview gallery.
                // Resolve by live id so a deleted playlist falls back to the overview, never crashes.
                if let id = nav.playlistID, let playlist = playlists.first(where: { $0.id == id }) {
                    PlaylistDetailView(playlist: playlist)
                } else {
                    PlaylistsView()
                }
            }
        case .statistics: NavigationStack { StatisticsView() }
        case .settings:   NavigationStack(path: $nav.settingsPath) { SettingsView() }
        }
    }

}

/// Hosts the floating now-playing pill and owns every per-frame dependency of it (the measured
/// detail frame, the queue-open flag, whether a session is active), so those changes re-render
/// this view alone.
private struct MacPillHost: View {
    @Environment(AppContainer.self) private var app
    @Environment(MacNavigationState.self) private var nav
    let metrics: MacShellMetrics

    var body: some View {
        let frame = metrics.detailFrame
        ZStack(alignment: .bottomLeading) {
            if app.player.isActive, frame.width > 0 {
                MacNowPlayingBar(onOpen: { nav.showingQueue.toggle() }, isQueueOpen: nav.showingQueue)
                    .frame(width: max(frame.width - 24, 0))
                    .padding(.leading, frame.minX + 12)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: app.player.isActive)
    }
}
#endif
