import Foundation
import SwiftData
import Observation

/// A file discovered inside a watched source folder (macOS reference library).
private struct ScannedFile: Sendable {
    let path: String
    let modified: Date?
    let size: Int64?
}

/// Main-actor progress holder for the watched-folder library. The heavy work runs on a
/// background ModelActor with its OWN context, so the bulk insert never touches the UI's
/// main context — `@Query` reacts to every insert, so inserting on the main context made
/// the library re-render per track (the carousel churn + lag). The background context is
/// isolated until it saves ONCE at the end, so the library updates a single time, smoothly.
@Observable
final class FolderLibraryScanner {
    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var statusText = ""
    var lastError: String?

    private let modelContainer: ModelContainer
    private let folders: LibraryFolders

    init(modelContainer: ModelContainer, folders: LibraryFolders) {
        self.modelContainer = modelContainer
        self.folders = folders
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        statusText = "Scanne Ordner…"
        lastError = nil
        defer { isScanning = false; statusText = "" }

        let sources = folders.folders
        let worker = LibraryScanWorker(modelContainer: modelContainer)
        await worker.scan(sources: sources) { [weak self] p, status in
            Task { @MainActor in
                guard let self else { return }
                self.progress = p
                if let status { self.statusText = status }
            }
        }
    }
}

