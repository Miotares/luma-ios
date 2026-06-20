import SwiftData
import Foundation

@Model
final class PlaylistEntry {
    var id: UUID
    var order: Int

    // Denormalized track metadata. Set for every entry, and the ONLY data a placeholder
    // entry carries — a placeholder (track == nil) is created when a backup is imported
    // before the song itself has been (re-)imported. Once a matching track appears it gets
    // re-linked (LibraryRepository.relinkPlaylistPlaceholders).
    var trackTitle: String = ""
    var trackArtist: String = ""
    var trackAlbum: String = ""

    @Relationship(deleteRule: .nullify)
    var track: Track?

    @Relationship(deleteRule: .nullify)
    var playlist: Playlist?

    init(track: Track, order: Int) {
        self.id = UUID()
        self.order = order
        self.track = track
        self.trackTitle = track.title
        self.trackArtist = track.artistName
        self.trackAlbum = track.albumTitle
    }

    /// A placeholder with no resolved track (from an imported backup).
    init(placeholderTitle: String, artist: String, album: String, order: Int) {
        self.id = UUID()
        self.order = order
        self.track = nil
        self.trackTitle = placeholderTitle
        self.trackArtist = artist
        self.trackAlbum = album
    }
}
