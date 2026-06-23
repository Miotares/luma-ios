import Foundation
import MediaPlayer
import os

// Connects MPRemoteCommandCenter to AudioPlayer + PlaybackQueue.
// Must be kept alive for the lifetime of the app — owned by AppContainer.
final class RemoteCommandHandler {
    /// Logs which remote command actually fires (lock screen, Control Center, AirPods/headset).
    /// View with: Console.app → filter subsystem "Luma", category "remote" (or `log stream
    /// --predicate 'subsystem == "Luma"'`). This is how we tell whether an AirPods "play" press
    /// arrives as togglePlayPause / play / pause — the crux of the play-after-pause bug.
    private static let log = Logger(subsystem: "Luma", category: "remote")
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
            let before = self?.player?.state
            let ok = self?.player?.resume() ?? false
            Self.log.info("play command (state=\(String(describing: before), privacy: .public)) → resumed=\(ok, privacy: .public)")
            return ok ? .success : .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            let before = self?.player?.state
            let ok = self?.player?.pause() ?? false
            Self.log.info("pause command (state=\(String(describing: before), privacy: .public)) → paused=\(ok, privacy: .public)")
            return ok ? .success : .commandFailed
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            let before = self?.player?.state
            let ok = self?.player?.togglePlayPause() ?? false
            Self.log.info("toggle command (state=\(String(describing: before), privacy: .public)) → acted=\(ok, privacy: .public)")
            return ok ? .success : .commandFailed
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
