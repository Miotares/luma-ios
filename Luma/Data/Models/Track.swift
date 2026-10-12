import SwiftData
import Foundation

@Model
final class Track {
    var id: UUID
    var title: String
    var artistName: String
    var albumTitle: String
    var trackNumber: Int
    var discNumber: Int
    var duration: TimeInterval
    /// Relative filename of the imported copy inside the app's media container.
    /// Preferred for playback (Doppler model — no external access needed).
    var localFileName: String?
    /// Legacy security-scoped bookmark to an external file (pre-copy imports).
    var fileBookmarkData: Data?
    /// Original source path — kept for import de-duplication / info only.
    var filePath: String
    var addedDate: Date
    var lastPlayedDate: Date?
    var playCount: Int
    /// Total seconds actually listened across all plays — accumulates even when a
    /// track is skipped before its end, so listening stats include partial plays.
    var listenSeconds: TimeInterval = 0
    var isLiked: Bool
    var genre: String?
    var year: Int?
    /// Watched-folder (macOS) change detection — referenced files stay in place, so we
    /// re-read metadata only when the file's modification date or size changes.
    var fileModifiedDate: Date?
    var fileSize: Int64?
    /// Integrated loudness (LUFS) and sample peak (dBFS), measured once in the background by
    /// `LoudnessService` and used to play every track equally loud. nil = not measured yet.
    /// Optional so the SwiftData migration stays lightweight.
    var loudnessLUFS: Double?
    var loudnessPeakDB: Double?
    /// Lyrics stored WITH the track: the `.lrc`/`.txt` file that lay next to the audio at import
    /// (raw text, LRC timestamps kept). nil for most tracks — lyrics embedded in the file's tags
    /// are read on demand instead (LyricsReader), so they don't bloat the track rows. Takes
    /// precedence over the embedded lyrics. (The name dates from a lyrics editor that existed in a
    /// test build — its texts are removed by `LibraryRepository.clearTypedLyricsIfNeeded` — and
    /// stays because renaming an attribute is a schema change.)
    var customLyrics: String?
    /// The track's OWN cover — picked in the editor, or embedded in a file that has no album tag
    /// (those all share the catch-all "Unknown Album", so its cover can't speak for them). Most
    /// tracks have none and show their album's cover. The bytes are a file (`ArtworkStorage`, read
    /// through `ownCoverData`); `hasCustomArtwork` lets a list row decide which cover applies
    /// without touching the disk. This attribute is the LEGACY in-database copy, kept so the
    /// schema is unchanged and read only until it has been moved to a file.
    @Attribute(.externalStorage) private var artworkData: Data?
    var hasCustomArtwork: Bool = false
    /// Bumped on every cover change so ArtworkView's decoded-image cache can't show a stale one.
    var artworkVersion: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Album.tracks)
    var album: Album?

    @Relationship(deleteRule: .nullify, inverse: \Artist.tracks)
    var artist: Artist?

    /// Playlist memberships. Cascade-delete so removing a track also removes its
    /// playlist entries — otherwise they dangle and crash on access.
    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.track)
    var playlistEntries: [PlaylistEntry] = []

    init(
        id: UUID = UUID(),
        title: String,
        artistName: String,
        albumTitle: String,
        trackNumber: Int = 0,
        discNumber: Int = 1,
        duration: TimeInterval,
        localFileName: String? = nil,
        fileBookmarkData: Data? = nil,
        filePath: String,
        addedDate: Date = Date(),
        genre: String? = nil,
        year: Int? = nil,
        fileModifiedDate: Date? = nil,
        fileSize: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.localFileName = localFileName
        self.fileBookmarkData = fileBookmarkData
        self.filePath = filePath
        self.addedDate = addedDate
        self.lastPlayedDate = nil
        self.playCount = 0
        self.isLiked = false
        self.genre = genre
        self.year = year
        self.fileModifiedDate = fileModifiedDate
        self.fileSize = fileSize
    }

    /// Resolves the playable URL. Prefers the local imported copy (no
    /// security-scoped access needed); falls back to the legacy bookmark.
    /// For bookmark-based tracks the caller must `startAccessingSecurityScopedResource()`.
    nonisolated func resolveURL() throws -> URL {
        if let localFileName {
            return MediaStorage.url(for: localFileName)
        }
        if let fileBookmarkData {
            var isStale = false
            #if os(macOS)
            return try URL(
                resolvingBookmarkData: fileBookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            return try URL(
                resolvingBookmarkData: fileBookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif
        }
        // Watched-folder reference model (macOS): the file lives at its original path and
        // is never copied. Play it directly from there.
        if !filePath.isEmpty {
            return URL(fileURLWithPath: filePath)
        }
        throw MediaStorage.StorageError.missingFile
    }

    /// The track's own cover, if it has one.
    var ownCoverData: Data? {
        guard hasCustomArtwork else { return nil }
        return ArtworkStorage.read(ArtworkStorage.trackURL(id)) ?? legacyCoverData
    }

    /// The cover to show for this track: its own if it has one, otherwise its album's.
    func resolvedArtworkData() -> Data? {
        ownCoverData ?? album?.coverData
    }

    /// Cheap, stable key for the decoded-image cache — changes whenever the visible cover does.
    var artworkCacheKey: String {
        hasCustomArtwork ? "\(id.uuidString)-t\(artworkVersion)" : (album?.artworkCacheKey ?? id.uuidString)
    }

    /// Sets (or, with nil, removes) the track's own cover.
    func setCustomArtwork(_ data: Data?) {
        let url = ArtworkStorage.trackURL(id)
        if let data, !data.isEmpty {
            if ArtworkStorage.write(data, to: url) {
                if artworkData != nil { artworkData = nil }
            } else {
                artworkData = data   // disk refused the file — keep the cover in the database instead
            }
            hasCustomArtwork = true
        } else {
            ArtworkStorage.remove(url)
            if artworkData != nil { artworkData = nil }
            hasCustomArtwork = false
        }
        artworkVersion &+= 1
    }

    /// The database copy — what the one-time move to files still has to pick up (nil once it is
    /// done). Empty counts as none (see `Album.legacyCoverData`).
    var legacyCoverData: Data? {
        guard let data = artworkData, !data.isEmpty else { return nil }
        return data
    }

    /// Drops the database copy — only after the file has been written and verified.
    func clearLegacyCover() {
        if artworkData != nil { artworkData = nil }
    }

    /// True when the track has a local copy (no external source needed).
    nonisolated var hasLocalCopy: Bool { localFileName != nil }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
