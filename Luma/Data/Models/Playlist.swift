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

    /// Which cover style this playlist uses (raw value of `PlaylistCoverStyle`, default `.mosaic`).
    /// A cheap scalar column so reading it while building a card never faults the custom-image
    /// blob below. Defaulted → the SwiftData migration stays lightweight.
    var coverStyleRaw: Int = 0

    /// User-picked cover image, downscaled to ~1024px and kept entirely on-device. External
    /// storage keeps the blob out of the row, so it's faulted only when actually rendered (lazily,
    /// by ArtworkView), never on the card-build/scroll path.
    @Attribute(.externalStorage) var customArtworkData: Data?

    /// JSON-encoded `GeneratedCoverConfig` (a few bytes). Persisted whenever the generated look is
    /// edited so it's remembered even while another style is active.
    var generatedCoverConfig: Data?

    /// Bumped on every cover change so ArtworkView's decoded-image cache (keyed by playlist id)
    /// can't keep showing a stale photo after the user replaces it.
    var coverVersion: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
    var entries: [PlaylistEntry]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdDate = Date()
        self.entries = []
    }

    /// The chosen cover style, bridging the persisted raw value. Falls back to `.mosaic`.
    var coverStyle: PlaylistCoverStyle {
        get { PlaylistCoverStyle(rawValue: coverStyleRaw) ?? .mosaic }
        set { coverStyleRaw = newValue.rawValue }
    }

    /// The decoded generated-cover recipe, or a pleasant name-seeded default when none is stored.
    /// Reads only the small inline `generatedCoverConfig` blob — never the externalStorage image.
    var generatedConfigValue: GeneratedCoverConfig {
        guard let data = generatedCoverConfig,
              let cfg = try? JSONDecoder().decode(GeneratedCoverConfig.self, from: data)
        else { return .seeded(forName: name) }
        return cfg
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
