import SwiftUI
import SwiftData
import StoreKit

@main
struct LumaApp: App {
    let modelContainer: ModelContainer
    /// Owned by the App (not RootView) so menu-bar commands can reach the same instance.
    @State private var container: AppContainer
    #if os(macOS)
    /// Window navigation shared between the shell and the menu-bar `LumaCommands`.
    @State private var macNav = MacNavigationState()
    /// Provides the Dock right-click transport menu.
    @NSApplicationDelegateAdaptor(LumaAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// Set when the store had to be reset on launch, so the UI can inform the user once.
    static let storeWasResetKey = "lumaStoreWasReset"

    init() {
        let schema = Schema([Track.self, Album.self, Artist.self, Playlist.self, PlaylistEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let created: ModelContainer
        do {
            created = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // An incompatible/corrupt store (failed migration, corrupt WAL after an OS kill)
            // would otherwise crash on every launch. Move the existing store ASIDE — never
            // delete it, the library is the user's only copy — so it stays recoverable, flag
            // it so the UI can tell the user, then rebuild.
            LumaApp.moveStoreAside(at: config.url)
            UserDefaults.standard.set(true, forKey: LumaApp.storeWasResetKey)
            do {
                created = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("SwiftData failed after store reset: \(error)")
            }
        }
        modelContainer = created
        _container = State(initialValue: AppContainer(modelContext: created.mainContext))
    }

    /// Moves the store (and its -shm/-wal sidecars) into a timestamped backup folder rather
    /// than deleting it, so a failed migration or corrupt WAL never destroys the library.
    private static func moveStoreAside(at url: URL) {
        let fm = FileManager.default
        let backupDir = url.deletingLastPathComponent()
            .appendingPathComponent("RecoveredStores", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.moveItem(at: src, to: backupDir.appendingPathComponent(src.lastPathComponent))
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                #if os(macOS)
                .environment(macNav)
                // Floor the window size so it can't be shrunk into the unusable state where the
                // detail header runs out of room (the title wraps and the cover slides down). The
                // window can still grow freely / go full-screen — only the minimum is fixed (see
                // .windowResizability(.contentMinSize) below). 1040 keeps the album header intact
                // EVEN with the queue inspector open (which eats ~340pt of the detail): at this
                // floor the play/shuffle buttons have collapsed to icons but the title + cover
                // still lay out correctly. Verified at the boundary — 920 breaks, 1040 holds.
                .frame(minWidth: 1040, minHeight: 600)
                #endif
                .modelContainer(modelContainer)
                .tint(Color.lumaAccent)
                .lumaForcedAppearance()
                .onChange(of: scenePhase) { oldPhase, phase in
                    // Persist the play head + playback stats whenever we leave the foreground,
                    // so a background-kill still resumes where the user left off and keeps the
                    // play/listen counts (stats are coalesced, not saved on every tick).
                    if phase != .active {
                        container.savePlaybackState()
                        container.saveStats()
                    }
                    // iOS only: let the player idle its engine when backgrounding-while-paused. It
                    // KEEPS the audio session active so it stays the Now-Playing app and resumable
                    // from the lock screen / AirPods (paused state is reported via now-playing rate).
                    switch phase {
                    case .background:
                        container.enterBackground()
                    case .active:
                        container.enterForeground()
                    case .inactive:
                        // Coming back from the background, the app becomes VISIBLE at .inactive
                        // (app-switcher / unlock) BEFORE .active fires. Re-project the play head
                        // already here so the scrubber is at the correct position on the first live
                        // frame, instead of briefly showing the frozen background value and visibly
                        // snapping forward once .active lands. `currentTime` is intentionally frozen
                        // while backgrounded (perf: no visible scrubber there), so without this
                        // early re-projection the first foreground frame would be stale.
                        if oldPhase == .background { container.enterForeground() }
                    @unknown default:
                        break
                    }
                }
                .modifier(ReviewPromptPresenter(review: container.review))
                #if os(iOS) || os(visionOS)
                // An audio file opened in / shared to Luma from another app is imported like one
                // picked in the import sheet. Several files arrive as several calls in quick
                // succession — ImportManager queues them instead of dropping all but the first.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await container.importManager.importFiles([url]) }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        // Min = the content's min frame above; window can still grow to any size / full-screen.
        .windowResizability(.contentMinSize)
        .commands { LumaCommands(app: container, nav: macNav) }
        #endif

        #if os(macOS)
        // Menu-bar mini-player: control playback while the main window is closed/backgrounded.
        MenuBarExtra {
            MacMenuBarPlayer()
                .environment(container)
                .modelContainer(modelContainer)
                .tint(Color.lumaAccent)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

// Presents the App Store rating prompt at the moment the review manager deems it earned. The
// manager only decides *when* (after enough qualified, music-playing sessions); the actual ask
// goes through SwiftUI's official `requestReview` action, which Apple throttles to ≤3/year and
// may silently suppress — so we always record the attempt via `markReviewRequested()`.
private struct ReviewPromptPresenter: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    let review: ReviewPromptManager

    func body(content: Content) -> some View {
        content.onChange(of: review.shouldRequestReview) { _, pending in
            guard pending else { return }
            requestReview()
            review.markReviewRequested()
        }
    }
}

// Thin bootstrap view: picks the platform-appropriate shell. AppContainer is created and
// owned by the App and injected via the environment.
struct RootView: View {
    var body: some View {
        #if os(macOS)
        MacRootView()
        #else
        MainTabView()
        #endif
    }
}
