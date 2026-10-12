import SwiftUI

// Design tokens (lumaBackground / lumaSurface / lumaAccent / lumaInk …) live in
// UI/Theme/LumaTheme.swift — appearance-adaptive so macOS can follow the system light/dark.

// MARK: - Open Now Playing Environment Key

struct OpenNowPlayingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openNowPlaying: () -> Void {
        get { self[OpenNowPlayingKey.self] }
        set { self[OpenNowPlayingKey.self] = newValue }
    }
}

/// What the player's "Album/Künstler anzeigen" should open as a FULL page.
enum LibraryNavTarget { case album(Album); case artist(Artist) }

/// Action the player invokes to open an album/artist as a normal full-screen page on the
/// Mediathek tab (exactly like opening it from the home screen) — closing the player sheet
/// first, since pushing inside the sheet would still leave a swipe-down "card".
struct OpenLibraryItemKey: EnvironmentKey {
    static let defaultValue: (LibraryNavTarget) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLibraryItem: (LibraryNavTarget) -> Void {
        get { self[OpenLibraryItemKey.self] }
        set { self[OpenLibraryItemKey.self] = newValue }
    }
}

// MARK: - Tab Model

enum LumaTab: Int, CaseIterable {
    case library, search, playlists, settings

    var title: String {
        switch self {
        case .library:   return String(localized: "Mediathek")
        case .search:    return String(localized: "Suchen")
        case .playlists: return String(localized: "Playlists")
        case .settings:  return String(localized: "Einstellungen")
        }
    }

    var icon: String {
        switch self {
        case .library:   return "square.grid.2x2"
        case .search:    return "magnifyingglass"
        case .playlists: return "list.bullet"
        case .settings:  return "gearshape"
        }
    }
}

/// Marker route for the (value-less) Statistics screen pushed inside the Settings tab.
struct StatisticsRoute: Hashable {}

// MARK: - Main Tab View

struct MainTabView: View {
    @Environment(AppContainer.self) private var app
    @State private var selectedTab: LumaTab
    @State private var showingPlayer = false
    @State private var storeWasReset = false

    static let startupTabKey = "startupTab"

    init() {
        let raw = UserDefaults.standard.object(forKey: MainTabView.startupTabKey) as? Int
            ?? LumaTab.library.rawValue
        _selectedTab = State(initialValue: LumaTab(rawValue: raw) ?? .library)
        _storeWasReset = State(initialValue: UserDefaults.standard.bool(forKey: LumaApp.storeWasResetKey))
    }

    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var playlistsPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var libraryResetSignal = 0

    private var miniPlayerActive: Bool { app.player.isActive }

    /// The player asks to open an album/artist as a full page on the Mediathek tab (just like from
    /// the home screen). Put the destination in place FIRST — while the player sheet is still fully
    /// up and stable, where pushing is reliable — then close the player on the NEXT runloop tick.
    /// The sheet then slides away to REVEAL the already-built page, instead of waiting for the full
    /// dismissal to finish and only THEN pushing (three serial animations = the laggy feel).
    ///
    /// The async hop is essential: doing the push and `showingPlayer = false` in one transaction
    /// would mutate the path WHILE the sheet tears down, which can drop the push (the failure the
    /// old deferred-onDismiss approach worked around). Splitting them into two transactions lets the
    /// push commit against a stable tree first.
    private func openLibraryFromPlayer(_ target: LibraryNavTarget) {
        selectedTab = .library
        switch target {
        case .album(let album):   libraryPath.append(album)
        case .artist(let artist): libraryPath.append(artist)
        }
        DispatchQueue.main.async { showingPlayer = false }
    }

    /// Tapping the already-selected tab pops it to root; on Mediathek it also resets
    /// the filter back to "Alben".
    private var tabSelection: Binding<LumaTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    switch newValue {
                    case .library:   libraryPath = NavigationPath(); libraryResetSignal += 1
                    case .playlists: playlistsPath = NavigationPath()
                    case .search:    searchPath = NavigationPath()
                    case .settings:  settingsPath = NavigationPath()
                    }
                }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab(LumaTab.library.title, systemImage: LumaTab.library.icon, value: .library) {
                NavigationStack(path: $libraryPath) { LibraryView(resetSignal: libraryResetSignal) }
                    .lumaMiniPlayer(isActive: miniPlayerActive) { showingPlayer = true }
            }
            Tab(LumaTab.search.title, systemImage: LumaTab.search.icon, value: .search) {
                NavigationStack(path: $searchPath) { SearchView() }
                    .lumaMiniPlayer(isActive: miniPlayerActive) { showingPlayer = true }
            }
            Tab(LumaTab.playlists.title, systemImage: LumaTab.playlists.icon, value: .playlists) {
                NavigationStack(path: $playlistsPath) { PlaylistsView() }
                    .lumaMiniPlayer(isActive: miniPlayerActive) { showingPlayer = true }
            }
            Tab(LumaTab.settings.title, systemImage: LumaTab.settings.icon, value: .settings) {
                NavigationStack(path: $settingsPath) { SettingsView() }
                    .lumaMiniPlayer(isActive: miniPlayerActive) { showingPlayer = true }
            }
        }
        .tint(Color.lumaAccent)
        .environment(\.openNowPlaying) { showingPlayer = true }
        .sheet(isPresented: $showingPlayer) {
            PlayerView()
                // Inject the "open album/artist" action directly on the sheet's CONTENT. Environment
                // values applied mid-tree (e.g. on the TabView above) do NOT cross the sheet boundary
                // here — same reason every other sheet re-injects `.environment(app)`. Without this,
                // PlayerView sees the default no-op and the "Album/Künstler anzeigen" buttons are dead.
                .environment(\.openLibraryItem, openLibraryFromPlayer)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
        .alert("Mediathek zurückgesetzt", isPresented: $storeWasReset) {
            Button("OK") { UserDefaults.standard.set(false, forKey: LumaApp.storeWasResetKey) }
        } message: {
            Text("Die Bibliotheksdaten konnten nicht geladen werden und wurden zurückgesetzt. Eine Sicherung der alten Daten wurde angelegt — bitte importiere deine Musik bei Bedarf erneut.")
        }
    }
}

