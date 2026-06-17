import Foundation
import SwiftData
import Observation

@Observable
final class ImportManager {
    private(set) var isImporting = false
    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var totalCount = 0
    private(set) var importedCount = 0
    private(set) var failedCount = 0
    var lastError: String?

    nonisolated static let supportedExtensions: Set<String> = ["mp3", "m4a", "flac", "aac", "wav", "aiff", "opus"]

    /// Number of files copied/parsed at once. A small pool keeps disk and the iCloud
    /// downloader busy without thrashing — spawning all ~1000 copies at once stalls at 0%.
    private let maxConcurrentCopies = 5
    /// Persist the SwiftData context every N inserts instead of once per track.
    private let saveInterval = 50

    private let modelContext: ModelContext

    // Import-time caches so artist/album lookup is O(1) instead of a fetch per track
    // (which turns a 1000-song import into O(n²) as the store grows).
    private var artistCache: [String: Artist] = [:]
    private var albumCache: [String: Album] = [:]
    private var existingPaths: Set<String> = []

    /// Result of the off-actor copy+parse step, handed back to the main actor to insert.
    private struct ParsedFile: Sendable {
        let sourcePath: String
        let localFileName: String
        let metadata: TrackMetadata
    }
    private enum ParseOutcome: Sendable {
        case parsed(ParsedFile)
        case skipped               // unsupported or already imported
        case failed(String)        // copy or parse error
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // Entry point called from UI. Accepts files AND folders — folders are
    // scanned recursively and all contained audio is imported.
    func importFiles(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        isScanning = true
        progress = 0
        totalCount = 0
        importedCount = 0
        failedCount = 0
        lastError = nil
        artistCache.removeAll()
        albumCache.removeAll()

        // Separate folders from loose files. Folder access is held open for the
        // whole import so child copies can read them; loose files re-acquire access
        // inside the worker.
        var folders: [URL] = []
        var looseFiles: [URL] = []
        var accessedFolders: [URL] = []
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
            if isDirectory {
                if didAccess { accessedFolders.append(url) }   // hold open for child copies
                folders.append(url)
            } else {
                if didAccess { url.stopAccessingSecurityScopedResource() }
                looseFiles.append(url)
            }
        }
        defer { accessedFolders.forEach { $0.stopAccessingSecurityScopedResource() } }

        // Enumerate folders off the main actor — walking a 1000-file iCloud tree
        // would otherwise freeze the UI before the progress bar even appears.
        let scanned = await Task.detached(priority: .userInitiated) { [folders] in
            folders.flatMap { ImportManager.audioFiles(in: $0) }
        }.value

        // De-duplicate the work list by path (a file could be picked twice).
        var seen = Set<String>()
        let fileURLs = (looseFiles + scanned).filter {
            seen.insert($0.path(percentEncoded: false)).inserted
        }

        isScanning = false
        guard !fileURLs.isEmpty else { isImporting = false; return }
        totalCount = fileURLs.count
        let total = Double(fileURLs.count)

        // Snapshot already-imported source paths once for cheap de-dup in workers.
        existingPaths = Set(((try? modelContext.fetch(FetchDescriptor<Track>())) ?? []).map { $0.filePath })
        let knownPaths = existingPaths

        // Bounded producer/consumer: keep at most `maxConcurrentCopies` copy+parse
        // tasks in flight, inserting each result on the main actor as it arrives.
        var nextIndex = 0
        var completed = 0
        var sinceSave = 0

        await withTaskGroup(of: ParseOutcome.self) { group in
            func submitNext() {
                guard nextIndex < fileURLs.count else { return }
                let url = fileURLs[nextIndex]
                nextIndex += 1
                group.addTask {
                    await ImportManager.copyAndParse(url, known: knownPaths)
                }
            }
            for _ in 0..<min(maxConcurrentCopies, fileURLs.count) { submitNext() }

            while let outcome = await group.next() {
                completed += 1
                switch outcome {
                case .parsed(let parsed):
                    do {
                        try insertParsed(parsed)
                        importedCount += 1
                        sinceSave += 1
                        if sinceSave >= saveInterval {
                            try? modelContext.save()
                            sinceSave = 0
                        }
                    } catch {
                        MediaStorage.delete(filename: parsed.localFileName)
                        failedCount += 1
                        lastError = error.localizedDescription
                    }
                case .failed(let message):
                    failedCount += 1
                    lastError = message
                case .skipped:
                    break
                }
                progress = Double(completed) / total
                submitNext()
            }
        }

        try? modelContext.save()
        isImporting = false
    }

