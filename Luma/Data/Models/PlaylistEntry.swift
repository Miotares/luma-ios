import SwiftData
import Foundation

@Model
final class PlaylistEntry {
    var id: UUID
    var order: Int

    @Relationship(deleteRule: .nullify)
    var track: Track?

    @Relationship(deleteRule: .nullify)
    var playlist: Playlist?

    init(track: Track, order: Int) {
        self.id = UUID()
        self.order = order
        self.track = track
    }
}
