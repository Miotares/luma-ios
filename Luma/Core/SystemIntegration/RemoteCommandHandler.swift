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
        // Return .commandFailed (not .success) when the action no-ops — e.g. a "pause" press that
        // arrives while already paused — so iOS doesn't latch an inverted play/pause state and
        // routes the next press correctly.
        //
        // These handlers are invoked on an arbitrary MediaPlayer thread, but AudioPlayer is
        // @MainActor (the module defaults types to MainActor) and drives the AVAudioEngine. Under
        // Swift 5 language mode the cross-actor call compiles with NO runtime hop, so calling the
        // player directly here would mutate playback state + the engine off the main actor — racing
        // handleInterruption / handleRouteChange / the display timer (the overlapping stop()/play()
        // that throws the uncatchable Obj-C exception). `onMain` bounces synchronously so we can
        // still return the .success/.commandFailed status iOS needs to keep its play/pause in sync.
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onMain { self.player?.resume() ?? false } ? .success : .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onMain { self.player?.pause() ?? false } ? .success : .commandFailed
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.onMain { self.player?.togglePlayPause() ?? false } ? .success : .commandFailed
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
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.onMain { self.player?.seek(to: e.positionTime) }
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

    /// Runs `work` on the main actor and returns its result synchronously — so a remote-command
    /// handler can both drive the @MainActor player AND return the .success/.commandFailed status.
    /// `nonisolated` because the handler invokes it from MediaPlayer's own thread; the main-thread
    /// guard avoids a deadlock if MediaPlayer happens to deliver the command on the main thread.
    nonisolated private func onMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }
}
