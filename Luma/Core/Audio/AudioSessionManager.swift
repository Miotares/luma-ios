import Foundation
#if os(iOS) || os(visionOS)
import AVFoundation

final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#else
// macOS: no AVAudioSession — playback category is set on the player directly.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}
    func activate() throws {}
    func deactivate() {}
}
#endif