// MARK: - Scroll Bottom Clearance

extension View {
    /// Bottom inset so the floating tab bar and mini-player never cover the last
    /// scrolled item. The two values are tuned by eye — adjust if a gap or overlap shows.
    func lumaScrollClearance(playerActive: Bool, top: CGFloat = 0) -> some View {
        #if os(macOS)
        // macOS `List` (NSTableView-backed) doesn't reliably honor
        // `contentMargins(.bottom, …, for: .scrollContent)`, so the floating player pill covered
        // the last row. A clear bottom safe-area inset spacer reliably reserves the space for
        // BOTH List and ScrollView. ~96pt clears the ~66pt pill + its 12pt bottom inset + a gap.
        return self
            .safeAreaInset(edge: .top, spacing: 0) {
                // `List` ignores contentMargins(.top, .scrollContent) on macOS, so the header's
                // ~22pt bottom fade covered the first row (e.g. the Play/Shuffle header). Reserve
                // the top via a safe-area spacer instead; +12 over the requested inset clears the
                // fade with a gap (0 when nothing was requested — those views pad their own top).
                Color.clear.frame(height: top > 0 ? top + 12 : 0)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: playerActive ? 104 : 16)
            }
        #else
        return contentMargins(.bottom, playerActive ? 92 : 50, for: .scrollContent)
            .contentMargins(.top, top, for: .scrollContent)
        #endif
    }
}

// MARK: - Mini-Player (floating bar above the tab bar)

extension View {
    /// Floats the mini-player just above the tab bar via `safeAreaInset` — a custom
    /// Liquid-Glass bar rather than the native `tabViewBottomAccessory`.
    ///
    /// WHY NOT the native accessory: attaching it shows an empty glass capsule when
    /// idle, and conditionally attaching it rebuilds the `TabView` the first time
    /// playback starts — which recreates the pushed detail view and snaps its scroll
    /// position back to the top. Here the `safeAreaInset` modifier is ALWAYS present
    /// (only its content is gated on `isActive`), so nothing in the view tree is
    /// structurally added/removed: no rebuild, no scroll jump, and no empty bar.
    func lumaMiniPlayer(isActive: Bool, open: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isActive {
                MiniPlayer(onTap: open)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: isActive)
    }
}

// MARK: - Shared Custom Components

/// Floating back button for detail views (no system nav bar needed)
struct LumaBackButton: View {
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        // macOS draws a native toolbar back button in the NavigationStack, so the custom
        // floating one would be a duplicate.
        EmptyView()
        #else
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.lumaInk())
                .frame(width: 36, height: 36)
                // Without this the hit area collapses to the glyph (the glass circle is
                // decoration, not a tappable fill) — taps miss and the button feels dead.
                .contentShape(Rectangle())
                .glassEffect(.regular, in: .circle)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        #endif
    }
}

/// Immediate press feedback for icon / transport buttons so taps feel direct and
/// snappy instead of mushy. Reacts on touch-down, independent of any async action.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // No scale/spring — a squish reads as "spongy". Just an instant dim.
            .opacity(configuration.isPressed ? 0.45 : 1)
            .contentShape(Rectangle())
            // Kill SwiftUI's default press-transition animation: it would otherwise
            // fade the dim AND sweep the button's own state change (play↔pause,
            // like) into a slow transaction — exactly the "spongy" feel reported.
            .animation(nil, value: configuration.isPressed)
    }
}

/// Row press-highlight style (replaces List cell highlight)
struct LumaRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        LumaRowStyleBody(configuration: configuration)
        #else
        configuration.label
            .background(configuration.isPressed ? Color.lumaInk(0.06) : Color.clear)
            .contentShape(Rectangle())
        #endif
    }

    #if os(macOS)
    /// macOS rows get an INSET, rounded hover/press pill (Apple-Music / Finder style) instead of a
    /// full-bleed bar. A full-width highlight ran flush to the translucent sidebar (the detail
    /// column spans the whole window width under it) and bled under the navbar; insetting the pill
    /// keeps the marker inside the main view with a clear margin from the sidebar. Hover feedback
    /// mirrors the track rows so every list reacts the same way. The hit area stays full-width
    /// (contentShape on the label) so clicking anywhere in the row still triggers it.
    private struct LumaRowStyleBody: View {
        let configuration: Configuration
        @State private var isHovered = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(configuration.isPressed ? Color.lumaInk(0.09)
                              : (isHovered ? Color.lumaInk(0.05) : Color.clear))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .onHover { isHovered = $0 }
        }
    }
    #endif
}

/// Thin separator used between rows
struct LumaSeparator: View {
    var leadingPad: CGFloat = 76

    var body: some View {
        Rectangle()
            .fill(.lumaInk(0.07))
            .frame(height: 0.5)
            .padding(.leading, leadingPad)
    }
}

/// Shared empty-state content (icon + title + optional subtitle) so every "nothing here" screen
/// looks identical — previously Search, Liked Songs, Playlists and the smart lists each rolled
/// their own sizes/weights/alignment. Content-only: the caller supplies the surrounding layout
/// (Spacers, a ScrollView, or a list row) for its context.
struct LumaEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.lumaInk(0.15))
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.lumaInk(0.35))
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.lumaInk(0.2))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
