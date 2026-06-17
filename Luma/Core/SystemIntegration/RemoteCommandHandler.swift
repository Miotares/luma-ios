import Foundation
import MediaPlayer

// Connects MPRemoteCommandCenter to AudioPlayer + PlaybackQueue.
// Must be kept alive for the lifetime of the app — owned by AppContainer.
final class RemoteCommandHandler {
    private let commandCenter = MPRemoteCommandCenter.shared()
    private weak var player: AudioPlayer?
    private weak var queue: PlaybackQueue?

    init(player: AudioPlayer, queue: PlaybackQueue) {
        self.player = player
        self.queue = queue
        register()
    }

    deinit {
        commandCenter.playCommand.removeTarget(self)
        commandCenter.pauseCommand.removeTarget(self)
        commandCenter.togglePlayPauseCommand.removeTarget(self)
        commandCenter.nextTrackCommand.removeTarget(self)
        commandCenter.previousTrackCommand.removeTarget(self)
        commandCenter.changePlaybackPositionCommand.removeTarget(self)
        commandCenter.skipForwardCommand.removeTarget(self)
        commandCenter.skipBackwardCommand.removeTarget(self)
    }

    private func register() {
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.player?.resume()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player?.togglePlayPause()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { await self?.queue?.advance() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { await self?.queue?.playPrevious() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seek(to: e.positionTime)
            return .success
        }

        // Show NEXT / PREVIOUS track on the lock screen & Control Center — not the
        // 15-second skip buttons. iOS prefers the skip commands whenever they're
        // enabled, so they must be explicitly disabled for a music player.
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }
}
