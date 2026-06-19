import SwiftData
import Foundation

@Model
final class Playlist {
    var id: UUID
    var name: String
    var createdDate: Date
    /// User-defined order of playlists in the Playlists tab (lower = higher up). Defaulted
    /// so the SwiftData migration stays lightweight; existing playlists are backfilled once
    /// from `createdDate` by `LibraryRepository.seedPlaylistOrderIfNeeded()`.
    var sortIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
    var entries: [PlaylistEntry]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.entries = []
    }

    var sortedTracks: [Track] {
        entries
            .sorted { $0.order < $1.order }
            .compactMap { $0.track }
    }

    var artworkData: Data? {
        sortedTracks.first { $0.album?.artworkData != nil }?.album?.artworkData
    }

    var totalDuration: TimeInterval {
        sortedTracks.reduce(0) { $0 + $1.duration }
    }

    var formattedDuration: String {
        let total = Int(totalDuration)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h) Std \(m) Min" : "\(m) Min"
    }

    func containsTrack(_ track: Track) -> Bool {
        // Via the track's own entries (safe) — never touches other entries whose
        // track may have been deleted.
        track.playlistEntries.contains { $0.playlist?.id == id }
    }

    func nextOrder() -> Int {
        (entries.map(\.order).max() ?? -1) + 1
    }
}
