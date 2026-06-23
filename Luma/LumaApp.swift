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

    /// Where the uncaught-exception handler records the last crash, so RootView can show it on the
    /// next launch. TEMPORARY diagnostic for the audio route-change crashes: those raise Obj-C
    /// NSExceptions that Swift try?/catch can't catch and that leave NO .ips log when "Share iPhone
    /// Analytics" is off, so we capture the exact reason in-app instead of guessing.
    static var crashLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumaLastCrash.txt")
    }

    /// Records uncaught Obj-C NSExceptions (e.g. AVFoundation "required condition is false"
    /// assertions raised while an audio route is settling). The app still aborts, but the name +
    /// reason + top stack frames are written synchronously so they survive to the next launch.
    private static func installCrashCapture() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            \(exception.name.rawValue)

            \(exception.reason ?? "(no reason)")

            \(exception.callStackSymbols.prefix(24).joined(separator: "\n"))
            """
            try? text.data(using: .utf8)?.write(to: LumaApp.crashLogURL, options: .atomic)
        }
    }

    init() {
        LumaApp.installCrashCapture()
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
    /// TEMPORARY: the last captured crash (NSException name + reason + stack), shown once so it can
    /// be reported. Cleared on dismiss. Remove together with LumaApp.installCrashCapture once the
    /// route-change crash is fixed.
    @State private var lastCrash: String?

    var body: some View {
        Group {
            #if os(macOS)
            MacRootView()
            #else
            MainTabView()
            #endif
        }
        .onAppear {
            if let data = try? Data(contentsOf: LumaApp.crashLogURL),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                lastCrash = text
            }
        }
        .alert("Letzter Absturz (bitte als Screenshot melden)", isPresented: Binding(
            get: { lastCrash != nil },
            set: { if !$0 { lastCrash = nil } }
        )) {
            Button("Verwerfen", role: .cancel) {
                try? FileManager.default.removeItem(at: LumaApp.crashLogURL)
                lastCrash = nil
            }
        } message: {
            Text(lastCrash ?? "")
        }
    }
}