    /// Recursively collects supported audio files within a folder.
    nonisolated static func audioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let fileURL as URL in enumerator {
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                result.append(fileURL)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Copies one source file into the container and parses its metadata. Runs OFF
    /// the main actor (nonisolated static) so `maxConcurrentCopies` of these run in
    /// parallel. The result is handed back to the main actor to insert.
    nonisolated private static func copyAndParse(_ url: URL, known: Set<String>) async -> ParseOutcome {
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return .skipped }

        // Security-scoped access only for the COPY + parse. Once the file is in the
        // container, playback never touches the source again (Doppler model). Folder
        // children return false here but are covered by the parent folder's held access.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let sourcePath = url.path(percentEncoded: false)
        if known.contains(sourcePath) { return .skipped }

        do {
            // COPY FIRST — the only read of the (security-scoped) source; downloads
            // the file from iCloud if needed. Then parse the LOCAL copy so AVAsset
            // never has to touch a security-scoped / dataless file.
            let localFileName = try MediaStorage.importFile(from: url)
            let localURL = MediaStorage.url(for: localFileName)
            do {
                let metadata = try await MetadataParser().parse(url: localURL)
                return .parsed(ParsedFile(sourcePath: sourcePath, localFileName: localFileName, metadata: metadata))
            } catch {
                MediaStorage.delete(filename: localFileName) // roll back the copy
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Must run on MainActor because ModelContext is not Sendable across actor boundaries.
    @MainActor
    private func insertParsed(_ parsed: ParsedFile) throws {
        guard !existingPaths.contains(parsed.sourcePath) else { return }
        let metadata = parsed.metadata

        let artistName = metadata.albumArtistName ?? metadata.artistName
        let artist = findOrCreateArtist(name: artistName)
        let album = findOrCreateAlbum(
            title: metadata.albumTitle,
            artistName: artistName,
            artist: artist,
            year: metadata.year,
            genre: metadata.genre
        )

        // Store artwork if album doesn't have it yet
        if album.artworkData == nil, let raw = metadata.artworkData {
            album.artworkData = raw
            // Hoist the Sendable id off the main actor — reading album.id (a non-Sendable
            // @Model) inside the detached task would be a data race during bulk import.
            let albumID = album.id
            Task.detached { await ArtworkCache.shared.store(raw, for: albumID) }
        }

        let track = Track(
            title: metadata.title,
            artistName: metadata.artistName,
            albumTitle: metadata.albumTitle,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: metadata.duration,
            localFileName: parsed.localFileName,
            filePath: parsed.sourcePath,
            genre: metadata.genre,
            year: metadata.year
        )
        track.album = album
        track.artist = artist
        album.tracks.append(track)
        artist.tracks.append(track)

        modelContext.insert(track)
        existingPaths.insert(parsed.sourcePath)
    }

    /// Cached lookup — one fetch per unique artist name, then served from memory.
    @MainActor
    private func findOrCreateArtist(name: String) -> Artist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let cached = artistCache[trimmed] { return cached }
        if let found = try? modelContext.fetch(
            FetchDescriptor<Artist>(predicate: #Predicate { $0.name == trimmed })
        ).first {
            artistCache[trimmed] = found
            return found
        }
        let artist = Artist(name: trimmed)
        modelContext.insert(artist)
        artistCache[trimmed] = artist
        return artist
    }

    /// Cached lookup keyed by (title, album-artist) — one fetch per unique album.
    @MainActor
    private func findOrCreateAlbum(
        title: String,
        artistName: String,
        artist: Artist,
        year: Int?,
        genre: String?
    ) -> Album {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespaces)
        let key = trimmedTitle + "\u{1}" + trimmedArtist
        if let cached = albumCache[key] { return cached }
        if let found = try? modelContext.fetch(
            FetchDescriptor<Album>(predicate: #Predicate {
                $0.title == trimmedTitle && $0.artistName == trimmedArtist
            })
        ).first {
            albumCache[key] = found
            return found
        }
        let album = Album(title: trimmedTitle, artistName: trimmedArtist, year: year, genre: genre)
        album.artist = artist
        modelContext.insert(album)
        albumCache[key] = album
        return album
    }

    // MARK: - Debug / Simulator

    #if DEBUG
    // Imports audio files directly from a host filesystem path.
    // Works in the iOS Simulator (same machine), not on device.
    func debugImportFromPath(_ libraryPath: String, maxAlbums: Int = 10) async {
        let root = URL(fileURLWithPath: libraryPath)
        let fm = FileManager.default
        guard let albumDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        let sorted = albumDirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxAlbums)

        var audioFiles: [URL] = []
        for albumDir in sorted {
            let contents = (try? fm.contentsOfDirectory(
                at: albumDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            let tracks = contents.filter {
                ImportManager.supportedExtensions.contains($0.pathExtension.lowercased())
            }
            audioFiles.append(contentsOf: tracks)
        }

        await importFiles(audioFiles)
    }
    #endif
}
