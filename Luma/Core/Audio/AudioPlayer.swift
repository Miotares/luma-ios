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

    private(set) var currentTrack: Track? {
        didSet { currentTrackID = currentTrack?.id }
    }
    /// Stable id of the current track, captured when it is set so it stays readable even
    /// after the Track is deleted from the store (used to tear down playback on delete).
    private(set) var currentTrackID: UUID?
    private(set) var state: PlaybackState = .stopped
    /// Coarse "is there an active session" flag (playing OR paused), flipped ONLY on the
    /// stopped↔active boundary. Views use THIS (not `state.isActive`) for the mini-player /
    /// scroll-clearance: reading `state` makes a view re-evaluate on every play↔pause (state
    /// changes but isActive doesn't), which re-ran every mounted tab body. `isActive` only
    /// changes when it truly changes, so play/pause no longer churns the whole UI.
    private(set) var isActive: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// True play head in seconds, accurate even while backgrounded — unlike the observable
    /// `currentTime`, which is intentionally frozen in the background for perf (no visible
    /// scrubber there). Use THIS for position-dependent LOGIC (e.g. the lock-screen "previous"
    /// restart-vs-skip decision, which fires while backgrounded), never the observable scrubber.
    var playheadSeconds: TimeInterval { parkedTime }
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
    /// Fired ONCE per track session when the user has actually listened to the track (a listen
    /// threshold is crossed, or it finished) — drives play count + recently/most-played, so a
    /// sampled/skipped track doesn't count but a real listen does even without finishing.
    var onTrackPlayed: ((Track) -> Void)?
    var onTrackChanged: ((Track) -> Void)?
    /// Called in ~minute batches with the seconds actually listened of a track, so stats can
    /// count partial (skipped) plays — not just tracks played to the end.
    var onListened: ((Track, TimeInterval) -> Void)?
    /// Fired when the session state worth persisting changed — on pause/stop and on a ~5s
    /// throttle while playing — so the queue + play head can be saved for resume.
    var onPersist: (() -> Void)?
    /// Fired at coalescing boundaries (pause/stop) so accumulated playback stats can be saved.
    /// recordPlay/addListenTime only mutate in memory (autosave is off on the main context);
    /// this is the cue to actually persist them — NOT on every tick, which would storm @Query.
    var onStatsShouldPersist: (() -> Void)?

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
    /// Wall-clock anchor: (when audio last (re)started rendering, at what track position). Set at
    /// EVERY authoritative playback (re)start while playing (play/resume/seek/gapless/crossfade/
    /// route change) via `anchorPlayhead`, cleared by the `state == .playing` gate on use. Used
    /// ONLY by `enterForeground()` to recompute the EXACT head: the render clock is momentarily
    /// unreadable on wake and the display timer is coalesced (so `parkedTime` is stale) in the
    /// background — but wall time advances 1:1 with audio at normal rate, so `position + elapsed`
    /// is the true head. Refreshed at each (re)start, so it always describes the CURRENT track.
    private var wallClockAnchor: (date: Date, position: TimeInterval)?
    private var scheduleGeneration = 0                // stale-completion guard
    private var displayTimer: Timer?
    /// Whether the app is in the foreground. While backgrounded, the display tick still runs
    /// (it drives gapless preload / crossfade timing + listen accumulation) but does NOT publish
    /// the observable `currentTime` — there is no visible scrubber, so the per-tick SwiftUI
    /// invalidation is pure wasted main-thread work that contributes to background stutter.
    private var isForeground = true

    // Gapless preload of the next track (scheduled back-to-back on the active node).
    private var preloadStarted = false
    private var preloadedNext: (track: Track, decoded: DecodedTrack)?

    private var accessedURL: URL?

    // Listening accumulation (drives listening-time statistics).
    private var lastListenPos: TimeInterval = 0
    private var pendingListen: TimeInterval = 0
    private var lastPersistPos: TimeInterval = 0
    // Play-count gating: count a "play" once per track session, after enough real listening.
    private var sessionListened: TimeInterval = 0
    private var playRecorded = false
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
        sessionListened = 0
        playRecorded = false

        schedule(decoded, track: track, on: node, from: clamped, generation: generation)
        isActive = true   // stopped→active boundary (covers both autostart and restore-paused)

        if autostart {
            try? engineGraph.start()
            node.play()
            anchorPlayhead(at: clamped)
            state = .playing
            startDisplayTimer()
            nowPlayingUpdate()
        } else {
            clock.invalidate()
            state = .paused
            nowPlayingUpdate()
        }
    }

    /// Returns whether it actually toggled — false if there's no active session. The remote-command
    /// layer maps that to .commandFailed so iOS doesn't latch a wrong play/pause state.
    @discardableResult
    func togglePlayPause() -> Bool {
        guard state.isActive else { return false }
        return state.isPlaying ? pause() : resume()
    }

    /// Returns whether it actually paused (false if not currently playing). The no-op case matters:
    /// when iOS mis-routes a "play" headset press to the pause command while we're already paused,
    /// returning false → .commandFailed lets iOS re-sync and send the play command on the next press.
    @discardableResult
    func pause() -> Bool {
        guard state.isPlaying else { return false }
        cancelCrossfade()
        activeNode.pause()
        // Idle the WHOLE render pipeline, not just the node, so the engine stops feeding the output.
        // Leaving the engine running while "paused" kept the app actively rendering silence — which
        // both wastes power and muddies the paused state that the system (now-playing / headset
        // routing) and our own resume() cold-restart depend on. resume() restarts it. Symmetric.
        engineGraph.pause()
        state = .paused
        parkedTime = currentTime
        stopDisplayTimer()
        flushListen()
        onStatsShouldPersist?()   // persist coalesced play/listen stats on pause
        onPersist?()
        nowPlayingUpdate()
        return true
    }

    /// Returns whether it actually resumed (false if not paused, or the audio session couldn't be
    /// activated). Mapped to .commandFailed at the remote-command layer so a failed resume doesn't
    /// look successful to iOS.
    @discardableResult
    func resume() -> Bool {
        guard state == .paused, currentTrack != nil else { return false }
        do { try session.activate() } catch { return false }
        // RE-SCHEDULE + COLD-RESTART the engine on resume rather than relying on a bare `node.play()`
        // to wake the paused node. A paused AVAudioPlayerNode/engine will NOT resume audibly after
        // the output route went idle (Bluetooth/AirPods: pause → route sleeps → play does nothing) —
        // that was the "tap to pause works, tap to play is dead, but skip works" report. The engine
        // must be FULLY restarted (engineGraph.resume() does stop→prepare→start) so the HAL output
        // unit is re-instantiated and the slept route re-acquired; a *paused* engine still reports
        // isRunning == true, so a bare engine.start() would silently no-op and leave it dead. The
        // node's buffers are scheduled AFTER that restart (a stop can drop already-scheduled ones).
        // Skip works precisely because it rebuilds from a clean node state; resume now re-acquires
        // the route the same way, from the parked position, while keeping the listen / play-count
        // session intact (unlike startPlayback).
        if let decoded = currentDecoded, let track = currentTrack {
            let resumeAt = parkedTime
            let node = activeNode
            node.stop()
            scheduleGeneration += 1
            clearPreload()
            engineGraph.connect(player: node, format: decoded.processingFormat)
            node.volume = volume
            clock.invalidate()
            do { try engineGraph.resume() } catch { try? engineGraph.start() }
            schedule(decoded, track: track, on: node, from: resumeAt, generation: scheduleGeneration)
            node.play()
            anchorPlayhead(at: resumeAt)
            lastListenPos = resumeAt
        } else {
            // No decoded track to reschedule (shouldn't happen while paused) — best-effort wake.
            do { try engineGraph.resume() } catch { try? engineGraph.start() }
            activeNode.play()
            anchorPlayhead(at: parkedTime)
        }
        state = .playing
        startDisplayTimer()
        nowPlayingUpdate()
        return true
    }

    /// Called when the app leaves the foreground. While playing, it's normal background audio —
    /// keep the session live and just push a fresh now-playing snapshot. While paused we KEEP the
    /// session active too (only pausing the engine to save power), so we stay the system's "Now
    /// Playing" app and remain resumable from the lock screen / Control Center / AirPods.
    func enterBackground() {
        #if os(iOS) || os(visionOS)
        // Stop publishing the (invisible) scrubber while backgrounded — set BEFORE the branch so
        // it also applies while playing (the main case). Not touched on macOS, where an unfocused
        // window stays visible and must keep its scrubber.
        isForeground = false
        if state == .playing {
            // We only push now-playing on discrete events (play/pause/seek/track-change), never on
            // the display tick — so by the time the screen locks, the last snapshot can be many
            // seconds/minutes stale. iOS then snapshots THAT on lock and intermittently drew the
            // play/pause button as PAUSED even though audio kept playing. Push a fresh, accurate
            // snapshot (live elapsed + rate = 1) right now so the lock screen reads the truth.
            syncPlayheadFromClock()
            nowPlayingUpdate()
            return
        }
        // Paused: do NOT deactivate the session. We used to call session.deactivate() here to fix a
        // cosmetic "lock screen shows playing while paused" glitch — but deactivating (with
        // .notifyOthersOnDeactivation) hands the Now-Playing role to the system and lets iOS suspend
        // us, so the PLAY remote command never reached the app and resume() never ran. That was the
        // "pause works, skip works, but play-after-pause is dead over AirPods/lock screen" bug.
        // Keep the session active so we stay resumable; pause only the engine to save power
        // (resume() restarts it), and push a fresh paused snapshot (rate 0 / playbackState .paused)
        // so the lock-screen play/pause button still shows the correct state.
        engineGraph.pause()
        nowPlayingUpdate()
        #endif
    }

    /// Returning to the foreground — re-publish the EXACT play head and refresh now-playing.
    func enterForeground() {
        isForeground = true
        // Recompute the head from WALL-CLOCK elapsed time, NOT the render clock or `parkedTime`.
        // On wake the node's render time is briefly unreadable (so `clock.seconds()` falls back to
        // the frozen `parkedTime`) AND the 0.2s display timer was coalesced in the background (so
        // `parkedTime` itself is stale) — that's why the scrubber showed e.g. 30s and only snapped
        // to 40s a tick later. Wall time advances 1:1 with audio at normal rate, and the anchor is
        // refreshed at every (re)start so it's always the current track, so `position + elapsed` is
        // the true head the instant we return; the sample clock takes back over on the next tick.
        if state == .playing, let anchor = wallClockAnchor {
            let projected = anchor.position + max(0, Date().timeIntervalSince(anchor.date))
            let bounded = trackDuration > 0 ? min(projected, trackDuration) : projected
            // Credit the seconds that genuinely played while the coalesced timer wasn't accumulating
            // — only the still-uncounted portion (`bounded - lastListenPos`), so any ticks that DID
            // fire aren't double-counted — then realign the listen cursor so the next tick's delta
            // stays under accumulateListen's 2s discard guard instead of being thrown away.
            let played = bounded - lastListenPos
            if played > 0 { pendingListen += played; sessionListened += played }
            lastListenPos = bounded
            parkedTime = bounded
            currentTime = bounded
        } else {
            // Paused / no anchor: parkedTime is already the correct frozen position.
            syncPlayheadFromClock()
        }
        nowPlayingUpdate()
    }

    /// Snap the published play head (`currentTime` + `parkedTime`) to the live render-clock
    /// position. Used at the fg/bg boundaries, where the per-tick publish was skipped/coalesced,
    /// so the scrubber and now-playing info are exact immediately. No-op unless playing (paused
    /// keeps its parked position, which is already correct).
    private func syncPlayheadFromClock() {
        guard state == .playing else { return }
        let t = clock.seconds(on: activeNode, parked: parkedTime)
        let bounded = trackDuration > 0 ? min(t, trackDuration) : t
        parkedTime = bounded
        currentTime = bounded
    }

    /// Anchor BOTH the sample clock (applied on the next render tick) and the wall-clock head at
    /// `seconds`. Call wherever playback (re)starts from a known position while playing — every
    /// site that used to set `pendingAnchorSeconds` directly — so the foreground-resync projection
    /// always has a fresh, current-track anchor to extrapolate from.
    private func anchorPlayhead(at seconds: TimeInterval) {
        pendingAnchorSeconds = seconds
        wallClockAnchor = (Date(), max(0, seconds))
    }

    /// Flush any in-memory listened-seconds delta into the current track's stats (no save).
    /// Used at a lifecycle boundary (backgrounding) so partial listening persists; the actual
    /// context save is driven separately via `onStatsShouldPersist` / AppContainer.saveStats().
    func flushPendingListen() { flushListen() }

    func stop() {
        flushListen()
        onStatsShouldPersist?()   // persist coalesced play/listen stats on stop
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
        isActive = false   // active→stopped boundary (the only place state becomes .stopped)
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
            anchorPlayhead(at: target)
        }
        nowPlayingUpdate()
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
        // A finished track counts as played (covers tracks shorter than the listen threshold).
        if !playRecorded { playRecorded = true; onTrackPlayed?(finished) }

        if sleepMode == .endOfTrack {
            cancelSleepTimer()
            stopDisplayTimer()
            activeNode.stop()
            state = .paused
            parkedTime = 0
            currentTime = 0
            clock.invalidate()
            onPersist?()
            nowPlayingUpdate()
            return
        }

        guard let q = queue else { stop(); return }

        if q.repeatMode == .one {
            Task { await startPlayback(track: finished, from: 0, autostart: true) }
            return
        }

        if let next = preloadedNext {
            // Gapless: `next` is already playing back-to-back on the active node.
            // Flush the finished track's listened seconds BEFORE reassigning currentTrack, or
            // the pending delta would be lost (and mis-attributed to the next track). This is
            // the only track-advance path that doesn't route through startPlayback's flush.
            flushListen()
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
            sessionListened = 0
            playRecorded = false
            anchorPlayhead(at: 0)
            nowPlayingUpdate()
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
        // Only publish the observable play head while foregrounded — the scrubber isn't visible
        // in the background, so skipping the write avoids 5×/sec SwiftUI invalidations there.
        // `parkedTime` is always updated so enterForeground() / resume can show the right time.
        if isForeground { currentTime = bounded }
        parkedTime = bounded
        accumulateListen(at: bounded)
        maybePersistProgress(at: bounded)
        // Pass the freshly-measured play head — NOT the observable `currentTime`, which is frozen
        // while backgrounded (it's only published `if isForeground`). Reading `currentTime` here
        // meant crossfade + gapless preload never triggered on the lock screen / in the background.
        maybeStartCrossfade(at: bounded)
        maybePreloadGapless(at: bounded)
    }

    // MARK: - Gapless preload

    private func maybePreloadGapless(at pos: TimeInterval) {
        guard state == .playing, !isCrossfading, !preloadStarted,
              crossfadeDuration == 0, trackDuration > 0,
              pos >= trackDuration - 8,
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

    private func maybeStartCrossfade(at pos: TimeInterval) {
        let xfade = crossfadeDuration
        let sleepSuppressesCrossfade = sleepMode == .endOfTrack
            || (sleepMode == .duration && sleepRemaining <= sleepFadeDuration)
        guard xfade > 0, !isCrossfading, state == .playing, trackDuration > 0,
              !sleepSuppressesCrossfade,
              pos >= trackDuration - xfade,
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

        // The outgoing track is near its end; record its play if the threshold wasn't hit yet.
        if !playRecorded, let outgoing = currentTrack { playRecorded = true; onTrackPlayed?(outgoing) }
        currentTrack = track
        currentDecoded = decoded
        onTrackChanged?(track)
        trackDuration = trackLength(decoded, fallback: track.duration)
        duration = trackDuration
        currentTime = 0
        parkedTime = 0
        lastListenPos = 0
        sessionListened = 0
        playRecorded = false
        anchorPlayhead(at: 0)
        queue?.advanceIndexForCrossfade()
        nowPlayingUpdate()

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

    /// Pushes the CURRENT player state to the lock screen / Control Center. The MediaPlayer
    /// IPC must run on the main actor; reading the live state at apply time (not a value frozen
    /// at call time) means out-of-order delivery of these async hops can't leave a stale rate —
    /// which is what got the lock-screen play/pause button stuck out of sync.
    private func nowPlayingUpdate() {
        Task { @MainActor [weak self] in self?.pushNowPlaying() }
    }

    @MainActor
    private func pushNowPlaying() {
        guard let track = currentTrack else { nowPlaying.clear(); return }
        nowPlaying.update(track: track, isPlaying: state.isPlaying, elapsed: currentTime)
    }

    private func handleConfigurationChange() {
        // The engine was reconfigured (route/HW change); reschedule from the current frame.
        guard let decoded = currentDecoded, let track = currentTrack, state != .stopped else { return }
        // Read the LIVE head from the render clock (node still rendering here, before node.stop()),
        // NOT the observable `currentTime` — that's frozen in the background, so a route change
        // there (e.g. AirPods (dis)connect on the lock screen) would reschedule from a stale frame.
        let resumeAt = clock.seconds(on: activeNode, parked: parkedTime)
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
            anchorPlayhead(at: resumeAt)
        }
    }

    // MARK: - Listening Time

    private func accumulateListen(at pos: TimeInterval) {
        defer { lastListenPos = pos }
        guard state == .playing else { return }
        let delta = pos - lastListenPos
        guard delta > 0, delta < 2 else { return }   // ignore seeks / discontinuities
        pendingListen += delta
        sessionListened += delta
        // Count a play once the user has genuinely listened (not just sampled the track).
        if !playRecorded, sessionListened >= playCountThreshold(for: trackDuration),
           let track = currentTrack {
            playRecorded = true
            onTrackPlayed?(track)
        }
        // No rolling mid-playback flush: pendingListen accumulates in memory and is flushed at
        // a boundary (track change / pause / stop / background). The old 60s flush mutated the
        // Track and (with autosave) republished every live @Query mid-playback — a periodic
        // hitch while scrolling and wasted CPU during background playback.
    }

    /// Seconds of real listening before a track counts as "played": 30% of its length, so a
    /// song lands in recently/most-played once it's a third of the way through (30s when the
    /// length is unknown).
    private func playCountThreshold(for duration: TimeInterval) -> TimeInterval {
        duration > 0 ? duration * 0.3 : 30
    }

    private func maybePersistProgress(at pos: TimeInterval) {
        guard state == .playing else { return }
        // 20s (was 5s): onPersist snapshots the whole queue (maps every item id) on the main
        // thread, and a shuffle-all of a large library is a few-thousand-element map each time.
        // Resume granularity doesn't need 5s, and pause/stop/track-change still persist exactly.
        if abs(pos - lastPersistPos) >= 20 {
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
