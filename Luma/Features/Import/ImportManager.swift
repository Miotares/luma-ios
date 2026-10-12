import Foundation
import SwiftData
import Observation
#if os(iOS)
import UIKit
#endif

@Observable
final class ImportManager {
    private(set) var isImporting = false
    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var totalCount = 0
    private(set) var importedCount = 0
    private(set) var failedCount = 0
    /// Outcome of the most recent import (kept until the next one starts), so the UI can say
    /// exactly what happened to every file instead of showing only the last error.
    private(set) var lastReport: ImportReport?
    /// True while the import sheet is on screen — it shows its own progress, so the app-wide
    /// progress capsule stays hidden.
    var isPresentingUI = false
    /// Fired (main actor) after an import finishes, so playlists can re-link placeholders.
    var onImportFinished: (() -> Void)?

    /// What an import did, file by file.
    struct ImportReport {
        struct Failure: Identifiable {
            let id = UUID()
            let fileName: String
            let reason: String
        }
        var imported = 0
        /// Skipped because the same file (by path) or the same song (by content) is already there.
        var alreadyPresent = 0
        var unsupported = 0
        var failures: [Failure] = []
        var wasCancelled = false

        var isClean: Bool { failures.isEmpty && unsupported == 0 && !wasCancelled }
    }

