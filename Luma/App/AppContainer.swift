import Foundation
import SwiftData
import Observation

@Observable
final class AppContainer {
    let player: AudioPlayer
    let equalizer: EQManager
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
        let eq = EQManager()
        eq.attach(to: p.graph)
        self.equalizer = eq
        self.queue = q
        self.modelContext = modelContext
        // Disable autosave on the UI-observed main context: otherwise every playback-stat
        // mutation (playCount/listenSeconds) autosaves at the next runloop turn and republishes
        // EVERY live @Query — the storm that made scrolling mushy and kept the phone busy during
        // background playback. Stats are now coalesced and saved at lifecycle boundaries
        // (saveStats); all OTHER mutations already save explicitly via LibraryRepository.
        modelContext.autosaveEnabled = false
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
        // Backfill denormalized playlist-entry metadata (one-time) so backups/placeholders work.
        lib.backfillEntryMetadataIfNeeded()

        // After a music import, re-link any playlist placeholders to the new tracks.
        importManager.onImportFinished = { [weak self] in self?.library.relinkPlaylistPlaceholders() }

        // When a track is deleted: if it was playing, tear down playback so the mini-player
        // closes; otherwise just drop it from the queue. Keeps a deleted (dangling) Track
        // from lingering in the queue.
        lib.onTrackDeleted = { [weak self] id in
            guard let self else { return }
            if self.player.currentTrackID == id {
                self.queue.clear()
                self.player.stop()          // clears currentTrack → mini-player closes; persists empty queue
            } else {
                self.queue.removeTrack(id: id)
                self.savePlaybackState()    // persist the trimmed queue
            }
        }

        p.onTrackPlayed = { track in
            try? lib.recordPlay(track: track)
        }

        p.onListened = { track, seconds in
            lib.addListenTime(to: track, seconds: seconds)
        }

        // The player coalesces stat writes (recordPlay/addListenTime mutate without saving);
        // it asks us to persist them at safe boundaries (pause/stop), not on every tick.
        p.onStatsShouldPersist = { lib.saveStats() }

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

    /// Flushes any in-memory listened-seconds delta into the current track, then persists all
    /// pending playback stats. Called when leaving the foreground (LumaApp scenePhase) so a
    /// background or kill keeps the stats without saving on every playback tick.
    func saveStats() {
        player.flushPendingListen()
        library.saveStats()
    }

    /// App left the foreground — let the player release the audio session if it's paused, so
    /// the lock screen reports the correct paused state.
    func enterBackground() { player.enterBackground() }

    /// App returned to the foreground — refresh the now-playing info.
    func enterForeground() { player.enterForeground() }

    /// Restores the last session's queue and parks the player paused at the saved position.
    /// No-op when nothing is saved or the referenced tracks are gone.
    func restoreLastSession() {
        guard let saved = PlaybackStateStore.load() else { return }
        // Fetch ONLY the saved-queue tracks (predicate), not the whole Track table — the old
        // full-table fetch + dictionary ran on the main thread on every launch.
        let neededIDs = Set(saved.queue.itemIDs + saved.queue.originalIDs)
        guard !neededIDs.isEmpty else { return }
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { neededIDs.contains($0.id) })
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        guard !fetched.isEmpty else { return }
        let map = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard queue.restore(from: saved.queue, resolve: { map[$0] }),
              let track = queue.currentTrack else { return }
        Task { await player.prepare(track: track, at: saved.position) }
    }
}
