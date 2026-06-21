import SwiftUI
import UniformTypeIdentifiers

/// On-disk playlist backup: playlist names + per-track metadata (NOT the audio). Tracks are
/// re-matched against the library by title/artist/album on import, so a backup survives a
/// reinstall — songs that aren't (yet) imported come in as grayed placeholders.
struct PlaylistBackup: Codable {
    var version: Int = 1
    var playlists: [BackupPlaylist]
}

struct BackupPlaylist: Codable {
    var name: String
    var tracks: [BackupTrack]
    /// Cover style raw value (`PlaylistCoverStyle`). Optional so older backups still decode; a
    /// `.photo` cover is exported as `.mosaic` since the on-device-only photo isn't carried.
    var coverStyle: Int? = nil
    /// The generated-cover recipe (tiny), so a `.generated` cover survives an export/import.
    var generatedCover: GeneratedCoverConfig? = nil
}

struct BackupTrack: Codable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var trackNumber: Int?
}

/// Wraps the backup JSON for SwiftUI's `.fileExporter` / `.fileImporter`.
struct PlaylistBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
