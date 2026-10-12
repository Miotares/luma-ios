import SwiftData
import Foundation

@Model
final class Album {
    var id: UUID
    var title: String
    var artistName: String
    var year: Int?
    var genre: String?
    /// LEGACY cover bytes inside the database — covers are files now (`ArtworkStorage`, read
    /// through `coverData`). The attribute stays so the schema is unchanged and so a library from
    /// an older version keeps its covers until they have been moved over; it is private so nothing
    /// else reads or writes it by accident.
    @Attribute(.externalStorage) private var artworkData: Data?
    /// Bumped whenever the cover is replaced in the editor, so ArtworkView's decoded-image cache
    /// (keyed by `artworkCacheKey`) drops the old one. Defaulted → lightweight migration.
    var artworkVersion: Int = 0

    @Relationship(deleteRule: .nullify)
    var tracks: [Track]

    @Relationship(deleteRule: .nullify, inverse: \Artist.albums)
    var artist: Artist?

    init(
        id: UUID = UUID(),
        title: String,
        artistName: String,
        year: Int? = nil,
        genre: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.year = year
        self.genre = genre
        self.artworkData = nil
        self.tracks = []
    }

    /// Cheap, stable key for the decoded-image cache — changes whenever the cover is replaced.
    var artworkCacheKey: String {
        artworkVersion == 0 ? id.uuidString : "\(id.uuidString)-a\(artworkVersion)"
    }

    // MARK: - Cover

    /// The cover's bytes: the file, or — for a library whose covers haven't been moved yet — the
    /// copy still in the database.
    var coverData: Data? {
        ArtworkStorage.read(ArtworkStorage.albumURL(id)) ?? legacyCoverData
    }

    var hasCover: Bool {
        ArtworkStorage.exists(ArtworkStorage.albumURL(id)) || legacyCoverData != nil
    }

    /// Sets (or, with nil, removes) the cover. Does NOT bump `artworkVersion` — callers that
    /// REPLACE a cover the UI may already have cached do that.
    func setCover(_ data: Data?) {
        let url = ArtworkStorage.albumURL(id)
        guard let data else {
            ArtworkStorage.remove(url)
            if artworkData != nil { artworkData = nil }
            return
        }
        if ArtworkStorage.write(data, to: url) {
            if artworkData != nil { artworkData = nil }
        } else {
            artworkData = data   // disk refused the file — keep the cover in the database instead
        }
    }

    /// The database copy — what the one-time move to files still has to pick up (nil once it is
    /// done). An EMPTY value counts as none: SwiftData turns a NULL in this column into empty
    /// data when it rewrites an album row from an older store, and treating that as "has a
    /// cover" kept such an album from ever receiving one.
    var legacyCoverData: Data? {
        guard let data = artworkData, !data.isEmpty else { return nil }
        return data
    }

    /// Drops the database copy — only after the file has been written and verified.
    func clearLegacyCover() {
        if artworkData != nil { artworkData = nil }
    }

    var sortedTracks: [Track] {
        tracks.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.trackNumber < $1.trackNumber
        }
    }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    var formattedTotalDuration: String {
        let total = Int(totalDuration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}
