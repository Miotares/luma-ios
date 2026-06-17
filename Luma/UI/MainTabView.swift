import SwiftUI

// MARK: - Design Tokens

extension Color {
    static let lumaBackground = Color(red: 0.051, green: 0.051, blue: 0.067)
    static let lumaSurface    = Color(red: 0.098, green: 0.102, blue: 0.133)
    static let lumaAccent     = Color.white   // neutral accent — app-wide, no blue tint
}

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

    private var miniPlayerActive: Bool { app.player.state.isActive }

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
            Tab(LumaTab.playlists.title, systemImage: LumaTab.playlists.icon, value: .playlists) {
                NavigationStack(path: $playlistsPath) { PlaylistsView() }
                    .lumaMiniPlayer(isActive: miniPlayerActive) { showingPlayer = true }
            }
            Tab(LumaTab.search.title, systemImage: LumaTab.search.icon, value: .search) {
                NavigationStack(path: $searchPath) { SearchView() }
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
        contentMargins(.bottom, playerActive ? 92 : 50, for: .scrollContent)
            .contentMargins(.top, top, for: .scrollContent)
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
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                // Without this the hit area collapses to the glyph (the glass circle is
                // decoration, not a tappable fill) — taps miss and the button feels dead.
                .contentShape(Rectangle())
                .glassEffect(.regular, in: .circle)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
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
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
    }
}

/// Thin separator used between rows
struct LumaSeparator: View {
    var leadingPad: CGFloat = 76

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, leadingPad)
    }
}
