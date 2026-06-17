import SwiftUI
import SwiftData

@main
struct LumaApp: App {
    let modelContainer: ModelContainer

    /// Set when the store had to be reset on launch, so the UI can inform the user once.
    static let storeWasResetKey = "lumaStoreWasReset"

    init() {
        let schema = Schema([Track.self, Album.self, Artist.self, Playlist.self, PlaylistEntry.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // An incompatible/corrupt store (failed migration, corrupt WAL after an OS kill)
            // would otherwise crash on every launch. Move the existing store ASIDE — never
            // delete it, the library is the user's only copy — so it stays recoverable, flag
            // it so the UI can tell the user, then rebuild.
            LumaApp.moveStoreAside(at: config.url)
            UserDefaults.standard.set(true, forKey: LumaApp.storeWasResetKey)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("SwiftData failed after store reset: \(error)")
            }
        }
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
                .modelContainer(modelContainer)
                .tint(Color.lumaAccent)
        }
    }
}

// Thin bootstrap view that owns AppContainer as @State so SwiftUI manages its lifetime.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var container: AppContainer?

    var body: some View {
        if let container {
            MainTabView()
                .environment(container)
        } else {
            Color.clear
                .onAppear {
                    container = AppContainer(modelContext: modelContext)
                }
        }
    }
}
