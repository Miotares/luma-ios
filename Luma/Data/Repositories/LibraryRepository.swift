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

    func recordPlay(track: Track) throws {
        track.playCount += 1
        track.lastPlayedDate = Date()
        // NO save here. The main context has autosave DISABLED (see AppContainer), so these
        // high-frequency playback-stat writes stay pending in memory and are flushed together
        // by `saveStats()` at a lifecycle boundary (pause/stop/background). Saving per-play
        // republished every live @Query mid-playback — the invalidation storm that made the
        // library mushy while scrolling and kept the phone busy during background playback.
        // Pending changes are still visible to same-context fetches, so smart playlists update.
    }

    /// Adds actually-listened seconds to a track (the player accumulates in memory and flushes
    /// at track boundaries / pause / background, so partial/skipped plays still count).
    func addListenTime(to track: Track, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        track.listenSeconds += seconds
        // NO save here — coalesced into `saveStats()` at a lifecycle boundary. See recordPlay.
    }

    /// Persists any pending in-memory mutations (playback stats accumulated during playback).
    /// Called when leaving the foreground / on pause / stop so a background or kill keeps the
    /// stats, WITHOUT saving on every play/listen tick (which republishes every live @Query).
    func saveStats() {
        guard context.hasChanges else { return }
        try? context.save()
    }

    private static let didSeedListenKey = "didSeedListenSeconds_v1"

    /// One-time backfill so listening-time stats aren't empty for libraries that predate
    /// per-second tracking: estimate past listening from completed plays. Runs once.
    func seedListenSecondsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didSeedListenKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.didSeedListenKey) }
        guard let tracks = try? context.fetch(FetchDescriptor<Track>()) else { return }
        var changed = false
        for track in tracks where track.listenSeconds == 0 && track.playCount > 0 {
            track.listenSeconds = Double(track.playCount) * track.duration
            changed = true
        }
        if changed { try? context.save() }
    }

    private static let didSeedPlaylistOrderKey = "didSeedPlaylistOrder_v1"

    /// One-time backfill of `Playlist.sortIndex` for libraries created before manual
    /// ordering existed: assigns indices by `createdDate` (newest first) so the previous
    /// visual order is preserved when the Playlists tab starts sorting by `sortIndex`.
    func seedPlaylistOrderIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.didSeedPlaylistOrderKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.didSeedPlaylistOrderKey) }
        guard let playlists = try? context.fetch(FetchDescriptor<Playlist>()), !playlists.isEmpty else { return }
        let ordered = playlists.sorted { $0.createdDate > $1.createdDate }
        for (index, playlist) in ordered.enumerated() { playlist.sortIndex = index }
        try? context.save()
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
    func setLiked(_ tracks: [Track], liked: Bool) throws {
        var changed = false
        for track in tracks where track.isLiked != liked {
            track.isLiked = liked
            changed = true
        }
        if changed { try context.save() }
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
        try context.save()
    }

    func delete(track: Track) throws {
        let deletedID = track.id
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
        try context.save()
        onTrackDeleted?(deletedID)
    }

    // MARK: - Stats

    func libraryStats() throws -> LibraryStats {
        let tracks = try context.fetch(FetchDescriptor<Track>())
        let albums = try context.fetch(FetchDescriptor<Album>())
        let artists = try context.fetch(FetchDescriptor<Artist>())
        let totalDuration = tracks.reduce(0.0) { $0 + $1.duration }
        return LibraryStats(
            trackCount: tracks.count,
            albumCount: albums.count,
            artistCount: artists.count,
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

    func addTracks(_ tracks: [Track], to playlist: Playlist) throws {
        for track in tracks {
            guard !playlist.containsTrack(track) else { continue }
            let entry = PlaylistEntry(track: track, order: playlist.nextOrder())
            entry.playlist = playlist
            playlist.entries.append(entry)
            context.insert(entry)
        }
        try context.save()
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
        // Detach entries whose track was deleted (identified via the inverse, never
        // touching the dead track) so the cascade-delete doesn't fault them and crash.
        // Valid entries cascade fine — their track is still alive.
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let validIDs = Set(allTracks.flatMap { $0.playlistEntries.map(\.persistentModelID) })
        for entry in playlist.entries where !validIDs.contains(entry.persistentModelID) {
            entry.playlist = nil
        }
        context.delete(playlist)
        try context.save()
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) throws {
        playlist.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try context.save()
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
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let map = validEntryTrackMap(allTracks)
        let backup = PlaylistBackup(version: 1, playlists: lists.map { pl in
            BackupPlaylist(name: pl.name, tracks: pl.entries.sorted { $0.order < $1.order }.map { e in
                let track = map[e.persistentModelID]
                return BackupTrack(
                    title: e.trackTitle,
                    artist: e.trackArtist,
                    album: e.trackAlbum,
                    duration: track?.duration,
                    trackNumber: track?.trackNumber
                )
            })
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
        return (backup.playlists.count, matched, placeholders)
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
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    /// Removes unresolved (placeholder / dangling) entries from a playlist and re-indexes.
    func removePlaceholders(from playlist: Playlist) throws {
        let allTracks = (try? context.fetch(FetchDescriptor<Track>())) ?? []
        let validIDs = Set(allTracks.flatMap { $0.playlistEntries.map(\.persistentModelID) })
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
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        album.title = newTitle
        album.year = year
        let g = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
        album.genre = (g?.isEmpty ?? true) ? nil : g

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
            for track in movedTracks { track.artist = target }
            if let old = oldArtist, old.id != target.id {
                old.albums.removeAll { $0.id == album.id }
                old.tracks.removeAll { t in movedTracks.contains { $0.id == t.id } }
                if old.albums.isEmpty && old.tracks.isEmpty { context.delete(old) }
            }
        }

        for track in album.tracks { track.albumTitle = newTitle }
        try context.save()
    }

    /// Delete an entire album: every track (and its on-disk file) plus the album and
    /// any now-empty artist. Reuses `delete(track:)` which cascades the teardown.
    func removeAlbum(_ album: Album) throws {
        for track in Array(album.tracks) {
            try delete(track: track)
        }
    }

    // MARK: - Private

    private func deleteAlbum(_ album: Album) {
        if let artist = album.artist {
            artist.albums.removeAll { $0.id == album.id }
        }
        context.delete(album)
    }
}

struct LibraryStats {
    let trackCount: Int
    let albumCount: Int
    let artistCount: Int
    let totalDuration: TimeInterval

    var formattedDuration: String {
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
