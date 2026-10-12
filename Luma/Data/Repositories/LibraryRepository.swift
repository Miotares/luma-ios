import Foundation
import SwiftData
import SwiftUI

// Encapsulates common library mutations that go beyond simple @Query usage.
// All methods run on MainActor (same as ModelContext).
final class LibraryRepository {
    private let context: ModelContext

    /// Fired with a track's id right after it is deleted from the store, so playback can be
    /// torn down if that track was playing (and the queue can drop it).
    var onTrackDeleted: ((UUID) -> Void)?

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Track Updates

    /// Play counts / listen time collected while music plays, keyed by track id, not yet on the
    /// models.
    ///
    /// WHY BUFFERED: changing a property of a main-context Track — even without saving — makes
    /// every live `@Query` re-fetch. With a ~2000-track library that froze the UI for up to a second
    /// (measured: 600 ms for the track list, 180 ms albums, 220 ms artists) at EVERY track change
    /// and every counted play, because the player reports listen time and plays exactly then. So
    /// the numbers wait here and reach the models in one step at a quiet boundary — pause, stop,
    /// leaving the foreground (`saveStats`). The price: "recently / most played" lists catch up at
    /// that boundary instead of mid-song. Durability is unchanged — these writes were never saved
    /// before that boundary either.
    private struct PendingStats {
        var plays = 0
        var listenSeconds: TimeInterval = 0
        var lastPlayed: Date?
    }
    private var pendingStats: [UUID: PendingStats] = [:]

    func recordPlay(track: Track) throws {
        pendingStats[track.id, default: PendingStats()].plays += 1
        pendingStats[track.id]?.lastPlayed = Date()
    }

    /// Adds actually-listened seconds to a track (the player accumulates in memory and flushes
    /// at track boundaries / pause / background, so partial/skipped plays still count).
    func addListenTime(to track: Track, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        pendingStats[track.id, default: PendingStats()].listenSeconds += seconds
    }

