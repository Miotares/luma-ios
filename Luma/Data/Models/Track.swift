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

    /// True when the track has a local copy (no external source needed).
    nonisolated var hasLocalCopy: Bool { localFileName != nil }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
