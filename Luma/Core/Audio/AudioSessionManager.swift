import Foundation
#if os(iOS) || os(visionOS)
import AVFoundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        // Ask for a slightly larger render quantum (~20 ms vs the tiny system default). It widens the
        // real-time render deadline so a brief read-ahead/graph-lock hiccup — e.g. during a crossfade,
        // or while the queue's artwork I/O competes — is absorbed instead of surfacing as a replayed
        // buffer (the "last ~0.5 s repeats" underrun). `try?`: the system may clamp/ignore the request,
        // which is fine. ~20 ms of added output latency is below perceptible scrubber/lock-screen drift.
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
    }

    // NOTE: there is deliberately NO deactivate(). Deactivating the session on pause/background
    // hands the Now-Playing role to the system and lets iOS suspend us, so the PLAY remote command
    // never arrives and resume() never runs (the "play-after-pause dead over AirPods/lock screen"
    // bug). Keep the session active while paused; only the engine is idled. Do not re-add this.
}
#else
// macOS: no AVAudioSession — playback category is set on the player directly.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}
    func activate() throws {}
}
#endif
