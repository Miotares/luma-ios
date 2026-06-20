import Foundation
import MediaPlayer
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
        // REQUIRED for an AVAudioEngine (non-AVPlayer) app: the lock-screen / Control Center
        // play-pause button is driven by playbackState, NOT the info-dict rate. Without it iOS
        // guesses from the rate/session and the button gets stuck out of sync (first tap
        // ignored). Set it AFTER nowPlayingInfo.
        center.playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        currentTrackID = nil
        info = [:]
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        #if os(iOS) || os(visionOS)
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #else
        return nil
        #endif
    }
}
