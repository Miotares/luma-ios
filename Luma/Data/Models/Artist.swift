import SwiftData
import Foundation

@Model
final class Artist {
    var id: UUID
    var name: String

    @Relationship(deleteRule: .nullify)
    var albums: [Album]

    @Relationship(deleteRule: .nullify)
    var tracks: [Track]

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.albums = []
        self.tracks = []
    }

    var sortedAlbums: [Album] {
        albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
    }

    var trackCount: Int { tracks.count }
    var albumCount: Int { albums.count }
}