/// Does the enumerate → diff → parse → insert work on its own background context.
@ModelActor
actor LibraryScanWorker {
    private let maxConcurrentParses = 5

    func scan(sources: [URL], progress: @escaping @Sendable (Double, String?) -> Void) async {
        // 1) Enumerate reachable sources + their files.
        let fm = FileManager.default
        var reachable: Set<String> = []
        var onDisk: [String: ScannedFile] = [:]
        for folder in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            reachable.insert(folder.standardizedFileURL.path)
            for url in ImportManager.audioFiles(in: folder) {
                let path = url.path(percentEncoded: false)
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                onDisk[path] = ScannedFile(path: path,
                                           modified: vals?.contentModificationDate,
                                           size: vals?.fileSize.map(Int64.init))
            }
        }

        modelContext.autosaveEnabled = false

        // 2) Index existing tracks by path.
        let existing = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        var byPath: [String: Track] = [:]
        for t in existing { byPath[t.filePath] = t }

        // 3) Removals: gone from disk AND not merely behind an unreachable source.
        for track in existing where onDisk[track.filePath] == nil {
            if Self.isUnderUnreachableSource(track.filePath, sources: sources, reachable: reachable) { continue }
            deleteTrack(track)
            byPath[track.filePath] = nil
        }

        // 4) Caches built AFTER removals so they never hand back a deleted object.
        var artistCache: [String: Artist] = [:]
        for a in (try? modelContext.fetch(FetchDescriptor<Artist>())) ?? [] { artistCache[a.name] = a }
        var albumCache: [String: Album] = [:]
        for al in (try? modelContext.fetch(FetchDescriptor<Album>())) ?? [] {
            albumCache[Self.albumKey(al.title, al.artistName)] = al
        }

        // 5) Work list: new files + changed files (modification date / size differs).
        var work: [ScannedFile] = []
        for (path, file) in onDisk {
            if let track = byPath[path] {
                if track.fileModifiedDate != file.modified || track.fileSize != file.size { work.append(file) }
            } else {
                work.append(file)
            }
        }

        guard !work.isEmpty else {
            try? modelContext.save()
            progress(1, nil)
            return
        }
        progress(0, "Lese Metadaten…")
        let total = Double(work.count)
        var done = 0
        var lastPct = -1

        await withTaskGroup(of: (ScannedFile, TrackMetadata?).self) { group in
            var index = 0
            func submit() {
                guard index < work.count else { return }
                let file = work[index]
                index += 1
                group.addTask {
                    let md = try? await MetadataParser().parse(url: URL(fileURLWithPath: file.path))
                    return (file, md)
                }
            }
            for _ in 0..<min(maxConcurrentParses, work.count) { submit() }

            while let (file, md) = await group.next() {
                if let md {
                    if let track = byPath[file.path] {
                        update(track, metadata: md, file: file, artistCache: &artistCache, albumCache: &albumCache)
                    } else {
                        let track = insert(metadata: md, file: file, artistCache: &artistCache, albumCache: &albumCache)
                        byPath[file.path] = track
                    }
                }
                done += 1
                let pct = Int(Double(done) / total * 100)
                if pct != lastPct { lastPct = pct; progress(Double(done) / total, nil) }
                submit()
            }
        }
        // Single save → the main context's @Query refreshes exactly once.
        try? modelContext.save()
        progress(1, nil)
    }

    // MARK: - Insert / Update / Delete

    private func insert(metadata md: TrackMetadata, file: ScannedFile,
                        artistCache: inout [String: Artist], albumCache: inout [String: Album]) -> Track {
        let albumArtistName = md.albumArtistName ?? md.artistName
        let artist = findOrCreateArtist(albumArtistName, cache: &artistCache)
        let album = findOrCreateAlbum(title: md.albumTitle, artistName: albumArtistName,
                                      artist: artist, year: md.year, genre: md.genre, cache: &albumCache)
        if album.artworkData == nil, let raw = md.artworkData {
            album.artworkData = raw
            let albumID = album.id
            Task.detached { await ArtworkCache.shared.store(raw, for: albumID) }
        }
        let track = Track(
            title: md.title, artistName: md.artistName, albumTitle: md.albumTitle,
            trackNumber: md.trackNumber, discNumber: md.discNumber, duration: md.duration,
            localFileName: nil, filePath: file.path, genre: md.genre, year: md.year,
            fileModifiedDate: file.modified, fileSize: file.size
        )
        track.album = album
        track.artist = artist
        album.tracks.append(track)
        artist.tracks.append(track)
        modelContext.insert(track)
        return track
    }

    private func update(_ track: Track, metadata md: TrackMetadata, file: ScannedFile,
                        artistCache: inout [String: Artist], albumCache: inout [String: Album]) {
        track.title = md.title
        track.artistName = md.artistName
        track.trackNumber = md.trackNumber
        track.discNumber = md.discNumber
        track.duration = md.duration
        track.genre = md.genre
        track.year = md.year
        track.fileModifiedDate = file.modified
        track.fileSize = file.size

        let albumArtistName = md.albumArtistName ?? md.artistName
        guard track.albumTitle != md.albumTitle || track.album?.artistName != albumArtistName else { return }

        let oldAlbum = track.album
        let oldArtist = track.artist
        let artist = findOrCreateArtist(albumArtistName, cache: &artistCache)
        let album = findOrCreateAlbum(title: md.albumTitle, artistName: albumArtistName,
                                      artist: artist, year: md.year, genre: md.genre, cache: &albumCache)
        oldAlbum?.tracks.removeAll { $0.id == track.id }
        oldArtist?.tracks.removeAll { $0.id == track.id }
        track.album = album
        track.artist = artist
        track.albumTitle = md.albumTitle
        album.tracks.append(track)
        artist.tracks.append(track)

        if let oldAlbum, oldAlbum.id != album.id, oldAlbum.tracks.isEmpty {
            albumCache[Self.albumKey(oldAlbum.title, oldAlbum.artistName)] = nil
            modelContext.delete(oldAlbum)
        }
        if let oldArtist, oldArtist.id != artist.id, oldArtist.tracks.isEmpty, oldArtist.albums.isEmpty {
            artistCache[oldArtist.name] = nil
            modelContext.delete(oldArtist)
        }
    }

    /// Removes a track's library entry (and now-empty album/artist). NEVER deletes the
    /// source file — referenced tracks have no `localFileName`.
    private func deleteTrack(_ track: Track) {
        if let album = track.album {
            album.tracks.removeAll { $0.id == track.id }
            if album.tracks.isEmpty {
                album.artist?.albums.removeAll { $0.id == album.id }
                modelContext.delete(album)
            }
        }
        if let artist = track.artist {
            artist.tracks.removeAll { $0.id == track.id }
            if artist.tracks.isEmpty && artist.albums.isEmpty { modelContext.delete(artist) }
        }
        modelContext.delete(track)
    }

    private func findOrCreateArtist(_ name: String, cache: inout [String: Artist]) -> Artist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let a = cache[trimmed] { return a }
        let artist = Artist(name: trimmed)
        modelContext.insert(artist)
        cache[trimmed] = artist
        return artist
    }

    private func findOrCreateAlbum(title: String, artistName: String, artist: Artist,
                                   year: Int?, genre: String?, cache: inout [String: Album]) -> Album {
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = artistName.trimmingCharacters(in: .whitespaces)
        let key = Self.albumKey(t, a)
        if let cached = cache[key] { return cached }
        let album = Album(title: t, artistName: a, year: year, genre: genre)
        album.artist = artist
        modelContext.insert(album)
        cache[key] = album
        return album
    }

    private static func albumKey(_ title: String, _ artistName: String) -> String {
        title.trimmingCharacters(in: .whitespaces) + "\u{1}" + artistName.trimmingCharacters(in: .whitespaces)
    }

    private static func isUnderUnreachableSource(_ path: String, sources: [URL], reachable: Set<String>) -> Bool {
        for src in sources {
            let sp = src.standardizedFileURL.path
            if !reachable.contains(sp), path == sp || path.hasPrefix(sp + "/") { return true }
        }
        return false
    }
}
