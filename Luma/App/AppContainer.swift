import Foundation
import SwiftData
import Observation

@Observable
final class AppContainer {
    let player: AudioPlayer
    let queue: PlaybackQueue
    let importManager: ImportManager
    let library: LibraryRepository
    let libraryFolders: LibraryFolders
    let folderScanner: FolderLibraryScanner
    private(set) var currentPalette: ColorPalette?

    private let remoteCommands: RemoteCommandHandler
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        let p = AudioPlayer()
        let q = PlaybackQueue()

        p.queue = q
        q.player = p

        self.player = p
        self.queue = q
        self.modelContext = modelContext
        self.importManager = ImportManager(modelContext: modelContext)
        let lib = LibraryRepository(context: modelContext)
        self.library = lib
        let folders = LibraryFolders()
        self.libraryFolders = folders
        self.folderScanner = FolderLibraryScanner(modelContainer: modelContext.container, folders: folders)
        self.remoteCommands = RemoteCommandHandler(player: p, queue: q)

        // Seed listening time from existing completed plays (one-time) so the new
        // stats reflect history instead of starting from zero.
        lib.seedListenSecondsIfNeeded()
        // Backfill playlist order (one-time) so existing playlists keep their order when
        // the Playlists tab switches to manual sorting.
        lib.seedPlaylistOrderIfNeeded()

        p.onTrackComplete = { track in
            try? lib.recordPlay(track: track)
        }

        p.onListened = { track, seconds in
            lib.addListenTime(to: track, seconds: seconds)
        }

        p.onTrackChanged = { [weak self] track in
            guard let self else { return }
            let artworkData = track.album?.artworkData
            let paletteId = track.album?.id ?? track.id
            Task {
                self.currentPalette = await PaletteExtractor.shared.palette(for: paletteId, imageData: artworkData)
            }
            self.savePlaybackState()
        }

        p.onPersist = { [weak self] in self?.savePlaybackState() }

        restoreLastSession()
    }

    /// Triggers a watched-folder rescan (macOS reference library). Never invoked on iOS.
    func rescan() {
        Task { await folderScanner.scan() }
    }

    // MARK: - Playback State Persistence

    /// Snapshots the current queue + play head so the next launch can resume here.
    func savePlaybackState() {
        PlaybackStateStore.save(queue: queue, position: player.currentTime)
    }

    /// Restores the last session's queue and parks the player paused at the saved position.
    /// No-op when nothing is saved or the referenced tracks are gone.
    func restoreLastSession() {
        guard let saved = PlaybackStateStore.load() else { return }
        let all = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        guard !all.isEmpty else { return }
        let map = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard queue.restore(from: saved.queue, resolve: { map[$0] }),
              let track = queue.currentTrack else { return }
        Task { await player.prepare(track: track, at: saved.position) }
    }
}
