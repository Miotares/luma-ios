import AVFAudio
import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// Playback engine, rebuilt on AVAudioEngine (was AVPlayer) to enable TRUE gapless playback
/// and an equalizer. The PUBLIC contract is unchanged — same @Observable state, methods,
/// callbacks and UserDefaults keys — so AppContainer, the queue, system integration and the
/// UI are untouched. Internally: two AVAudioPlayerNodes (A/B) feed `LumaAudioGraph`
/// (mixer → EQ → output). Node A plays the current track; the next track is scheduled
/// back-to-back on the SAME node for gapless (crossfade off), or on node B with a volume
/// ramp for crossfade. A display timer drives `currentTime`, listening stats, persistence
/// and the gapless/crossfade triggers (replacing AVPlayer's periodic time observer).
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
            if !isCrossfading { activeNode.volume = volume }
            UserDefaults.standard.set(Double(volume), forKey: AudioPlayer.volumeDefaultsKey)
        }
    }

    enum PlaybackState: Equatable {
        case stopped, playing, paused, buffering
        var isActive: Bool { self != .stopped }
        var isPlaying: Bool { self == .playing }
    }

    // MARK: - Internal wiring

    weak var queue: PlaybackQueue?
    var onTrackComplete: ((Track) -> Void)?
    var onTrackChanged: ((Track) -> Void)?
    /// Called in ~minute batches with the seconds actually listened of a track, so stats can
    /// count partial (skipped) plays — not just tracks played to the end.
    var onListened: ((Track, TimeInterval) -> Void)?
    /// Fired when the session state worth persisting changed — on pause/stop and on a ~5s
    /// throttle while playing — so the queue + play head can be saved for resume.
    var onPersist: (() -> Void)?

    /// Exposed so the equalizer can attach to the live AVAudioUnitEQ.
    var graph: LumaAudioGraph { engineGraph }

    // MARK: - Sleep Timer (observed by UI)

    enum SleepTimerMode: Equatable { case off, duration, endOfTrack }
    private(set) var sleepMode: SleepTimerMode = .off
    private(set) var sleepRemaining: TimeInterval = 0
    var isSleepTimerActive: Bool { sleepMode != .off }

    // MARK: - Engine internals

    private let engineGraph = LumaAudioGraph()
    private let clock = PlayheadClock()
    private var useNodeB = false
    private var activeNode: AVAudioPlayerNode { useNodeB ? engineGraph.playerB : engineGraph.playerA }

    private var currentDecoded: DecodedTrack?
    private var trackDuration: TimeInterval = 0
    private var parkedTime: TimeInterval = 0          // play head while paused / not yet anchored
    private var pendingAnchorSeconds: TimeInterval?   // re-anchor the clock once the node renders
    private var scheduleGeneration = 0                // stale-completion guard
    private var displayTimer: Timer?

    // Gapless preload of the next track (scheduled back-to-back on the active node).
    private var preloadStarted = false
    private var preloadedNext: (track: Track, decoded: DecodedTrack)?

    private var accessedURL: URL?

    // Listening accumulation (drives listening-time statistics).
    private var lastListenPos: TimeInterval = 0
    private var pendingListen: TimeInterval = 0
    private var lastPersistPos: TimeInterval = 0
    // Bounds the skip-on-unplayable loop so an all-missing queue stops instead of looping.
    private var skipFailures = 0

    // Sleep timer internals: wall-clock deadline (survives timer coalescing/backgrounding).
    private var sleepDeadline: Date?
    private var sleepTimer: Timer?
    private let sleepFadeDuration: TimeInterval = 8

    // Crossfade: the outgoing node overlaps the incoming one while volumes ramp.
    static let crossfadeDefaultsKey = "crossfadeDuration"
    private var fadeTimer: Timer?
    private var isCrossfading = false
    private var crossfadeOutgoing: AVAudioPlayerNode?
    private var crossfadeDuration: TimeInterval {
        max(0, UserDefaults.standard.double(forKey: Self.crossfadeDefaultsKey))
    }

    private let session = AudioSessionManager.shared
    private let nowPlaying = NowPlayingManager.shared

    init() {
        engineGraph.onConfigurationChange = { [weak self] in self?.handleConfigurationChange() }
        setupSystemNotifications()
    }

    deinit {
        displayTimer?.invalidate()
        fadeTimer?.invalidate()
        sleepTimer?.invalidate()
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Playback Control

    func play(track: Track) async {
        await startPlayback(track: track, from: 0, autostart: true)
    }

    /// Loads a track WITHOUT starting playback, parked at `position` — used to restore the
    /// previous session. Ends in `.paused`; the audio engine/session is NOT started here
    /// (that happens on resume) so relaunching never interrupts other apps' audio.
    func prepare(track: Track, at position: TimeInterval) async {
        await startPlayback(track: track, from: position, autostart: false)
    }

    /// Core entry: decode, wire the active node at the track's format, schedule from `offset`,
    /// and (when `autostart`) start the engine + node. Otherwise park paused for restore.
    private func startPlayback(track: Track, from offset: TimeInterval, autostart: Bool) async {
        flushListen()
        guard let url = resolveURL(for: track), isPlayable(url, localCopy: track.hasLocalCopy),
              let decoded = await TrackDecoder.open(url: url) else {
            await handleUnplayable()
            return
        }
        skipFailures = 0
        if autostart { do { try session.activate() } catch { return } }

        stopAccessingCurrentResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url

        cancelCrossfade()
        resetNodes()
        scheduleGeneration += 1
        let generation = scheduleGeneration

        let node = activeNode
        engineGraph.connect(player: node, format: decoded.processingFormat)
        node.volume = volume

        currentTrack = track
        currentDecoded = decoded
        onTrackChanged?(track)
        trackDuration = trackLength(decoded, fallback: track.duration)
        duration = trackDuration
        let clamped = max(0, offset)
        currentTime = clamped
        parkedTime = clamped
        lastListenPos = clamped
        lastPersistPos = clamped

        schedule(decoded, track: track, on: node, from: clamped, generation: generation)

        if autostart {
            try? engineGraph.start()
            node.play()
            pendingAnchorSeconds = clamped
            state = .playing
            startDisplayTimer()
            nowPlayingUpdate(isPlaying: true)
        } else {
            clock.invalidate()
            state = .paused
            nowPlayingUpdate(isPlaying: false)
        }
    }

    func togglePlayPause() {
        guard state.isActive else { return }
        if state.isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard state.isPlaying else { return }
        cancelCrossfade()
        activeNode.pause()
        state = .paused
        parkedTime = currentTime
        stopDisplayTimer()
        flushListen()
        onPersist?()
        nowPlayingUpdate(isPlaying: false)
    }

    func resume() {
        guard state == .paused, currentTrack != nil else { return }
        try? session.activate()
        try? engineGraph.start()
        activeNode.play()
        if !clock.isAnchored { pendingAnchorSeconds = parkedTime }
        state = .playing
        startDisplayTimer()
        nowPlayingUpdate(isPlaying: true)
    }

    func stop() {
        flushListen()
        cancelSleepTimer()
        cancelCrossfade()
        stopDisplayTimer()
        scheduleGeneration += 1
        resetNodes()
        engineGraph.stop()
        clock.invalidate()
        currentDecoded = nil
        stopAccessingCurrentResource()
        currentTrack = nil
        state = .stopped
        currentTime = 0
        duration = 0
        parkedTime = 0
        nowPlaying.clear()
        onPersist?()
    }

    func seek(to time: TimeInterval) {
        guard let decoded = currentDecoded, let track = currentTrack else { return }
        cancelCrossfade()
        let target = max(0, min(time, trackDuration > 0 ? trackDuration : time))
        let node = activeNode
        node.stop()
        scheduleGeneration += 1
        clearPreload()
        schedule(decoded, track: track, on: node, from: target, generation: scheduleGeneration)
        currentTime = target
        parkedTime = target
        lastListenPos = target
        clock.invalidate()
        if state == .playing {
            try? engineGraph.start()
            node.play()
            pendingAnchorSeconds = target
        }
        nowPlayingUpdate(isPlaying: state.isPlaying)
    }

    func skipForward(_ seconds: TimeInterval = 15) {
        seek(to: min(currentTime + seconds, duration))
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        seek(to: max(currentTime - seconds, 0))
    }

    // MARK: - Scheduling

    private func resetNodes() {
        engineGraph.playerA.stop()
        engineGraph.playerB.stop()
        clearPreload()
    }

    private func clearPreload() {
        preloadStarted = false
        preloadedNext = nil
    }

    /// Schedule `decoded` on `node` from `offset` seconds, firing the track-boundary handler
    /// (tagged with `generation`) when the data has finished playing.
    private func schedule(_ decoded: DecodedTrack, track: Track, on node: AVAudioPlayerNode,
                          from offset: TimeInterval, generation: Int) {
        let rate = decoded.processingFormat.sampleRate
        let onDone: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
            Task { @MainActor in self?.handleBoundary(finished: track, generation: generation) }
        }
        switch decoded {
        case .file(let file):
            let total = file.length
            let startFrame = AVAudioFramePosition(max(0, offset) * rate)
            if startFrame <= 0 || startFrame >= total {
                node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: onDone)
            } else {
                let frames = AVAudioFrameCount(total - startFrame)
                node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                                     completionCallbackType: .dataPlayedBack, completionHandler: onDone)
            }
        case .buffers(let buffers, _, _):
            // Seek lands on the buffer containing `offset` (sub-buffer precision is dropped).
            let target = AVAudioFramePosition(max(0, offset) * rate)
            var frame: AVAudioFramePosition = 0
            var scheduled: [AVAudioPCMBuffer] = []
            for buf in buffers {
                let len = AVAudioFramePosition(buf.frameLength)
                if frame + len <= target { frame += len; continue }
                scheduled.append(buf)
                frame += len
            }
            if scheduled.isEmpty { scheduled = buffers }
            for (i, buf) in scheduled.enumerated() {
                let isLast = i == scheduled.count - 1
                node.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack,
                                    completionHandler: isLast ? onDone : nil)
            }
        }
    }

    /// Fired when a scheduled track finished playing. By design the NEXT track is already
    /// playing (gapless preload or crossfade incoming), so this mostly does bookkeeping.
    private func handleBoundary(finished: Track, generation: Int) {
        guard generation == scheduleGeneration else { return }   // stale (stop/seek/skip/new play)
        onTrackComplete?(finished)

        if sleepMode == .endOfTrack {
            cancelSleepTimer()
            stopDisplayTimer()
            activeNode.stop()
            state = .paused
            parkedTime = 0
            currentTime = 0
            clock.invalidate()
            onPersist?()
            nowPlayingUpdate(isPlaying: false)
            return
        }

        guard let q = queue else { stop(); return }

        if q.repeatMode == .one {
            Task { await startPlayback(track: finished, from: 0, autostart: true) }
            return
        }

        if let next = preloadedNext {
            // Gapless: `next` is already playing back-to-back on the active node.
            q.advanceIndexForCrossfade()
            currentTrack = next.track
            currentDecoded = next.decoded
            clearPreload()
            onTrackChanged?(next.track)
            trackDuration = trackLength(next.decoded, fallback: next.track.duration)
            duration = trackDuration
            currentTime = 0
            parkedTime = 0
            lastListenPos = 0
            pendingAnchorSeconds = 0
            nowPlayingUpdate(isPlaying: true)
        } else {
            // No gapless follow (queue end, rate change, or not preloaded) → normal advance.
            Task { await q.advance() }
        }
    }

    // MARK: - Display timer (drives currentTime + triggers)

    private func startDisplayTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.displayTick() }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func displayTick() {
        guard state == .playing else { return }
        if let target = pendingAnchorSeconds {
            clock.anchor(seconds: target, on: activeNode)
            if clock.isAnchored { pendingAnchorSeconds = nil }
        }
        let t = clock.seconds(on: activeNode, parked: parkedTime)
        let bounded = trackDuration > 0 ? min(t, trackDuration) : t
        currentTime = bounded
        parkedTime = bounded
        accumulateListen(at: bounded)
        maybePersistProgress(at: bounded)
        maybeStartCrossfade()
        maybePreloadGapless()
    }

    // MARK: - Gapless preload

    private func maybePreloadGapless() {
        guard state == .playing, !isCrossfading, !preloadStarted,
              crossfadeDuration == 0, trackDuration > 0,
              currentTime >= trackDuration - 8,
              sleepMode != .endOfTrack,
              let q = queue, q.repeatMode != .one,
              let next = crossfadeNextTrack() else { return }
        preloadStarted = true
        let generation = scheduleGeneration
        let currentRate = currentDecoded?.processingFormat.sampleRate
        Task { @MainActor in
            guard generation == self.scheduleGeneration,
                  let url = self.resolveURL(for: next),
                  let decoded = await TrackDecoder.open(url: url) else {
                self.preloadStarted = false
                return
            }
            // Gapless on one node needs the same sample rate; otherwise fall back to a gap.
            guard generation == self.scheduleGeneration,
                  decoded.processingFormat.sampleRate == currentRate else {
                self.preloadStarted = false
                return
            }
            self.preloadedNext = (next, decoded)
            self.schedule(decoded, track: next, on: self.activeNode, from: 0, generation: generation)
        }
    }

    // MARK: - Crossfade

    private func maybeStartCrossfade() {
        let xfade = crossfadeDuration
        let sleepSuppressesCrossfade = sleepMode == .endOfTrack
            || (sleepMode == .duration && sleepRemaining <= sleepFadeDuration)
        guard xfade > 0, !isCrossfading, state == .playing, trackDuration > 0,
              !sleepSuppressesCrossfade,
              currentTime >= trackDuration - xfade,
              let next = crossfadeNextTrack() else { return }
        isCrossfading = true
        Task { @MainActor in await self.startCrossfade(to: next, over: xfade) }
    }

    /// The track `advance()` would move to — nil when there's nothing to fade into.
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

    private func startCrossfade(to track: Track, over xfade: TimeInterval) async {
        guard let url = resolveURL(for: track), let decoded = await TrackDecoder.open(url: url) else {
            isCrossfading = false
            return
        }
        flushListen()
        let outgoing = activeNode
        useNodeB.toggle()                 // active node is now the incoming one
        let incoming = activeNode
        crossfadeOutgoing = outgoing

        scheduleGeneration += 1           // outgoing's completion becomes stale; we own the swap
        let generation = scheduleGeneration
        clearPreload()

        incoming.stop()
        engineGraph.connect(player: incoming, format: decoded.processingFormat)
        incoming.volume = 0
        schedule(decoded, track: track, on: incoming, from: 0, generation: generation)
        try? engineGraph.start()
        incoming.play()

        currentTrack = track
        currentDecoded = decoded
        onTrackChanged?(track)
        trackDuration = trackLength(decoded, fallback: track.duration)
        duration = trackDuration
        currentTime = 0
        parkedTime = 0
        lastListenPos = 0
        pendingAnchorSeconds = 0
        queue?.advanceIndexForCrossfade()
        nowPlayingUpdate(isPlaying: true)

        let start = Date()
        let target = volume
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = min(1, Date().timeIntervalSince(start) / xfade)
            self.crossfadeOutgoing?.volume = Float(1 - p) * target
            self.activeNode.volume = Float(p) * target
            if p >= 1 { self.finishCrossfade() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func finishCrossfade() {
        fadeTimer?.invalidate(); fadeTimer = nil
        crossfadeOutgoing?.stop()
        crossfadeOutgoing = nil
        activeNode.volume = volume
        isCrossfading = false
    }

    /// Abandon any in-progress crossfade — the incoming node becomes the sole player.
    private func cancelCrossfade() {
        guard isCrossfading else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        crossfadeOutgoing?.stop(); crossfadeOutgoing = nil
        activeNode.volume = volume
        isCrossfading = false
    }

    // MARK: - Unplayable handling

    private func resolveURL(for track: Track) -> URL? { try? track.resolveURL() }

    private func isPlayable(_ url: URL, localCopy: Bool) -> Bool {
        guard localCopy else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

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

    private func trackLength(_ decoded: DecodedTrack, fallback: TimeInterval) -> TimeInterval {
        let rate = decoded.processingFormat.sampleRate
        guard rate > 0, decoded.lengthFrames > 0 else { return fallback }
        return Double(decoded.lengthFrames) / rate
    }

    private func nowPlayingUpdate(isPlaying: Bool) {
        let track = currentTrack
        let elapsed = currentTime
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let track { self.nowPlaying.update(track: track, isPlaying: isPlaying) }
            self.nowPlaying.updatePlaybackState(isPlaying: isPlaying, elapsed: elapsed)
        }
    }

    private func handleConfigurationChange() {
        // The engine was reconfigured (route/HW change); reschedule from the current frame.
        guard let decoded = currentDecoded, let track = currentTrack, state != .stopped else { return }
        let resumeAt = currentTime
        let wasPlaying = state == .playing
        let node = activeNode
        node.stop()
        scheduleGeneration += 1
        clearPreload()
        engineGraph.connect(player: node, format: decoded.processingFormat)
        node.volume = volume
        schedule(decoded, track: track, on: node, from: resumeAt, generation: scheduleGeneration)
        clock.invalidate()
        if wasPlaying {
            try? engineGraph.start()
            node.play()
            pendingAnchorSeconds = resumeAt
        }
    }

    // MARK: - Listening Time

    private func accumulateListen(at pos: TimeInterval) {
        defer { lastListenPos = pos }
        guard state == .playing else { return }
        let delta = pos - lastListenPos
        guard delta > 0, delta < 2 else { return }   // ignore seeks / discontinuities
        pendingListen += delta
        if pendingListen >= 60 { flushListen() }
    }

    private func maybePersistProgress(at pos: TimeInterval) {
        guard state == .playing else { return }
        if abs(pos - lastPersistPos) >= 5 {
            lastPersistPos = pos
            onPersist?()
        }
    }

    private func flushListen() {
        guard pendingListen > 0, let track = currentTrack else { pendingListen = 0; return }
        let seconds = pendingListen
        pendingListen = 0
        onListened?(track, seconds)
    }

    // MARK: - Sleep Timer

    func startSleepTimer(minutes: Int) {
        restoreSleepVolume()
        sleepMode = .duration
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        sleepDeadline = deadline
        sleepRemaining = deadline.timeIntervalSinceNow
        sleepTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.sleepTick() }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    func startSleepTimerEndOfTrack() {
        restoreSleepVolume()
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepDeadline = nil
        sleepRemaining = 0
        sleepMode = .endOfTrack
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate(); sleepTimer = nil
        sleepDeadline = nil
        sleepRemaining = 0
        sleepMode = .off
        restoreSleepVolume()
    }

    private func sleepTick() {
        guard sleepMode == .duration, let deadline = sleepDeadline else { return }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        sleepRemaining = remaining
        if remaining <= 0 {
            fireSleep()
        } else if remaining <= sleepFadeDuration, !isCrossfading {
            activeNode.volume = volume * Float(remaining / sleepFadeDuration)
        }
    }

    private func fireSleep() {
        flushListen()
        if state.isPlaying { pause() }
        cancelSleepTimer()   // also restores the faded volume
    }

    private func restoreSleepVolume() {
        if !isCrossfading { activeNode.volume = volume }
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
        if reason == .oldDeviceUnavailable {
            Task { @MainActor in self.pause() }
        }
    }
    #endif
}
