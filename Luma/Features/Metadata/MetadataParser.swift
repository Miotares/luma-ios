import AVFoundation
import Foundation

struct TrackMetadata {
    var title: String
    var artistName: String
    var albumTitle: String
    var albumArtistName: String?
    var trackNumber: Int
    var discNumber: Int
    var duration: TimeInterval
    var genre: String?
    var year: Int?
    var artworkData: Data?
    /// Downscaled cover (~1024 px) stored inline on the Album row — what every surface renders.
    /// (`artworkData` holds the full-resolution source only transiently during parsing; it is no
    /// longer persisted separately — that on-disk copy was write-only. See LegacyArtworkCleanup.)
    var artworkThumbnail: Data?
    /// Whether the file carried an album tag. Untagged files all share the "Unknown Album" bucket,
    /// so their embedded cover belongs to the track, not to that catch-all album.
    var hasAlbumTag: Bool = true
}

// Stateless value-type parser — nonisolated so it runs on the cooperative thread pool.
struct MetadataParser {
    /// `fallbackName` is the file's ORIGINAL name (without extension) for when `url` points at a
    /// container copy stored under a UUID — fields the tags don't provide are guessed from it.
    nonisolated func parse(url: URL, fallbackName: String? = nil) async throws -> TrackMetadata {
        let asset = AVURLAsset(url: url)

        async let durationLoad = asset.load(.duration)
        async let commonLoad = asset.load(.commonMetadata)
        async let id3Load = asset.loadMetadata(for: .id3Metadata)
        async let itunesLoad = asset.loadMetadata(for: .iTunesMetadata)
        async let everythingLoad = asset.load(.metadata)

        let (durTime, common, id3, itunes) = try await (durationLoad, commonLoad, id3Load, itunesLoad)
        // Vorbis comments (FLAC/Opus) appear ONLY in the asset-wide list — `commonMetadata` is empty
        // for them, which is why every FLAC used to import without title/artist/album.
        let others = ((try? await everythingLoad) ?? []).filter {
            $0.keySpace != .common && $0.keySpace != .id3 && $0.keySpace != .iTunes
        }
        let allItems = common + id3 + itunes + others

        // Collect raw parsed values then build the result — avoids mutating async on struct.
        var title: String?
        var artistName: String?
        var albumTitle: String?
        var albumArtistName: String?
        var trackNumber = 0
        var discNumber = 1
        var genre: String?
        var year: Int?
        var artworkData: Data?

        for item in allItems {
            if let key = item.commonKey {
                switch key {
                case .commonKeyTitle:
                    if let v = Self.nonEmpty(try? await item.load(.stringValue)) { title = v }
                case .commonKeyArtist:
                    if let v = Self.nonEmpty(try? await item.load(.stringValue)) { artistName = v }
                case .commonKeyAlbumName:
                    if let v = Self.nonEmpty(try? await item.load(.stringValue)) { albumTitle = v }
                case .commonKeyType:
                    genre = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    if artworkData == nil { artworkData = try? await item.load(.dataValue) }
                default: break
                }
                continue
            }

            switch item.identifier {
            case .id3MetadataTrackNumber:
                if let v = try? await item.load(.stringValue) {
                    trackNumber = Int(v.components(separatedBy: "/").first ?? "") ?? trackNumber
                }
            case .id3MetadataPartOfASet:
                if let v = try? await item.load(.stringValue) {
                    discNumber = Int(v.components(separatedBy: "/").first ?? "") ?? discNumber
                }
            case .id3MetadataYear:
                if let v = try? await item.load(.stringValue) { year = Int(v.prefix(4)) }
            case .id3MetadataRecordingTime:
                if year == nil, let v = try? await item.load(.stringValue) { year = Int(v.prefix(4)) }
            case .id3MetadataAttachedPicture:
                if artworkData == nil { artworkData = try? await item.load(.dataValue) }
            case .id3MetadataBand:
                // ID3 TPE2 = "Band/orchestra/accompaniment" — the Album Artist for
                // MP3s. Without this, featured tracks (different song artist) would
                // each become their own album.
                if let v = try? await item.load(.stringValue), !v.isEmpty { albumArtistName = v }
            case .iTunesMetadataAlbumArtist:
                if let v = try? await item.load(.stringValue), !v.isEmpty { albumArtistName = v }
            case .iTunesMetadataReleaseDate:
                if let v = try? await item.load(.stringValue) { year = Int(v.prefix(4)) }
            case .iTunesMetadataCoverArt:
                if artworkData == nil { artworkData = try? await item.load(.dataValue) }
            case .iTunesMetadataTrackNumber:
                if let n = Self.iTunesIndex(try? await item.load(.dataValue)) { trackNumber = n }
            case .iTunesMetadataDiscNumber:
                if let n = Self.iTunesIndex(try? await item.load(.dataValue)) { discNumber = n }
            default:
                // Vorbis comment fields without a common key, addressed by their plain-text name.
                guard let key = (item.key as? String)?.uppercased(),
                      let v = Self.nonEmpty(try? await item.load(.stringValue)) else { break }
                switch key {
                case "TRACKNUMBER":
                    trackNumber = Int(v.components(separatedBy: "/").first ?? "") ?? trackNumber
                case "DISCNUMBER":
                    discNumber = Int(v.components(separatedBy: "/").first ?? "") ?? discNumber
                case "DATE", "YEAR":
                    if year == nil { year = Int(v.prefix(4)) }
                case "GENRE":
                    if genre == nil { genre = v }
                case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST":
                    albumArtistName = v
                default: break
                }
            }
        }

        // AVFoundation doesn't expose a FLAC's PICTURE block, so read it directly.
        if artworkData == nil, url.pathExtension.lowercased() == "flac" {
            artworkData = FLACPicture.read(url: url)
        }

        // Downscale once here, off the main actor, so the import sites can store a small (~1024px)
        // thumbnail inline on the album row (the only persisted copy).
        let artworkThumbnail = artworkData.map { ImageDownscaler.thumbnail(from: $0) }

        // Whatever the tags left open is guessed from the file name.
        let guess = FilenameMetadata.guess(
            fromStem: fallbackName ?? url.deletingPathExtension().lastPathComponent
        )

        return TrackMetadata(
            title: title ?? guess.title,
            artistName: artistName ?? guess.artist ?? "Unknown Artist",
            albumTitle: albumTitle ?? "Unknown Album",
            albumArtistName: albumArtistName,
            trackNumber: trackNumber > 0 ? trackNumber : (guess.trackNumber ?? 0),
            discNumber: discNumber,
            duration: durTime.seconds.isFinite ? durTime.seconds : 0,
            genre: genre,
            year: year,
            artworkData: artworkData,
            artworkThumbnail: artworkThumbnail,
            hasAlbumTag: albumTitle != nil
        )
    }

    /// iTunes `trkn` / `disk` atoms are binary: 2 reserved bytes, then the index as a big-endian
    /// UInt16 (followed by the total).
    private nonisolated static func iTunesIndex(_ data: Data?) -> Int? {
        guard let bytes = data.map([UInt8].init), bytes.count >= 4 else { return nil }
        let n = Int(bytes[2]) << 8 | Int(bytes[3])
        return n > 0 ? n : nil
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
