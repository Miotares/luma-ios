import Foundation

/// Cover images as plain files in `Application Support/LumaCovers`, one per album (and one per
/// track that has its own cover).
///
/// They used to live in the library database (`Album.artworkData` / `Track.artworkData`). Those
/// attributes are declared `.externalStorage`, but Core Data only moves LARGE blobs out of the
/// row: in a real 119-album library 109 covers (21 MB of a 24 MB store) sat inside the album
/// table, so anything that fetched or prefetched albums dragged megabytes of image data through
/// SQLite on the main thread — on every list refresh. As files the covers cost nothing until one
/// is actually shown, and a memory-mapped read hands the bytes to the off-main decoder without
/// copying them on the main thread.
///
/// The database attributes still exist (removing them would be a schema change) and are read as a
/// fallback until `LibraryRepository.moveArtworkToFilesIfNeeded()` has moved an existing library's
/// covers over.
// Pure file I/O — nonisolated so it can run off the main actor (import, folder scan, migration).
nonisolated enum ArtworkStorage {
    /// Created on first use. Unlike the media folder this one is always part of a device backup:
    /// it is small, and without it a restored library would have no covers.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LumaCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func albumURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("album-\(id.uuidString)")
    }

    static func trackURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("track-\(id.uuidString)")
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Writes atomically and confirms the file really holds all the bytes — callers drop the
    /// database copy on the strength of this result.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        guard !data.isEmpty, (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == data.count
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
