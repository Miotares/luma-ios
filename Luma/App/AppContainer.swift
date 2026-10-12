import Foundation
import SwiftData
import Observation

@Observable
final class AppContainer {
    /// The single live container, so AppKit entry points without SwiftUI environment access
    /// (the Dock menu) can reach the shared player/queue. There is only ever one window.
    @MainActor static weak var shared: AppContainer?

    let player: AudioPlayer
    let equalizer: EQManager
    let queue: PlaybackQueue
    let importManager: ImportManager
    let library: LibraryRepository
    let loudness: LoudnessService
    let libraryFolders: LibraryFolders
    let folderScanner: FolderLibraryScanner
    let review = ReviewPromptManager()
    let toast = ToastCenter()
    /// Lyrics of the current track (see `LyricsStore`).
    let lyrics = LyricsStore()
    /// Last sorted order of the macOS Songs page, kept here because that page is destroyed on
    /// every sidebar section switch (see `MacLibrarySongsPage`).
    let songOrder = SongOrderCache()

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
        // Loudness normalization: the service measures tracks in the background and hands the
        // player each track's gain; a measurement arriving for the playing track glides in.
        let loud = LoudnessService(context: modelContext)
        self.loudness = loud
        p.loudness = loud
        p.normalizationSettingChanged()
        loud.onResult = { [weak p] id in p?.loudnessDidUpdate(for: id) }
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
        // Drop lyrics typed into the (removed) lyrics editor of the test builds (one-time).
        lib.clearTypedLyricsIfNeeded()
        // Recover real titles for songs that were imported under their container UUID (one-time,
        // re-reads the affected files in the background).
        Task { await lib.repairPlaceholderTitlesIfNeeded() }
        // Move the covers of an existing library out of the database into files (one-time; runs
        // once launch has settled — until then they are simply read from where they still are).
        Task {
            try? await Task.sleep(for: .seconds(2))
            await lib.moveArtworkToFilesIfNeeded()
        }
        // Reclaim disk from the abandoned full-resolution artwork cache (one-time, off-main).
        Task.detached { LegacyArtworkCleanup.purgeIfNeeded() }

        // After a music import, re-link any playlist placeholders to the new tracks.
        importManager.onImportFinished = { [weak self] in
            guard let self else { return }
            self.library.relinkPlaylistPlaceholders()
            self.loudness.enqueueMissing()   // measure the new tracks' loudness in the background
            self.announceImportResult()
        }

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

        p.onTrackPlayed = { [weak self] track in
            try? lib.recordPlay(track: track)
            // A genuinely-listened track is our "success moment": count it toward a qualified
            // session and let the review manager decide whether it's time to ask for a rating.
            self?.review.registerPlaybackActivity()
        }

        p.onListened = { track, seconds in
            lib.addListenTime(to: track, seconds: seconds)
        }

        // The repository only BUFFERS play counts / listen time while music plays (see
        // LibraryRepository.recordPlay); the player asks us to write them at a quiet boundary
        // (pause / stop). Loudness measurements collected meanwhile ride along in the same save.
        p.onStatsShouldPersist = { [weak self] in
            self?.loudness.flush(save: false)
            lib.saveStats()
        }

        // Persist the queue/playhead on every track change. (No palette extraction here — PlayerView
        // derives its own palette via PaletteExtractor; the old AppContainer.currentPalette was
        // written here but never read, duplicating that work.)
        p.onTrackChanged = { [weak self] _ in self?.savePlaybackState() }

        p.onPersist = { [weak self] in self?.savePlaybackState() }

        AppContainer.shared = self
        restoreLastSession()
        // Measure whatever has no loudness yet (the whole library on the first launch after the
        // update) — once launch has settled, at low priority.
        Task {
            try? await Task.sleep(for: .seconds(3))
            loud.enqueueMissing()
        }

        #if DEBUG
        // Dev/Simulator seeding: launch with LUMA_DEBUG_IMPORT=/host/folder to import that folder's
        // album subfolders — the Files picker can't be driven from a script.
        if let path = ProcessInfo.processInfo.environment["LUMA_DEBUG_IMPORT"] {
            Task { await importManager.debugImportFromPath(path, maxAlbums: .max) }
        }
        #endif
    }

    /// Triggers a watched-folder rescan (macOS reference library). Never invoked on iOS.
    func rescan() {
        Task {
            await folderScanner.scan()
            loudness.enqueueMissing()
        }
    }

    // MARK: - Playback State Persistence

    /// Snapshots the current queue + play head so the next launch can resume here. Uses
    /// `playheadSeconds` (the true head, live even while backgrounded) rather than the observable
    /// `currentTime`, which is frozen in the background — otherwise a background save / kill would
    /// persist a stale position and resume seconds behind where playback actually was.
    func savePlaybackState() {
        PlaybackStateStore.save(queue: queue, position: player.playheadSeconds)
    }

    /// Flushes any in-memory listened-seconds delta into the current track, then persists all
    /// pending playback stats. Called when leaving the foreground (LumaApp scenePhase) so a
    /// background or kill keeps the stats without saving on every playback tick.
    func saveStats() {
        player.flushPendingListen()
        // Loudness measurements collected in memory ride along with this save — the app is leaving
        // the foreground, so the query refresh a write causes isn't visible.
        loudness.flush(save: false)
        library.saveStats()
    }

    /// App left the foreground — let the player idle its engine when paused. It KEEPS the audio
    /// session active so it stays the Now-Playing app and resumable from the lock screen / AirPods.
    func enterBackground() { player.enterBackground() }

    /// App returned to the foreground — refresh the now-playing info and re-arm review-session
    /// counting so the next bout of playback counts as a fresh qualified session.
    func enterForeground() {
        player.enterForeground()
        review.startNewForegroundSession()
    }

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
