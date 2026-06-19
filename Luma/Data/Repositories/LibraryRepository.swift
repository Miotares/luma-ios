import Foundation
import SwiftData
import SwiftUI

// Encapsulates common library mutations that go beyond simple @Query usage.
// All methods run on MainActor (same as ModelContext).
final class LibraryRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Track Updates

    func recordPlay(track: Track) throws {
        track.playCount += 1
        track.lastPlayedDate = Date()
        // Defer the save off the current frame — these stats writes invalidate the library
        // @Query views, so saving inline stalled playback/track-change interactions.
        Task { @MainActor in try? self.context.save() }
    }

    /// Adds actually-listened seconds to a track (called by the player in ~5s batches,
    /// so partial/skipped plays still count toward listening statistics).
    func addListenTime(to track: Track, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        track.listenSeconds += seconds
        Task { @MainActor in try? self.context.save() }
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
        // Persist off the tap's frame — a synchronous save can stall the frame that
        // flips the heart, making the like feel delayed. The `isLiked` change above is
        // already observable; the save just follows on the next main-actor turn. Self is
        // @MainActor, so the context never leaves the main actor.
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