    nonisolated static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "flac", "aac", "wav", "aiff", "aif", "caf", "opus",
    ]

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
    /// Content signatures of everything in the library (see `signature`), so the SAME song arriving
    /// from a different folder / provider path isn't imported a second time.
    private var existingSignatures: Set<String> = []

    /// Imports requested while one is already running — processed right after it, never dropped.
    private var pendingURLs: [URL] = []
    private var cancelRequested = false
    private var report = ImportReport()
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Result of the off-actor copy+parse step, handed back to the main actor to insert.
    private struct ParsedFile: Sendable {
        let sourcePath: String
        let fileName: String
        let localFileName: String
        let metadata: TrackMetadata
        /// Lyrics from a `.lrc`/`.txt` file next to the source (only readable for folder imports).
        let sidecarLyrics: String?
    }
    private enum ParseOutcome: Sendable {
        case parsed(ParsedFile)
        case alreadyImported                           // same source path as an existing track
        case unsupported
        case cancelled
        case failed(fileName: String, reason: String)  // copy or parse error
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Entry points

    /// Entry point called from UI. Accepts files AND folders — folders are scanned recursively and
    /// all contained audio is imported. Safe to call while an import is running: the new URLs are
    /// queued and picked up as soon as the current batch is done (e.g. several files shared to
    /// Luma one after another).
    func importFiles(_ urls: [URL]) async {
        pendingURLs.append(contentsOf: urls)
        guard !isImporting else { return }

        isImporting = true
        cancelRequested = false
        progress = 0
        totalCount = 0
        importedCount = 0
        failedCount = 0
        report = ImportReport()
        lastReport = nil
        artistCache.removeAll()
        albumCache.removeAll()
        beginKeepAlive()

        // Snapshot the library once for cheap de-dup: source paths for the workers, content
        // signatures for the insert step.
        let existing = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        existingPaths = Set(existing.map(\.filePath))
        existingSignatures = Set(existing.map {
            Self.signature(title: $0.title, artist: $0.artistName, album: $0.albumTitle,
                           duration: $0.duration, trackNumber: $0.trackNumber)
        })

        var completed = 0
        while !pendingURLs.isEmpty, !cancelRequested {
            let batch = pendingURLs
            pendingURLs.removeAll()
            await run(batch, completed: &completed)
        }
        pendingURLs.removeAll()

        try? modelContext.save()
        endKeepAlive()
        report.wasCancelled = cancelRequested
        lastReport = report
        existingPaths.removeAll()
        existingSignatures.removeAll()
        isScanning = false
        isImporting = false
        onImportFinished?()
    }

    /// Stops the running import. Tracks imported so far stay; files still being copied finish and
    /// are kept (they're complete), nothing new is started.
    func cancel() {
        guard isImporting else { return }
        cancelRequested = true
    }

    // MARK: - One batch

    private func run(_ urls: [URL], completed: inout Int) async {
        isScanning = true

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
        guard !fileURLs.isEmpty else { return }
        totalCount += fileURLs.count
        let knownPaths = existingPaths

        // Bounded producer/consumer: keep at most `maxConcurrentCopies` copy+parse
        // tasks in flight, inserting each result on the main actor as it arrives.
        var nextIndex = 0
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
                        if try insertParsed(parsed) {
                            importedCount += 1
                            report.imported += 1
                            sinceSave += 1
                            if sinceSave >= saveInterval {
                                try? modelContext.save()
                                sinceSave = 0
                            }
                        } else {
                            // Same song already in the library — drop the copy we just made.
                            MediaStorage.delete(filename: parsed.localFileName)
                            report.alreadyPresent += 1
                        }
                    } catch {
                        MediaStorage.delete(filename: parsed.localFileName)
                        recordFailure(fileName: parsed.fileName, reason: error.localizedDescription)
                    }
                case .failed(let fileName, let reason):
                    recordFailure(fileName: fileName, reason: reason)
                case .alreadyImported:
                    report.alreadyPresent += 1
                case .unsupported:
                    report.unsupported += 1
                case .cancelled:
                    break
                }
                progress = totalCount > 0 ? min(1, Double(completed) / Double(totalCount)) : 0
                // After a cancel nothing new is started; what is already in flight still lands.
                if !cancelRequested { submitNext() }
            }
        }
    }

    private func recordFailure(fileName: String, reason: String) {
        failedCount += 1
        report.failures.append(.init(fileName: fileName, reason: reason))
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
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return .unsupported }
        if Task.isCancelled { return .cancelled }
        let fileName = url.lastPathComponent

        // Security-scoped access only for the COPY + parse. Once the file is in the
        // container, playback never touches the source again (Doppler model). Folder
        // children return false here but are covered by the parent folder's held access.
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            removeInboxCopy(url)
        }

        let sourcePath = url.path(percentEncoded: false)
        if known.contains(sourcePath) { return .alreadyImported }

        do {
            // COPY FIRST — the only read of the (security-scoped) source; downloads
            // the file from iCloud if needed. Then parse the LOCAL copy so AVAsset
            // never has to touch a security-scoped / dataless file.
            let localFileName = try MediaStorage.importFile(from: url)
            let localURL = MediaStorage.url(for: localFileName)
            do {
                // The copy is named by UUID, so hand the parser the ORIGINAL name for its
                // title fallback — otherwise an untagged file imports as "4D96906E-…".
                let metadata = try await MetadataParser().parse(
                    url: localURL,
                    fallbackName: url.deletingPathExtension().lastPathComponent
                )
                // The lyrics file stays behind in the source folder, so take its text along now —
                // embedded lyrics need no such step, they travel inside the copied audio file.
                return .parsed(ParsedFile(sourcePath: sourcePath, fileName: fileName,
                                          localFileName: localFileName, metadata: metadata,
                                          sidecarLyrics: LyricsReader.sidecarLyrics(for: url)))
            } catch {
                MediaStorage.delete(filename: localFileName) // roll back the copy
                // AVFoundation's own message for an unreadable file is just "Operation stopped".
                return .failed(fileName: fileName,
                               reason: String(localized: "Die Datei ist beschädigt oder kein lesbares Audioformat."))
            }
        } catch {
            return .failed(fileName: fileName, reason: error.localizedDescription)
        }
    }

    /// A file shared to Luma from another app ("Open in…" without in-place access) is handed over
    /// as a COPY in `Documents/Inbox`. Once it has been imported (or rejected) that copy is dead
    /// weight the user can't see from inside the app — remove it.
    nonisolated private static func removeInboxCopy(_ url: URL) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Identity of a song independent of where its file lives: tags + length. Two files with the
    /// same title, artist, album, track number and duration (to the second) are the same song.
    private static func signature(title: String, artist: String, album: String,
                                  duration: TimeInterval, trackNumber: Int) -> String {
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(norm(title))\u{1}\(norm(artist))\u{1}\(norm(album))\u{1}\(Int(duration.rounded()))\u{1}\(trackNumber)"
    }

    /// Inserts the parsed track. Returns false (inserting nothing) when the song is already in the
    /// library. Must run on MainActor because ModelContext is not Sendable across actor boundaries.
    @MainActor
    private func insertParsed(_ parsed: ParsedFile) throws -> Bool {
        guard !existingPaths.contains(parsed.sourcePath) else { return false }
        let metadata = parsed.metadata
        let signature = Self.signature(title: metadata.title, artist: metadata.artistName,
                                       album: metadata.albumTitle, duration: metadata.duration,
                                       trackNumber: metadata.trackNumber)
        guard !existingSignatures.contains(signature) else { return false }

        let artistName = metadata.albumArtistName ?? metadata.artistName
        let artist = findOrCreateArtist(name: artistName)
        let album = findOrCreateAlbum(
            title: metadata.albumTitle,
            artistName: artistName,
            artist: artist,
            year: metadata.year,
            genre: metadata.genre
        )

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

        // Store the cover (downscaled ~1024px thumbnail) inline. We deliberately do NOT also keep a
        // full-resolution copy on disk: nothing reads it (every surface, incl. the full-screen
        // player, caps decoding at ~1024px = the inline thumbnail). See LegacyArtworkCleanup.
        if let cover = metadata.artworkThumbnail ?? metadata.artworkData {
            if metadata.hasAlbumTag {
                if album.artworkData == nil { album.artworkData = cover }
            } else {
                // No album tag → the track sits in the catch-all "Unknown Album" with unrelated
                // songs. Its cover is its own, not that album's (which used to make every
                // untagged song show whichever cover was imported first).
                track.setCustomArtwork(cover)
            }
        }

        track.customLyrics = parsed.sidecarLyrics

        track.album = album
        track.artist = artist
        album.tracks.append(track)
        artist.tracks.append(track)

        modelContext.insert(track)
        existingPaths.insert(parsed.sourcePath)
        existingSignatures.insert(signature)
        return true
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

    // MARK: - Staying alive during a long import

    /// A mass import takes minutes. Without this the screen auto-locks, iOS suspends the app and
    /// the import silently stops part-way ("it only imported 180 of 1000"). Keep the screen awake
    /// while importing, and ask for background time so a quick app switch doesn't freeze it; if
    /// that time runs out, save what has been imported so nothing is lost.
    private func beginKeepAlive() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Luma Import") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? self.modelContext.save()
                self.endBackgroundTask()
            }
        }
        #endif
    }

    private func endKeepAlive() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        #endif
    }

    #if os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

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
