import AVFAudio
import Foundation

/// Derives the current play position (seconds into the track) from an AVAudioPlayerNode's
/// render time. AVAudioEngine has no `currentTime` like AVPlayer, so we anchor a known
/// position to the node's `sampleTime` and measure elapsed frames from there. Re-anchored on
/// every (re)schedule and seek, and falls back to a parked value when the node isn't
/// rendering (paused / prepared-but-not-started, e.g. the restore path).
@MainActor
final class PlayheadClock {
    /// Track position (seconds) captured at the last anchor.
    private var anchorSeconds: TimeInterval = 0
    /// Node sample time captured at that anchor.
    private var anchorSampleTime: AVAudioFramePosition = 0
    private var hasAnchor = false

    /// Whether a usable anchor is set (render time was available when anchored).
    var isAnchored: Bool { hasAnchor }

    /// Pin `seconds` to the node's current render position. Call right after scheduling +
    /// starting playback at a known offset (play / seek / gapless boundary).
    func anchor(seconds: TimeInterval, on node: AVAudioPlayerNode) {
        anchorSeconds = max(0, seconds)
        if let nodeTime = node.lastRenderTime,
           let playerTime = node.playerTime(forNodeTime: nodeTime) {
            anchorSampleTime = playerTime.sampleTime
            hasAnchor = true
        } else {
            anchorSampleTime = 0
            hasAnchor = false
        }
    }

    /// Drop the anchor (e.g. on stop) so `seconds(...)` returns the parked value.
    func invalidate() {
        hasAnchor = false
        anchorSeconds = 0
    }

    /// Current position in seconds. Returns `parked` while the node isn't actively rendering
    /// (paused or not yet started) so the UI shows the restored/seeked position.
    func seconds(on node: AVAudioPlayerNode, parked: TimeInterval) -> TimeInterval {
        guard hasAnchor, node.isPlaying,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else {
            return parked
        }
        let elapsed = Double(playerTime.sampleTime - anchorSampleTime) / playerTime.sampleRate
        return max(0, anchorSeconds + elapsed)
    }
}
