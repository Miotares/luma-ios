import Foundation
import SwiftData
import Observation

/// A file discovered inside a watched source folder (macOS reference library).
private struct ScannedFile: Sendable {
    let path: String
    let modified: Date?
    let size: Int64?
}

/// Builds and maintains the macOS library by REFERENCING audio files in user-chosen
/// folders (foobar style): files are never copied, never deleted. Each scan adds new
/// files, re-reads changed ones (by modification date / size) and removes entries whose
/// file is gone — but never prunes tracks behind a source that is currently unreachable
/// (e.g. an unmounted drive), so the library survives offline volumes.
@Observable
final class FolderLibraryScanner {
    private(set) var isScanning = false
    private(set) var progress: Double = 0
    private(set) var statusText = ""
    var lastError: String?

    private let modelContext: ModelContext
    private let folders: LibraryFolders
    private let library: LibraryRepository
    private let maxConcurrentParses = 5

    init(modelContext: ModelContext, folders: LibraryFolders, library: LibraryRepository) {
        self.modelContext = modelContext
        self.folders = folders
        self.library = library
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        statusText = "Scanne Ordner…"
        lastError = nil
        // Pause autosave so the bulk insert doesn't fire a @Query update (and a full
        // library re-render) on every run-loop turn — that caused the import lag and the
        // "recently added" carousel thrashing. We save in batches instead.
        modelContext.autosaveEnabled = false
        defer { isScanning = false; statusText = ""; modelContext.autosaveEnabled = true }

        let sources = folders.folders

        // 1) Enumerate reachable sources + their files off the main actor.
        let (reachablePaths, onDisk) = await Task.detached(priority: .userInitiated) { () -> ([String], [String: ScannedFile]) in
            let fm = FileManager.default
            var reachable: [String] = []
            var files: [String: ScannedFile] = [:]
            for folder in sources {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
                reachable.append(folder.standardizedFileURL.path)
                for url in ImportManager.audioFiles(in: folder) {
                    let path = url.path(percentEncoded: false)
                    let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    files[path] = ScannedFile(
                        path: path,
                        modified: vals?.contentModificationDate,
                        size: vals?.fileSize.map(Int64.init)
                    )
                }
            }
            return (reachable, files)
        }.value

        let reachableSet = Set(reachablePaths)

        // 2) Index existing tracks by path.
        let existing = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        var byPath: [String: Track] = [:]
        for t in existing { byPath[t.filePath] = t }

        // 3) Removals: file no longer on disk AND not merely behind an unreachable source.
        for track in existing where onDisk[track.filePath] == nil {
            if Self.isUnderUnreachableSource(track.filePath, sources: sources, reachable: reachableSet) { continue }
            try? library.delete(track: track)
            byPath[track.filePath] = nil
        }

        // 4) Build artist/album caches AFTER removals (which may have deleted empties),
        //    so cached lookups never hand back a deleted object.
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

        guard !work.isEmpty else { progress = 1; try? modelContext.save(); return }
        statusText = "Lese Metadaten…"
        let total = Double(work.count)
        var done = 0

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

            var sinceSave = 0
            while let (file, md) = await group.next() {
                if let md {
                    if let track = byPath[file.path] {
                        update(track, metadata: md, file: file, artistCache: &artistCache, albumCache: &albumCache)
                    } else {
                        let track = insert(metadata: md, file: file, artistCache: &artistCache, albumCache: &albumCache)
                        byPath[file.path] = track
                    }
                    sinceSave += 1
                    if sinceSave >= 400 { try? modelContext.save(); sinceSave = 0 }
                }
                done += 1
                progress = Double(done) / total
                submit()
            }
        }
        try? modelContext.save()
    }

    // MARK: - Insert / Update (main actor)

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
        let needsRelink = track.albumTitle != md.albumTitle || track.album?.artistName != albumArtistName
        guard needsRelink else { return }

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
