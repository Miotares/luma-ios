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
}

// Stateless value-type parser — nonisolated so it runs on the cooperative thread pool.
struct MetadataParser {
    nonisolated func parse(url: URL) async throws -> TrackMetadata {
        let asset = AVURLAsset(url: url)

        async let durationLoad = asset.load(.duration)
        async let commonLoad = asset.load(.commonMetadata)
        async let id3Load = asset.loadMetadata(for: .id3Metadata)
        async let itunesLoad = asset.loadMetadata(for: .iTunesMetadata)

        let (durTime, common, id3, itunes) = try await (durationLoad, commonLoad, id3Load, itunesLoad)
        let allItems = common + id3 + itunes

        // Collect raw parsed values then build the result — avoids mutating async on struct.
        var title = url.deletingPathExtension().lastPathComponent
        var artistName = "Unknown Artist"
        var albumTitle = "Unknown Album"
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
                    if let v = try? await item.load(.stringValue) { title = v }
                case .commonKeyArtist:
                    if let v = try? await item.load(.stringValue) { artistName = v }
                case .commonKeyAlbumName:
                    if let v = try? await item.load(.stringValue) { albumTitle = v }
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
            default: break
            }
        }

        return TrackMetadata(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artistName: artistName.trimmingCharacters(in: .whitespacesAndNewlines),
            albumTitle: albumTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtistName: albumArtistName,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: durTime.seconds.isFinite ? durTime.seconds : 0,
            genre: genre,
            year: year,
            artworkData: artworkData
        )
    }
}
