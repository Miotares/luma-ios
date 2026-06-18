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

    func update(track: Track, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]

        if let artworkData = track.album?.artworkData {
            info[MPMediaItemPropertyArtwork] = makeArtwork(from: artworkData)
        }

        self.info = info
        center.nowPlayingInfo = info
    }

    func updatePlaybackState(isPlaying: Bool, elapsed: TimeInterval) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
    }

    func clear() {
        info = [:]
        center.nowPlayingInfo = nil
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