    /// Moves the buffered stats onto their tracks (no save). A track deleted meanwhile is skipped.
    private func applyPendingStats() {
        guard !pendingStats.isEmpty else { return }
        let pending = pendingStats
        let ids = Array(pending.keys)
        guard let tracks = try? context.fetch(
            FetchDescriptor<Track>(predicate: #Predicate { ids.contains($0.id) })
        ) else { return }   // keep the buffer for the next attempt
        pendingStats.removeAll()
        for track in tracks {
            guard let stats = pending[track.id] else { continue }
            track.playCount += stats.plays
            track.listenSeconds += stats.listenSeconds
            if let played = stats.lastPlayed { track.lastPlayedDate = played }
        }
    }

    /// Persists any pending in-memory mutations (playback stats accumulated during playback).
    /// Called when leaving the foreground / on pause / stop so a background or kill keeps the
    /// stats, WITHOUT saving on every play/listen tick (which republishes every live @Query).
    func saveStats() {
        applyPendingStats()
        guard context.hasChanges else { return }
        try? context.save()
    }

    private static let didSeedListenKey = "didSeedListenSeconds_v1"

    /// One-time backfill so listening-time stats aren't empty for libraries that predate
    /// per-second tracking: estimate past listening from completed plays. Runs once.
    func seedListenSecondsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didSeedListenKey) else { return }
        // Mark done only AFTER a successful fetch — a transient fetch failure must retry next launch,
        // not permanently skip the backfill (which a `defer` before this guard would have done).
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        var changed = false
        for track in tracks where track.listenSeconds == 0 && track.playCount > 0 {
            track.listenSeconds = Double(track.playCount) * track.duration
            changed = true
        }
        if changed { try? context.save() }
        UserDefaults.standard.set(true, forKey: Self.didSeedListenKey)
    }

    private static let didSeedPlaylistOrderKey = "didSeedPlaylistOrder_v1"

    /// One-time backfill of `Playlist.sortIndex` for libraries created before manual
    /// ordering existed: assigns indices by `createdDate` (newest first) so the previous
    /// visual order is preserved when the Playlists tab starts sorting by `sortIndex`.
    func seedPlaylistOrderIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didSeedPlaylistOrderKey) else { return }
        // Fetch failure → return WITHOUT marking done, so it retries next launch. An empty result is
        // a valid "nothing to seed" state and DOES mark done (new playlists get their sortIndex from
        // createPlaylist). Previously a `defer` marked it done even on a transient fetch failure.
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()) else { return }
        let ordered = playlists.sorted { $0.createdDate > $1.createdDate }
        for (index, playlist) in ordered.enumerated() { playlist.sortIndex = index }
        if !playlists.isEmpty { try? context.save() }
        UserDefaults.standard.set(true, forKey: Self.didSeedPlaylistOrderKey)
    }

    private static let didRepairUUIDTitlesKey = "didRepairUUIDTitles_v1"

    /// One-time repair for libraries imported before the title fallback was fixed: a file whose
    /// tags weren't read (every FLAC, and any untagged file) got the UUID of its container copy as
    /// its title ("4D96906E-…"). Each such track is re-read from its local copy with the fixed
    /// parser, falling back to the ORIGINAL filename still kept in `filePath` — so the real names
    /// come back without a re-import. Touches ONLY tracks whose title is literally their own
    /// container filename; if nothing better can be found the track is left exactly as it is.
    /// Safe to interrupt: an unfinished pass simply resumes on the next launch.
    func repairPlaceholderTitlesIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.didRepairUUIDTitlesKey) else { return }
        // Bail WITHOUT marking done so a transient fetch/save failure retries next launch.
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        let affected = tracks.filter { track in
            guard let local = track.localFileName else { return false }
            let containerStem = (local as NSString).deletingPathExtension
            return FilenameMetadata.isPlaceholderName(containerStem)
                && track.title.caseInsensitiveCompare(containerStem) == .orderedSame
        }

        var unsaved = 0
        for track in affected {
            guard track.modelContext != nil, let local = track.localFileName else { continue }
            let originalStem = URL(fileURLWithPath: track.filePath).deletingPathExtension().lastPathComponent
            let fallback = originalStem.isEmpty || FilenameMetadata.isPlaceholderName(originalStem)
                ? nil : originalStem
            let metadata = try? await MetadataParser().parse(url: MediaStorage.url(for: local),
                                                             fallbackName: fallback)
            // The track may have been deleted while its file was being read.
            guard track.modelContext != nil, let metadata,
                  !metadata.title.isEmpty, !FilenameMetadata.isPlaceholderName(metadata.title) else { continue }

            track.title = metadata.title
            track.artistName = metadata.artistName
            if metadata.hasAlbumTag { track.albumTitle = metadata.albumTitle }
            if metadata.trackNumber > 0 { track.trackNumber = metadata.trackNumber }
            if metadata.discNumber > 0 { track.discNumber = metadata.discNumber }
            if let year = metadata.year { track.year = year }
            if let genre = metadata.genre { track.genre = genre }
            // Don't inherit the catch-all "Unknown Album" cover — it belongs to whichever file
            // happened to be imported first, not to this track's real album.
            relinkTrackAlbumAndArtist(track, groupingArtist: metadata.albumArtistName, inheritArtwork: false)
            if let cover = metadata.artworkThumbnail ?? metadata.artworkData {
                if metadata.hasAlbumTag {
                    if let album = track.album, album.artworkData == nil { album.artworkData = cover }
                } else if !track.hasCustomArtwork {
                    // Untagged: the embedded cover is this track's own, not the catch-all album's.
                    track.setCustomArtwork(cover)
                }
            }
            // Keep the denormalized playlist metadata in step (via the track's own entries — safe).
            for entry in track.playlistEntries {
                entry.trackTitle = track.title
                entry.trackArtist = track.artistName
                entry.trackAlbum = track.albumTitle
            }
            unsaved += 1
            // Batched so a large library fills in progressively without a save per track.
            if unsaved >= 50 {
                do { try context.save() } catch { return }
                unsaved = 0
            }
        }
        if unsaved > 0 {
            do { try context.save() } catch { return }
        }
        UserDefaults.standard.set(true, forKey: Self.didRepairUUIDTitlesKey)
    }

    func toggleLike(track: Track) throws {
        track.isLiked.toggle()
        // Unlike play/listen stats, a like MUST save explicitly: autosave is off, and the
        // Liked tab (`LikedSongsView`'s isLiked @Query) has to update + persist immediately.
        // Deferred to the next main-actor turn so the heart flips instantly without the save
        // (and its @Query refresh) stalling the tap frame. recordPlay/addListenTime instead
        // coalesce into saveStats() — a like is a deliberate, infrequent action.
        Task { @MainActor in try? self.context.save() }
    }

    /// Sets the like state on many tracks at once (bulk selection). Only tracks whose
    /// state actually changes are touched, and the whole batch is persisted in a single
    /// save — this is an explicit user action, not a per-frame tap, so saving inline is fine.
    @discardableResult
    func setLiked(_ tracks: [Track], liked: Bool) throws -> Int {
        var changed = 0
        for track in tracks where track.isLiked != liked {
            track.isLiked = liked
            changed += 1
        }
        if changed > 0 { try context.save() }
        return changed
    }

    func updateTrack(
        _ track: Track,
        title: String,
        artistName: String,
        albumTitle: String,
        trackNumber: Int,
        year: Int?,
        genre: String?
    ) throws {
        track.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        track.artistName = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        track.albumTitle = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        track.trackNumber = trackNumber
        track.year = year
        let trimmedGenre = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        track.genre = (trimmedGenre?.isEmpty ?? true) ? nil : trimmedGenre
        // Move the track to the album/artist matching its edited strings — see relink helper.
        relinkTrackAlbumAndArtist(track)
        try context.save()
    }

    /// Stores lyrics for a track; empty or nil removes them (the file's embedded lyrics, if any,
    /// show again).
    func updateLyrics(_ track: Track, text: String?) throws {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        track.customLyrics = trimmed.isEmpty ? nil : trimmed
        try context.save()
    }

    /// Sets (or, with nil, removes) a track's own cover. `data` is already downscaled by the caller.
    func updateTrackArtwork(_ track: Track, data: Data?) throws {
        track.setCustomArtwork(data)
        try context.save()
    }

    /// Replaces (or, with nil, removes) an album's cover. `data` is already downscaled by the caller.
    func updateAlbumArtwork(_ album: Album, data: Data?) throws {
        album.artworkData = data
        album.artworkVersion &+= 1
        try context.save()
    }

    func delete(track: Track, save: Bool = true) throws {
        let deletedID = track.id
        // Tear down playback / drop this track from the queue FIRST, while it is still a live
        // @Model. PlaybackQueue holds STRONG references to Track and its removeTrack()/snapshot()
        // read `.id` off every queued element — doing this after context.delete(track) would
        // dereference the just-invalidated instance and crash ("backing data could no longer be
        // found"). This is what made deleting an album (or any queued track) crash.
        onTrackDeleted?(deletedID)
        // Remove the imported on-disk copy so it doesn't orphan storage.
        if let fileName = track.localFileName {
            MediaStorage.delete(filename: fileName)
        }
        if let album = track.album {
            album.tracks.removeAll { $0.id == track.id }
            if album.tracks.isEmpty {
                deleteAlbum(album)
            }
        }
        if let artist = track.artist {
            artist.tracks.removeAll { $0.id == track.id }
            if artist.tracks.isEmpty {
                context.delete(artist)
            }
        }
        context.delete(track)
        if save { try context.save() }
    }

    // MARK: - Stats

    /// Library totals for the Settings screen. Counts are SQL `COUNT`s and the duration reads one
    /// column — never whole rows: an Album row carries its cover inline (≈200 KB each), so fetching
    /// the album table just to count it read ~20 MB.
    func libraryStats() -> LibraryStats {
        var durations = FetchDescriptor<Track>()
        durations.propertiesToFetch = [\.duration]
        let totalDuration = ((try? context.fetch(durations)) ?? []).reduce(0.0) { $0 + $1.duration }
        return LibraryStats(
            trackCount: (try? context.fetchCount(FetchDescriptor<Track>())) ?? 0,
            albumCount: (try? context.fetchCount(FetchDescriptor<Album>())) ?? 0,
            artistCount: (try? context.fetchCount(FetchDescriptor<Artist>())) ?? 0,
            playlistCount: (try? context.fetchCount(FetchDescriptor<Playlist>())) ?? 0,
            totalDuration: totalDuration
        )
    }

    // MARK: - Playlist CRUD

    @discardableResult
    func createPlaylist(name: String) throws -> Playlist {
        let playlist = Playlist(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        // New playlists go to the top (smallest sortIndex) — preserves the previous
        // "newest first" feel without reindexing the existing ones.
        let minIndex = (try? context.fetch(FetchDescriptor<Playlist>()))?.map(\.sortIndex).min() ?? 0
        playlist.sortIndex = minIndex - 1
        context.insert(playlist)
        try context.save()
        return playlist
    }

    /// Persists a user-defined playlist order (Playlists-tab drag-to-reorder): reassigns a
    /// contiguous 0..n `sortIndex` to the already-reordered array.
    func reorderPlaylists(_ ordered: [Playlist]) throws {
        for (index, playlist) in ordered.enumerated() { playlist.sortIndex = index }
        try context.save()
    }

    /// Returns how many of `tracks` were actually added (tracks already in the playlist are skipped).
    @discardableResult
    func addTracks(_ tracks: [Track], to playlist: Playlist) throws -> Int {
        // Index this playlist's unresolved placeholder entries by their match key (via the SAFE
        // inverse — never reading entry.track, which can fault on a dangling entry). Manually adding
        // a song that already exists as a placeholder LINKS the placeholder instead of inserting a
        // 2nd entry; otherwise relinkPlaylistPlaceholders later links the placeholder too → two
        // entries for one song.
        let validIDs = try validPlaylistEntryIDs()
        var placeholderByKey: [String: PlaylistEntry] = [:]
        for e in playlist.entries where !validIDs.contains(e.persistentModelID) && !e.trackTitle.isEmpty {
            placeholderByKey[matchKey(e.trackTitle, e.trackArtist, e.trackAlbum)] = e
        }
        var added = 0
        for track in tracks {
            guard !playlist.containsTrack(track) else { continue }
            added += 1
            let key = matchKey(track.title, track.artistName, track.albumTitle)
            if let placeholder = placeholderByKey.removeValue(forKey: key) {
                placeholder.track = track
                continue
            }
            let entry = PlaylistEntry(track: track, order: playlist.nextOrder())
            entry.playlist = playlist
            playlist.entries.append(entry)
            context.insert(entry)
        }
        try context.save()
        return added
    }

    func removeEntry(_ entry: PlaylistEntry, from playlist: Playlist) throws {
        playlist.entries.removeAll { $0.id == entry.id }
        context.delete(entry)
        // Re-index remaining entries
        for (i, e) in playlist.entries.sorted(by: { $0.order < $1.order }).enumerated() {
            e.order = i
        }
        try context.save()
    }

    /// Reassigns a contiguous order to the given (already-reordered) entries.
    func reorderEntries(_ entries: [PlaylistEntry]) throws {
        for (index, entry) in entries.enumerated() { entry.order = index }
        try context.save()
    }

    func reorderPlaylist(_ playlist: Playlist, from source: IndexSet, to destination: Int) throws {
        var sorted = playlist.entries.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: source, toOffset: destination)
        for (i, entry) in sorted.enumerated() { entry.order = i }
        try context.save()
    }

    func deletePlaylist(_ playlist: Playlist) throws {
        // Explicitly DELETE entries whose track is gone / never resolved (placeholders, danglers)
        // instead of detaching them (entry.playlist = nil). Detaching left them orphaned in the
        // store forever — relinkPlaylistPlaceholders then kept re-processing them. Deleting an entry
        // whose `track` is already nil faults nothing; the remaining VALID entries cascade with the
        // playlist. Snapshot first — never remove from playlist.entries while iterating. (Mirrors
        // removePlaceholders.)
        let validIDs = try validPlaylistEntryIDs()
        let dead = playlist.entries.filter { !validIDs.contains($0.persistentModelID) }
        for entry in dead {
            playlist.entries.removeAll { $0.id == entry.id }
            context.delete(entry)
        }
        context.delete(playlist)
        try context.save()
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) throws {
        playlist.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try context.save()
    }

    /// Persists a playlist's cover choice in one save. `photoData` is the full desired image
    /// (already downscaled by the caller) or nil to clear it; the generated config is always
    /// stored so the look is remembered even when another style is active. Bumps `coverVersion`
    /// so ArtworkView's decoded-image cache drops any stale photo for this playlist.
    func updatePlaylistCover(_ playlist: Playlist,
                             style: PlaylistCoverStyle,
                             photoData: Data?,
                             generatedConfig: GeneratedCoverConfig) throws {
        playlist.coverStyle = style
        playlist.customArtworkData = photoData
        playlist.generatedCoverConfig = try? JSONEncoder().encode(generatedConfig)
        playlist.coverVersion &+= 1
        try context.save()
    }

    /// Ids of every playlist entry that still resolves to a live track, via the SAFE track→entry
    /// inverse. Fetches only the tracks that are in a playlist (a track without entries contributes
    /// nothing) instead of the whole table, which made every "add to playlist" a ~26 ms main-thread
    /// scan. THROWS on a fetch failure rather than returning an empty set: the callers treat
    /// "not in this set" as dead/placeholder, so a silently-empty set would misclassify — and, in
    /// `removePlaceholders`, delete — every valid entry.
    private func validPlaylistEntryIDs() throws -> Set<PersistentIdentifier> {
        let inPlaylists = try context.fetch(playlistTracksDescriptor())
        return Set(inPlaylists.flatMap { $0.playlistEntries.map(\.persistentModelID) })
    }

    // MARK: - Playlist Backup (export / import)

    /// Match key for re-linking a backup entry to a library track: title+artist+album,
    /// lowercased + trimmed.
    private func matchKey(_ title: String, _ artist: String, _ album: String) -> String {
        func n(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return n(title) + "\u{1}" + n(artist) + "\u{1}" + n(album)
    }

    /// Encodes playlists (all, or a given subset) to a backup JSON blob.
    func makeBackupData(playlists: [Playlist]? = nil) -> Data? {
        let lists = playlists ?? ((try? context.fetch(
            FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? [])
        // Resolve duration/trackNumber through the track->entry inverse — never read e.track,
        // which can fault on a legacy dangling entry (the no-entry.track invariant).
        let map = validEntryTrackMap((try? context.fetch(playlistTracksDescriptor())) ?? [])
        let backup = PlaylistBackup(version: 1, playlists: lists.map { pl in
            // A `.photo` cover isn't carried (the image is on-device only), so back it up as
            // `.mosaic`; `.generated`/`.mosaic` are preserved. The generated recipe is tiny.
            let exportedStyle: PlaylistCoverStyle = pl.coverStyle == .photo ? .mosaic : pl.coverStyle
            let generated = pl.generatedCoverConfig
                .flatMap { try? JSONDecoder().decode(GeneratedCoverConfig.self, from: $0) }
            return BackupPlaylist(
                name: pl.name,
                tracks: pl.entries.sorted { $0.order < $1.order }.map { e in
                    let track = map[e.persistentModelID]
                    return BackupTrack(
                        title: e.trackTitle,
                        artist: e.trackArtist,
                        album: e.trackAlbum,
                        duration: track?.duration,
                        trackNumber: track?.trackNumber
                    )
                },
                coverStyle: exportedStyle.rawValue,
                generatedCover: generated
            )
        })
        return try? JSONEncoder().encode(backup)
    }

    /// Recreates playlists from a backup. Tracks already in the library are linked; the rest
    /// become placeholders (re-linked later via relinkPlaylistPlaceholders).
    @discardableResult
    func importBackup(_ data: Data) throws -> (created: Int, matched: Int, placeholders: Int) {
        let backup = try JSONDecoder().decode(PlaylistBackup.self, from: data)
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var index: [String: Track] = [:]
        for t in allTracks { index[matchKey(t.title, t.artistName, t.albumTitle)] = t }

        let existing = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        var existingNames = Set(existing.map { $0.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let minSort = existing.map(\.sortIndex).min() ?? 0
        var created = 0, matched = 0, placeholders = 0

        for bp in backup.playlists {
            let trimmed = bp.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? String(localized: "Playlist") : trimmed
            // Skip playlists that already exist (re-import / populated library) — no duplicates.
            guard existingNames.insert(name.lowercased()).inserted else { continue }
            let playlist = Playlist(name: name)
            playlist.sortIndex = minSort - 1 - created
            // Restore the cover choice. A backed-up `.photo` was already downgraded to `.mosaic`
            // on export (the image isn't carried), so this never leaves a photo cover without
            // its blob. The generated recipe is re-encoded as the playlist's stored config.
            if let raw = bp.coverStyle, let style = PlaylistCoverStyle(rawValue: raw) {
                playlist.coverStyle = style
            }
            if let generated = bp.generatedCover {
                playlist.generatedCoverConfig = try? JSONEncoder().encode(generated)
            }
            created += 1
            context.insert(playlist)
            for (order, bt) in bp.tracks.enumerated() {
                let entry: PlaylistEntry
                if let match = index[matchKey(bt.title, bt.artist, bt.album)] {
                    entry = PlaylistEntry(track: match, order: order)
                    matched += 1
                } else {
                    entry = PlaylistEntry(placeholderTitle: bt.title, artist: bt.artist, album: bt.album, order: order)
                    placeholders += 1
                }
                entry.playlist = playlist
                playlist.entries.append(entry)
                context.insert(entry)
            }
        }
        try context.save()
        // Return the number of playlists actually CREATED (not the file's total) — the caller shows
        // "already present" when created == 0, which was unreachable while this returned the total,
        // and an all-duplicate re-import falsely reported "N playlists imported".
        return (created, matched, placeholders)
    }

    /// Links placeholder entries to newly-available tracks. Called after a music import.
    func relinkPlaylistPlaceholders() {
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        guard !allTracks.isEmpty else { return }
        let validIDs = Set(allTracks.flatMap { $0.playlistEntries.map(\.persistentModelID) })
        let entries = (try? context.fetch(FetchDescriptor<PlaylistEntry>())) ?? []
        let placeholders = entries.filter { !validIDs.contains($0.persistentModelID) && !$0.trackTitle.isEmpty }
        guard !placeholders.isEmpty else { return }

        var index: [String: Track] = [:]
        for t in allTracks { index[matchKey(t.title, t.artistName, t.albumTitle)] = t }
        var changed = false
        for entry in placeholders {
            if let match = index[matchKey(entry.trackTitle, entry.trackArtist, entry.trackAlbum)] {
                entry.track = match
                // Refresh the denormalized metadata to the matched track's canonical, current values
                // (casing/spacing may differ from the backup) so a later re-export is clean.
                entry.trackTitle = match.title
                entry.trackArtist = match.artistName
                entry.trackAlbum = match.albumTitle
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Removes unresolved (placeholder / dangling) entries from a playlist and re-indexes.
    func removePlaceholders(from playlist: Playlist) throws {
        let validIDs = try validPlaylistEntryIDs()
        // Snapshot before mutating — never remove from playlist.entries while iterating it.
        let dead = playlist.entries.filter { !validIDs.contains($0.persistentModelID) }
        for entry in dead {
            playlist.entries.removeAll { $0.id == entry.id }
            context.delete(entry)
        }
        for (i, e) in playlist.entries.sorted(by: { $0.order < $1.order }).enumerated() { e.order = i }
        try context.save()
    }

    private static let didBackfillEntryMetaKey = "didBackfillEntryMeta_v1"

    /// One-time backfill of denormalized entry metadata for playlists created before backups
    /// existed, so a track later deleted becomes a proper placeholder instead of vanishing.
    func backfillEntryMetadataIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didBackfillEntryMetaKey) else { return }
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        var trackByEntry: [PersistentIdentifier: Track] = [:]
        for t in allTracks { for e in t.playlistEntries { trackByEntry[e.persistentModelID] = t } }
        // Bail WITHOUT marking done so a transient fetch failure retries next launch.
        guard let entries = try? context.fetch(FetchDescriptor<PlaylistEntry>()) else { return }
        var changed = false
        for e in entries where e.trackTitle.isEmpty {
            if let t = trackByEntry[e.persistentModelID] {
                e.trackTitle = t.title
                e.trackArtist = t.artistName
                e.trackAlbum = t.albumTitle
                changed = true
            }
        }
        if changed { try? context.save() }
        UserDefaults.standard.set(true, forKey: Self.didBackfillEntryMetaKey)
    }

    // MARK: - Album

    /// Edit album metadata. Reassigns the album (and its tracks) to a find-or-created
    /// Artist when the album artist changes, and propagates the title to every track.
    func updateAlbum(_ album: Album, title: String, artistName: String, year: Int?, genre: String?) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never store/propagate an empty album title — it would blank every member track's
        // albumTitle. (The editor also disables Save on an empty title; this guards other callers.)
        let newTitle = trimmedTitle.isEmpty ? album.title : trimmedTitle
        let newArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        album.title = newTitle
        album.year = year
        let g = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newGenre = (g?.isEmpty ?? true) ? nil : g
        album.genre = newGenre

        if !newArtist.isEmpty, album.artistName != newArtist {
            let oldArtist = album.artist
            album.artistName = newArtist
            let target = try context.fetch(
                FetchDescriptor<Artist>(predicate: #Predicate { $0.name == newArtist })
            ).first ?? {
                let a = Artist(name: newArtist)
                context.insert(a)
                return a
            }()
            album.artist = target
            let movedTracks = album.tracks
            // Propagate the new album artist to each track's denormalized `artistName` too — not just
            // the relationship. The UI reads `track.artistName` almost everywhere (rows, player,
            // queue, stats), so without this the album moved under the new artist while every track
            // still displayed the OLD name. Mirrors the title/genre/year propagation below.
            for track in movedTracks {
                track.artist = target
                track.artistName = newArtist
            }
            if let old = oldArtist, old.id != target.id {
                old.albums.removeAll { $0.id == album.id }
                old.tracks.removeAll { t in movedTracks.contains { $0.id == t.id } }
                if old.albums.isEmpty && old.tracks.isEmpty { context.delete(old) }
            }
        }

        // Propagate the album genre to every track too: Smart Playlists filter on Track.genre
        // (not Album.genre), so editing the album genre must retag its tracks or they stay in the
        // OLD genre's smart list. Mirrors how editing the album title propagates albumTitle below.
        for track in album.tracks {
            track.albumTitle = newTitle
            track.genre = newGenre
            // The Decade smart playlist filters/groups on Track.year (not Album.year), so editing
            // the album year must retag its tracks or they stay in the old decade bucket.
            track.year = year
        }
        try context.save()
    }

    /// Delete the ENTIRE library in one transaction. Reuses `delete(track:)` (which cascades the
    /// playback teardown + on-disk file + empty album/artist cleanup) but saves only ONCE at the
    /// end. The per-track variant saved — and republished every live @Query — once per track, an
    /// O(n²) main-thread storm that froze the UI for seconds on a large library.
    func deleteAllTracks() throws {
        let tracks = try context.fetch(FetchDescriptor<Track>())
        for track in tracks {
            try delete(track: track, save: false)
        }
        try context.save()
    }

    /// Delete an entire album: every track (and its on-disk file) plus the album and
    /// any now-empty artist. Reuses `delete(track:)` which cascades the teardown.
    func removeAlbum(_ album: Album) throws {
        // Delete every track WITHOUT saving per-track (that did N save+@Query-republish cycles —
        // the invalidation storm the codebase otherwise avoids), then persist once at the end.
        for track in Array(album.tracks) {
            try delete(track: track, save: false)
        }
        try context.save()
    }

    /// Outcome of a duplicate-removal pass (for surfacing a result message).
    struct DuplicateRemoval: Sendable { let removed: Int; let groups: Int }

    /// Removes content-duplicate tracks. Import de-dup is keyed by file PATH, so importing the SAME
    /// songs from two different folders (e.g. a loose copy AND the Apple Music library) creates two
    /// distinct rows per track — the "doubled album" symptom. Two tracks are duplicates when they
    /// share the same album + title + disc number + track number. For each duplicate group ONE keeper
    /// is retained (the copy carrying the most user state, tie-broken by earliest import) and the rest
    /// are MERGED into it — liked status, play count, listening seconds, last-played date and playlist
    /// memberships are preserved on the keeper — then the redundant copies (and their imported on-disk
    /// files) are deleted via `delete(track:)`. Saves once at the end.
    @discardableResult
    func removeDuplicateTracks() throws -> DuplicateRemoval {
        applyPendingStats()   // merge with the real counts, not the ones before this session
        let all = try context.fetch(FetchDescriptor<Track>())
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
             .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Key on album IDENTITY when present (both duplicate copies resolve to the same Album row,
        // since import find-or-creates albums by (title, artist)); fall back to the denormalized
        // album+artist strings for orphaned tracks.
        func key(_ t: Track) -> String {
            let albumKey = t.album.map { String($0.persistentModelID.hashValue) }
                ?? "\(norm(t.albumTitle))\u{1}\(norm(t.artistName))"
            return "\(albumKey)\u{1}\(norm(t.title))\u{1}\(t.discNumber)\u{1}\(t.trackNumber)"
        }
        // Higher score = better keeper: liked > more plays > more listening > in-playlist, and an
        // earlier import breaks ties (so the "original" copy survives).
        func keepScore(_ t: Track) -> (Int, Int, Double, Int, Double) {
            (t.isLiked ? 1 : 0, t.playCount, t.listenSeconds, t.playlistEntries.count,
             -t.addedDate.timeIntervalSinceReferenceDate)
        }

        var groups: [String: [Track]] = [:]
        for t in all { groups[key(t), default: []].append(t) }

        var removed = 0, dupGroups = 0
        for (_, dupes) in groups where dupes.count > 1 {
            dupGroups += 1
            let keeper = dupes.max { keepScore($0) < keepScore($1) }!
            for dup in dupes where dup !== keeper {
                keeper.isLiked = keeper.isLiked || dup.isLiked
                keeper.playCount += dup.playCount
                keeper.listenSeconds += dup.listenSeconds
                if let dl = dup.lastPlayedDate, dl > (keeper.lastPlayedDate ?? .distantPast) {
                    keeper.lastPlayedDate = dl
                }
                if keeper.customLyrics == nil { keeper.customLyrics = dup.customLyrics }
                if !keeper.hasCustomArtwork, dup.hasCustomArtwork {
                    keeper.setCustomArtwork(dup.artworkData)
                }
                if keeper.loudnessLUFS == nil {
                    keeper.loudnessLUFS = dup.loudnessLUFS
                    keeper.loudnessPeakDB = dup.loudnessPeakDB
                }
                // Move playlist memberships to the keeper BEFORE deleting — otherwise the track's
                // cascade-delete rule would drop it out of every playlist it was in.
                for entry in Array(dup.playlistEntries) { entry.track = keeper }
                try delete(track: dup, save: false)
                removed += 1
            }
        }
        if removed > 0 { try context.save() }
        return DuplicateRemoval(removed: removed, groups: dupGroups)
    }

    // MARK: - Private

    /// Re-links a track's `album`/`artist` RELATIONSHIPS to match its (just-edited) denormalized
    /// `albumTitle`/`artistName`. Without this, editing a single track's album or artist changed only
    /// the display strings while the track stayed grouped under — and showed the artwork of — its old
    /// album/artist. Find-or-creates the targets (same (title, artist) identity as import), moves the
    /// track, inherits artwork for a brand-new album, and deletes an old album/artist left empty.
    ///
    /// `groupingArtist` is the album artist when it differs from the track artist (import groups
    /// albums by album artist, so featured tracks stay in one album). `inheritArtwork` false keeps
    /// a new album from adopting the old album's cover.
    private func relinkTrackAlbumAndArtist(_ track: Track, groupingArtist: String? = nil,
                                           inheritArtwork: Bool = true) {
        let oldAlbum = track.album
        let oldArtist = track.artist
        let trimmedGrouping = groupingArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artistName = trimmedGrouping.isEmpty ? track.artistName : trimmedGrouping
        let targetArtist = findOrCreateArtist(named: artistName)
        let targetAlbum = findOrCreateAlbum(title: track.albumTitle, artistName: artistName,
                                            artist: targetArtist, year: track.year, genre: track.genre)

        // Album first: deleting an emptied old album also prunes it from the old artist's `albums`,
        // so the artist-emptiness check below sees the up-to-date state.
        if oldAlbum?.id != targetAlbum.id {
            oldAlbum?.tracks.removeAll { $0.id == track.id }
            if inheritArtwork, targetAlbum.artworkData == nil { targetAlbum.artworkData = oldAlbum?.artworkData }
            track.album = targetAlbum
            targetAlbum.tracks.append(track)
            if let old = oldAlbum, old.tracks.isEmpty { deleteAlbum(old) }
        }
        if oldArtist?.id != targetArtist.id {
            oldArtist?.tracks.removeAll { $0.id == track.id }
            track.artist = targetArtist
            targetArtist.tracks.append(track)
            if let old = oldArtist, old.tracks.isEmpty, old.albums.isEmpty { context.delete(old) }
        }
    }

    /// Find-or-create an Artist by name (mirrors ImportManager's matching).
    private func findOrCreateArtist(named name: String) -> Artist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = try? context.fetch(
            FetchDescriptor<Artist>(predicate: #Predicate { $0.name == trimmed })
        ).first { return found }
        let artist = Artist(name: trimmed)
        context.insert(artist)
        return artist
    }

    /// Find-or-create an Album by (title, album-artist) — the same identity ImportManager uses.
    private func findOrCreateAlbum(title: String, artistName: String, artist: Artist,
                                   year: Int?, genre: String?) -> Album {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = try? context.fetch(
            FetchDescriptor<Album>(predicate: #Predicate { $0.title == t && $0.artistName == a })
        ).first { return found }
        let album = Album(title: t, artistName: a, year: year, genre: genre)
        album.artist = artist
        context.insert(album)
        return album
    }

    private func deleteAlbum(_ album: Album) {
        if let artist = album.artist {
            artist.albums.removeAll { $0.id == album.id }
        }
        context.delete(album)
    }
}

struct LibraryStats {
    var trackCount = 0
    var albumCount = 0
    var artistCount = 0
    var playlistCount = 0
    var totalDuration: TimeInterval = 0

    var formattedDuration: String {
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
