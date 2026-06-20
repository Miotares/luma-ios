import SwiftUI
import SwiftData

@main
struct LumaApp: App {
    let modelContainer: ModelContainer
    /// Owned by the App (not RootView) so menu-bar commands can reach the same instance.
    @State private var container: AppContainer
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
                .modelContainer(modelContainer)
                .tint(Color.lumaAccent)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    // Persist the play head whenever we leave the foreground, so a
                    // background-kill still resumes where the user left off.
                    if phase != .active { container.savePlaybackState() }
                    // On iOS, release the audio session when backgrounding-while-paused so the
                    // lock screen reflects "paused" (iOS reads the session, not playbackState).
                    switch phase {
                    case .background: container.enterBackground()
                    case .active:     container.enterForeground()
                    default:          break
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .commands { LumaCommands(app: container) }
        #endif
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
