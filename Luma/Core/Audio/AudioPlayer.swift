import AVFoundation
import Foundation
import MediaPlayer
import Observation

@Observable
final class AudioPlayer {
    // MARK: - Public State (observed by UI)

    private(set) var currentTrack: Track?
    private(set) var state: PlaybackState = .stopped
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    static let volumeDefaultsKey = "playerVolume"
    var volume: Float = {
        if let stored = UserDefaults.standard.object(forKey: AudioPlayer.volumeDefaultsKey) as? Double {
            return Float(stored)
        }
        return 1.0
    }() {
        didSet {
            player?.volume = volume
            UserDefaults.standard.set(Double(volume), forKey: AudioPlayer.volumeDefaultsKey)
        }
    }

    enum PlaybackState: Equatable {
        case stopped, playing, paused, buffering
        var isActive: Bool { self != .stopped }
        var isPlaying: Bool { self == .playing }
    }

    // MARK: - Internal

    weak var queue: PlaybackQueue?
    var onTrackComplete: ((Track) -> Void)?
    var onTrackChanged: ((Track) -> Void)?
    /// Called in ~5-second batches with the seconds actually listened of a track, so
    /// stats can count partial (skipped) plays — not just tracks played to the end.
    var onListened: ((Track, TimeInterval) -> Void)?
    /// Fired when the session state worth persisting changed — on pause/stop and on a
    /// ~5s throttle while playing — so the queue + play head can be saved for resume.
    var onPersist: (() -> Void)?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var accessedURL: URL? // tracks security-scoped resource access

    // Actual-listening accumulation (drives the listening-time statistics).
    private var lastListenPos: TimeInterval = 0
    private var pendingListen: TimeInterval = 0
    // Last position at which the session was persisted, to throttle saves while playing.
    private var lastPersistPos: TimeInterval = 0
    // Bounds the skip-on-unplayable loop so an all-missing queue stops instead of looping.
    private var skipFailures = 0

    // Crossfade: the outgoing player overlaps the incoming one while volumes ramp.
    static let crossfadeDefaultsKey = "crossfadeDuration"
    private var fadeOutPlayer: AVPlayer?
    private var fadeTimer: Timer?
    private var isCrossfading = false
    private var crossfadeDuration: TimeInterval {
        max(0, UserDefaults.standard.double(forKey: Self.crossfadeDefaultsKey))
    }

    private let session = AudioSessionManager.shared
    private let nowPlaying = NowPlayingManager.shared

    init() {
        setupSystemNotifications()
    }

