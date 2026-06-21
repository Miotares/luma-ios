import Foundation
import MediaPlayer
import ImageIO
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class NowPlayingManager {
    static let shared = NowPlayingManager()
    private init() {}

    private let center = MPNowPlayingInfoCenter.default()
    /// Local mirror of the info dict. Reading `center.nowPlayingInfo` is a slow
    /// synchronous IPC round-trip to the media server; mutating this cache instead
    /// keeps play/pause toggles off that hot path so the UI updates instantly.
    private var info: [String: Any] = [:]
    /// The track whose metadata/artwork is currently in `info`, so a pause/resume doesn't
    /// rebuild it (and doesn't momentarily reset elapsed to 0 → the lock-screen scrubber
    /// jumping to 0 and snapping back).
    private var currentTrackID: UUID?

    func update(track: Track, isPlaying: Bool, elapsed: TimeInterval) {
        // Rebuild the (expensive) metadata + artwork ONLY when the track actually changes.
        if track.id != currentTrackID {
            currentTrackID = track.id
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: track.title,
                MPMediaItemPropertyArtist: track.artistName,
                MPMediaItemPropertyAlbumTitle: track.albumTitle,
                MPMediaItemPropertyPlaybackDuration: track.duration,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            ]
            if let artworkData = track.album?.artworkData {
                info[MPMediaItemPropertyArtwork] = makeArtwork(from: artworkData)
            }
            self.info = info
        }
        // Always set the accurate elapsed + rate together, so the scrubber never resets.
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        // Drives the play/pause button on macOS (no central media server there). On iOS this
        // is effectively a no-op — iOS infers play/pause from the AVAudioSession's active
        // state, which is why AudioPlayer.enterBackground() releases the session when paused.
        center.playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        currentTrackID = nil
        info = [:]
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// Builds the lock-screen artwork WITHOUT decoding the cover here. The request handler is
    /// called by MediaPlayer (off the main thread) only when it actually needs the image, and
    /// decodes a thumbnail at the requested size via ImageIO. Previously this did a full
    /// `UIImage(data:)` (~1024px) decode ON THE MAIN ACTOR at every track change — a needless
    /// main-thread hitch that, with scrolling cover decodes, helped delay starting playback.
    private func makeArtwork(from data: Data) -> MPMediaItemArtwork {
        // Covers are square; a nominal 600px bounds is a fine hint for the lock screen.
        let bounds = CGSize(width: 600, height: 600)
        #if os(iOS) || os(visionOS)
        return MPMediaItemArtwork(boundsSize: bounds) { size in
            let px = max(64, Int(max(size.width, size.height).rounded(.up)))
            if let cg = Self.thumbnailCGImage(from: data, maxPixel: px) { return UIImage(cgImage: cg) }
            return UIImage()
        }
        #elseif os(macOS)
        return MPMediaItemArtwork(boundsSize: bounds) { size in
            let px = max(64, Int(max(size.width, size.height).rounded(.up)))
            if let cg = Self.thumbnailCGImage(from: data, maxPixel: px) { return NSImage(cgImage: cg, size: size) }
            return NSImage(size: size)
        }
        #endif
    }

    private static func thumbnailCGImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
