import SwiftData
import Foundation

@Model
final class Album {
    var id: UUID
    var title: String
    var artistName: String
    var year: Int?
    var genre: String?
    // Cover art bytes. `.externalStorage` keeps the (multi-MB) blob OUT of the SQLite row,
    // so materializing an Album / running an @Query<Album> doesn't fault the image off disk —
    // it's only read when artworkData is actually accessed.
    @Attribute(.externalStorage) var artworkData: Data?

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