    deinit {
        teardown()
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Playback Control

    func play(track: Track) async {
        // Attribute any unsaved listening to the outgoing track before we switch.
        flushListen()

        guard let url = resolveURL(for: track), isPlayable(url, localCopy: track.hasLocalCopy) else {
            // Unplayable (missing/moved/deleted file) — skip forward to the next playable
            // track instead of dead-stopping in a fake `.playing` state.
            await handleUnplayable()
            return
        }
        skipFailures = 0

        do { try session.activate() } catch { return }

        stopAccessingCurrentResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url

        teardown()

        currentTrack = track
        onTrackChanged?(track)
        duration = 0
        currentTime = 0
        lastListenPos = 0

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item

        player = AVPlayer(playerItem: item)
        player?.volume = volume

        addTimeObserver()
        observeItemEnd()

        player?.play()
        state = .playing

        // Defer the Now Playing write (full-res artwork decode + synchronous media-server
        // IPC) off the tapped frame so the UI repaints immediately.
        Task { @MainActor [weak self] in
            guard let self, let t = self.currentTrack else { return }
            self.nowPlaying.update(track: t, isPlaying: true)
        }
    }

    /// Loads a track WITHOUT starting playback, parked at `position` — used to restore the
    /// previous session. Ends in `.paused`; the audio session is deliberately NOT activated
    /// here (that happens on resume), so relaunching the app never interrupts other apps'
    /// audio when the user doesn't actually press play.
    func prepare(track: Track, at position: TimeInterval) async {
        guard let url = resolveURL(for: track), isPlayable(url, localCopy: track.hasLocalCopy) else { return }

        stopAccessingCurrentResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url

        teardown()

        currentTrack = track
        onTrackChanged?(track)
        currentTime = max(0, position)
        // Seed from the track's metadata duration so the progress bar is correct while
        // parked & paused — the periodic time observer (which refines `duration` from the
        // loaded item) only fires once playback actually starts.
        duration = track.duration
        lastListenPos = max(0, position)
        lastPersistPos = max(0, position)

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        player = AVPlayer(playerItem: item)
        player?.volume = volume

        addTimeObserver()
        observeItemEnd()

        // Park at the saved offset, paused. AVPlayer buffers the seek until the item is ready.
        if position > 0 { seekPlayerItem(to: position) }
        state = .paused

        Task { @MainActor [weak self] in
            guard let self, let t = self.currentTrack else { return }
            self.nowPlaying.update(track: t, isPlaying: false)
        }
    }

    func togglePlayPause() {
        guard state.isActive else { return }
        cancelCrossfade()
        if state.isPlaying {
            player?.pause()
            state = .paused
            flushListen()
            onPersist?()
        } else {
            try? session.activate()
            player?.play()
            state = .playing
        }
        // Defer the Now Playing update to the next main-actor turn: the `state` flip
        // above is what the UI observes, so letting it redraw FIRST makes the button
        // feel instant. Updating MPNowPlayingInfoCenter inline here stalled that frame.
        let isPlaying = state.isPlaying
        let elapsed = currentTime
        let nowPlaying = self.nowPlaying
        Task { @MainActor in nowPlaying.updatePlaybackState(isPlaying: isPlaying, elapsed: elapsed) }
    }

    func pause() {
        guard state.isPlaying else { return }
        cancelCrossfade()
        player?.pause()
        state = .paused
        flushListen()
        onPersist?()
        let elapsed = currentTime
        Task { @MainActor [weak self] in self?.nowPlaying.updatePlaybackState(isPlaying: false, elapsed: elapsed) }
    }

    func resume() {
        guard state == .paused else { return }
        try? session.activate()
        player?.play()
        state = .playing
        let elapsed = currentTime
        Task { @MainActor [weak self] in self?.nowPlaying.updatePlaybackState(isPlaying: true, elapsed: elapsed) }
    }

    func stop() {
        flushListen()
        teardown()
        stopAccessingCurrentResource()
        currentTrack = nil
        state = .stopped
        currentTime = 0
        duration = 0
        nowPlaying.clear()
        onPersist?()
    }

    func seek(to time: TimeInterval) {
        cancelCrossfade()
        let target = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        lastListenPos = time   // don't count the jump as listened time
        let playing = state.isPlaying
        Task { @MainActor [weak self] in self?.nowPlaying.updatePlaybackState(isPlaying: playing, elapsed: time) }
    }

    /// Raw player seek with no side effects — used while preparing a restored, paused
    /// session. A standalone sync method so the synchronous `seek` overload is selected
    /// (inside the `async` prepare(), the bare call would resolve to the awaited overload).
    private func seekPlayerItem(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skipForward(_ seconds: TimeInterval = 15) {
        seek(to: min(currentTime + seconds, duration))
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        seek(to: max(currentTime - seconds, 0))
    }

    // MARK: - Private

    private func resolveURL(for track: Track) -> URL? {
        try? track.resolveURL()
    }

    /// Local copies live in our own container (no security scope needed), so verify the
    /// file is actually present — a deleted copy would otherwise stall in a fake `.playing`.
    private func isPlayable(_ url: URL, localCopy: Bool) -> Bool {
        guard localCopy else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Skip an unplayable track, bounded by `skipFailures` so a fully-missing queue stops
    /// instead of looping forever.
    private func handleUnplayable() async {
        let count = queue?.items.count ?? 0
        skipFailures += 1
        guard skipFailures < max(count, 1), let q = queue else {
            skipFailures = 0
            stop()
            return
        }
        await q.advancePastUnplayable()
    }

    private func stopAccessingCurrentResource() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let item = self.playerItem {
                let dur = item.duration.seconds
                // Only assign on change — @Observable fires a mutation on every set, and
                // this ran 4×/sec for the whole track, waking the scrubbers needlessly.
                if dur.isFinite && dur > 0 && dur != self.duration { self.duration = dur }
            }
            self.accumulateListen(at: time.seconds)
            self.maybePersistProgress(at: time.seconds)
            self.maybeStartCrossfade()
        }
    }

    // MARK: - Listening Time

    /// Accumulates real playback progress between observer ticks while playing. Seeks
    /// and pauses are excluded (jumps are clamped, and ticks stop when paused), so this
    /// reflects time actually heard. Flushed to storage in ~5-second batches.
    private func accumulateListen(at pos: TimeInterval) {
        defer { lastListenPos = pos }
        guard state == .playing else { return }
        let delta = pos - lastListenPos
        guard delta > 0, delta < 2 else { return }   // ignore seeks / discontinuities
        pendingListen += delta
        // Flush at most once a minute (was every 5s): each flush saves the context, which
        // refreshes the library @Query and re-rendered the "recently added" carousel mid-
        // playback. Pause / stop / track-change still flush, so stats stay accurate.
        if pendingListen >= 60 { flushListen() }
    }

    /// Saves the session at most every ~5 seconds while playing, so an unexpected
    /// termination (or a background-kill mid-playback) restores close to the real position.
    private func maybePersistProgress(at pos: TimeInterval) {
        guard state == .playing else { return }
        if abs(pos - lastPersistPos) >= 5 {
            lastPersistPos = pos
            onPersist?()
        }
    }

    /// Persist the buffered listened-seconds onto the current track.
    private func flushListen() {
        guard pendingListen > 0, let track = currentTrack else { pendingListen = 0; return }
        let seconds = pendingListen
        pendingListen = 0
        onListened?(track, seconds)
    }

    // MARK: - Crossfade

    /// Triggered from the time observer: once the current track is within the
    /// crossfade window of its end, start overlapping the next track.
    private func maybeStartCrossfade() {
        let xfade = crossfadeDuration
        guard xfade > 0, !isCrossfading, state == .playing, duration > 0,
              currentTime >= duration - xfade,
              let next = crossfadeNextTrack(),
              let url = resolveURL(for: next) else { return }
        startCrossfade(to: next, url: url, over: xfade)
    }

    /// The track `advance()` would move to — nil when there's nothing to fade into
    /// (queue end with repeat off, or repeat-one where a crossfade makes no sense).
    private func crossfadeNextTrack() -> Track? {
        guard let q = queue else { return nil }
        switch q.repeatMode {
        case .one: return nil
        case .all:
            guard !q.items.isEmpty else { return nil }
            return q.items[(q.currentIndex + 1) % q.items.count]
        case .off:
            let n = q.currentIndex + 1
            return q.items.indices.contains(n) ? q.items[n] : nil
        }
    }

    private func startCrossfade(to track: Track, url: URL, over xfade: TimeInterval) {
        isCrossfading = true

        // Detach the current (outgoing) player so its natural end doesn't advance,
        // and keep it playing while it fades out.
        if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        fadeOutPlayer = player

        // Attribute the outgoing track's buffered listening before switching.
        flushListen()

        // Bring up the incoming track on a new primary player, silent at first.
        let item = AVPlayerItem(url: url)
        let incoming = AVPlayer(playerItem: item)
        incoming.volume = 0
        player = incoming
        playerItem = item
        currentTrack = track
        onTrackChanged?(track)
        duration = 0
        currentTime = 0
        lastListenPos = 0
        addTimeObserver()
        observeItemEnd()
        incoming.play()
        queue?.advanceIndexForCrossfade()
        nowPlaying.update(track: track, isPlaying: true)

        // Linear volume ramp over the crossfade duration.
        let start = Date()
        let target = volume
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(start) / xfade)
            self.fadeOutPlayer?.volume = Float(1 - p) * target
            self.player?.volume = Float(p) * target
            if p >= 1 {
                timer.invalidate()
                self.finishCrossfade()
            }
        }
    }

    private func finishCrossfade() {
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeOutPlayer?.pause()
        fadeOutPlayer = nil
        player?.volume = volume
        isCrossfading = false
    }

    /// Abandon any in-progress crossfade — the incoming player becomes the sole
    /// player at full volume. Called on pause / seek / track change.
    private func cancelCrossfade() {
        guard isCrossfading else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeOutPlayer?.pause(); fadeOutPlayer = nil
        player?.volume = volume
        isCrossfading = false
    }

    private func observeItemEnd() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }

    @objc private func itemDidFinish() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let track = self.currentTrack {
                self.onTrackComplete?(track)
            }
            if let q = self.queue {
                await q.advance()
            } else {
                self.stop()
            }
        }
    }

    private func teardown() {
        cancelCrossfade()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        player?.pause()
        player = nil
        playerItem = nil
    }

    // MARK: - System Notifications

    private func setupSystemNotifications() {
        #if os(iOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
        #endif
    }

    // These fire on AVAudioSession's own (background) notify thread, so they must NOT
    // touch @Observable state / SwiftData directly — parse here, then hop to the main actor.
    #if os(iOS) || os(visionOS)
    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        let shouldResume: Bool = {
            guard type == .ended,
                  let optVal = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            else { return false }
            return AVAudioSession.InterruptionOptions(rawValue: optVal).contains(.shouldResume)
        }()
        Task { @MainActor in
            switch type {
            case .began: self.pause()
            case .ended: if shouldResume { self.resume() }
            @unknown default: break
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ note: Notification) {
        guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
        // Headphones unplugged → pause (standard Apple behavior).
        if reason == .oldDeviceUnavailable {
            Task { @MainActor in self.pause() }
        }
    }
    #endif
}
