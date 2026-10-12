import AVFAudio
import AVFoundation
import Foundation
import MediaPlayer
import Observation
#if canImport(AppKit)
import AppKit
#endif

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
            if !isCrossfading { activeNode.volume = volume * currentGain }
            UserDefaults.standard.set(Double(volume), forKey: AudioPlayer.volumeDefaultsKey)
        }
    }

    enum PlaybackState: Equatable {
        case stopped, playing, paused
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
    /// Wall-clock instant the current track actually began rendering — stamped in `anchorPlayhead`
    /// (the single chokepoint hit by every authoritative (re)start while playing), cleared on
    /// pause/stop. `handleBoundary` uses it to tell a genuine end-of-track from a SPURIOUS ~0s
    /// completion fired by a route-broken/uninitialized graph, which would otherwise burn the queue.
    private var trackStartedAt: Date?
    private var scheduleGeneration = 0                // stale-completion guard
    private var displayTimer: Timer?
    /// Whether a Luma surface is actually on-screen. While off-screen the display tick still runs
    /// (it drives gapless preload / crossfade timing + listen accumulation) but does NOT publish
    /// the observable `currentTime` — there is no visible scrubber, so the per-tick SwiftUI
    /// invalidation is pure wasted main-thread work that contributes to background stutter.
    /// Driven by scenePhase on iOS and by window occlusion on macOS (see setupSystemNotifications);
    /// exposed read-only so the now-playing waveform can stop animating off-screen.
    private(set) var isForeground = true
    /// macOS occlusion-state observer token (removed in deinit). nil on iOS.
    private var occlusionObserver: NSObjectProtocol?

    // Gapless preload of the next track (scheduled back-to-back on the active node).
    private var preloadStarted = false
    private var preloadedNext: (track: Track, decoded: DecodedTrack)?

    private var accessedURL: URL?

    // Listening accumulation (drives listening-time statistics).
    private var lastListenPos: TimeInterval = 0
    private var pendingListen: TimeInterval = 0
    private var lastPersistPos: TimeInterval = 0
    // Throttles the ~1Hz now-playing (lock screen / Control Center) elapsed resync — see
    // maybeSyncNowPlaying. Rebased to the start position at every authoritative (re)start.
    private var lastNowPlayingSyncPos: TimeInterval = 0
    // Play-count gating: count a "play" once per track session, after enough real listening.
    private var sessionListened: TimeInterval = 0
    private var playRecorded = false
    // Bounds the skip-on-unplayable loop so an all-missing queue stops instead of looping.
    private var skipFailures = 0
    // Guards `scheduleResumeRetry` so only ONE deferred restart is ever in flight — a settling
    // audio route (headset plug / car BT) is retried once, not spun on.
    private var resumeRetryScheduled = false

    // Sleep timer internals: wall-clock deadline (survives timer coalescing/backgrounding).
    private var sleepDeadline: Date?
    private var sleepTimer: Timer?
    private let sleepFadeDuration: TimeInterval = 8

    // Crossfade: the outgoing node overlaps the incoming one while volumes ramp.
    static let crossfadeDefaultsKey = "crossfadeDuration"
    /// The crossfade volume ramp is driven OFF the main run loop. It used to be a `Timer` on
    /// `RunLoop.main` (.common) — but that ramp is the ONLY per-tick *audio* operation, and when the
    /// user opened/reordered the queue DURING a transition the saturated main thread coalesced its
    /// 40 ms ticks into one catch-up firing, so the gain jumped in coarse steps on BOTH overlapping
    /// nodes at once = audible zipper/crackle ("Rauschen/Kratzen"). A dispatch-source timer on a
    /// dedicated queue is immune to main-thread stalls; the handler writes only the (thread-safe)
    /// node volumes off-main and hops to the main actor exactly once, at the end, to finish.
    private var fadeTimerSource: DispatchSourceTimer?
    private let fadeQueue = DispatchQueue(label: "luma.crossfade.ramp", qos: .userInteractive)
    private var isCrossfading = false
    private var crossfadeOutgoing: AVAudioPlayerNode?
    private var crossfadeDuration: TimeInterval {
        max(0, UserDefaults.standard.double(forKey: Self.crossfadeDefaultsKey))
    }

    // Loudness normalization: every track is played at the same perceived level. `LoudnessService`
    // supplies the per-track gain; nil (not wired) means unity, i.e. playback as before.
    weak var loudness: LoudnessService?
    /// Normalization gain (linear, 0…1) the ACTIVE node carries for the current track, on top of
    /// the user `volume`. Any boost comes from the graph's constant make-up gain, so this only
    /// ever attenuates. Every place that sets a node's volume multiplies it in.
    private var currentGain: Float = 1
    /// Glides the active node from one normalization gain to another (a late measurement, a
    /// gapless album transition) — off the main run loop for the same reason as the crossfade ramp.
    private var gainRampSource: DispatchSourceTimer?
    private var gainRampGeneration = 0
    /// Bumped by every start request, so one that was suspended for a loudness estimate can tell
    /// it has been superseded.
    private var playRequestGeneration = 0

    private let session = AudioSessionManager.shared
    private let nowPlaying = NowPlayingManager.shared

    init() {
        engineGraph.onConfigurationChange = { [weak self] in self?.handleConfigurationChange() }
        setupSystemNotifications()
    }

    deinit {
        displayTimer?.invalidate()
        fadeTimerSource?.cancel()
        gainRampSource?.cancel()
        sleepTimer?.invalidate()
        accessedURL?.stopAccessingSecurityScopedResource()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
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
        guard let url = resolveURL(for: track) else {
            await handleUnplayable()
            return
        }
        // Begin the security scope BEFORE decoding. A bookmark-resolved URL (legacy iOS imports /
        // macOS .withSecurityScope) can't be opened by AVAudioFile/AVAssetReader without an active
        // scope, so decoding first wrongly routed a real, playable file to handleUnplayable() and
        // skipped it. No-op for local-copy URLs (own container, not security-scoped). Released on
        // the failure paths below; on success it's adopted as the current resource.
        let scoped = url.startAccessingSecurityScopedResource()
        guard isPlayable(url, localCopy: track.hasLocalCopy),
              let decoded = await TrackDecoder.open(url: url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            await handleUnplayable()
            return
        }
        skipFailures = 0
        // A track played before its loudness is measured gets a quick estimate from its first
        // seconds, so even that first play starts near the right level. Returns at once when the
        // value is already known or normalization is off. When it does have to measure, this is a
        // real suspension — so if another start request arrived meanwhile, that newer one wins.
        playRequestGeneration += 1
        let request = playRequestGeneration
        await loudness?.quickEstimate(for: track, url: url)
        guard request == playRequestGeneration else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        if autostart {
            do { try session.activate() }
            catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
        }

        // Release the previous track's scope and adopt this one (balanced by the next
        // startPlayback / stop()). accessedURL only tracks a scope we actually started.
        stopAccessingCurrentResource()
        accessedURL = scoped ? url : nil

        cancelCrossfade()
        resetNodes()
        scheduleGeneration += 1
        let generation = scheduleGeneration

        let node = activeNode
        engineGraph.connect(player: node, format: decoded.processingFormat)
        cancelGainRamp()
        currentGain = normalizationGain(for: track)
        node.volume = volume * currentGain

        currentTrack = track
        currentDecoded = decoded
        onTrackChanged?(track)
        prioritizeLoudness(startingWith: track)
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
            guard engineGraph.startAndPlay(node, format: decoded.processingFormat) else {
                // Engine couldn't start or the node was disconnected (e.g. the audio route is still
                // settling after a wired-headset plug / car BT connect). Never call play() on a
                // stopped engine or disconnected node — it raises an uncatchable NSException and
                // crashes. Park paused and retry once shortly.
                clock.invalidate()
                state = .paused
                nowPlayingUpdate()
                scheduleResumeRetry(at: clamped)
                return
            }
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
        // Capture the LIVE render head BEFORE idling the node — once activeNode.pause() runs the
        // clock reads back the parked value. Do NOT use `currentTime`: it's frozen while
        // backgrounded (published only `if isForeground`), so pausing from the lock screen would
        // rewind the playhead to where it was when the screen locked (the "jumps back to 6s" bug).
        let head = clock.seconds(on: activeNode, parked: parkedTime)
        let boundedHead = trackDuration > 0 ? min(head, trackDuration) : head
        activeNode.pause()
        #if os(iOS) || os(visionOS)
        // iOS: idle the WHOLE render pipeline, not just the node, so the engine stops feeding the
        // output. Leaving it running while "paused" wastes power and muddies the paused state that
        // the system (now-playing / headset routing) and our cold-restart resume() depend on.
        // resume() restarts it. macOS deliberately SKIPS this: idling the engine there cost a
        // ~150–225 ms cold restart on the next play/resume (the "playback starts a half-second
        // late, until the song switches" lag). macOS has no Bluetooth route-sleep to recover from,
        // so keeping the engine warm (rendering silence is nearly free on the desktop) makes the
        // next play/resume instant — and, because the route never idles, a bare node.play() resumes
        // reliably even over AirPods, so resume() takes a fast path on macOS.
        engineGraph.pause()
        #endif
        state = .paused
        parkedTime = boundedHead
        if isForeground { currentTime = boundedHead }
        trackStartedAt = nil
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
    func resume() -> Bool { performResume(allowRetry: true) }

    @discardableResult
    private func performResume(allowRetry: Bool) -> Bool {
        guard state == .paused, currentTrack != nil else { return false }
        do { try session.activate() } catch { return false }
        #if os(macOS)
        // macOS keeps the engine RUNNING while paused (see pause()), so resume doesn't need the
        // cold engine rebuild below — that rebuild is the iOS AirPods route-sleep recovery and it
        // added a ~150 ms engine-restart lag. Re-SCHEDULE the track from the parked frame and play
        // it via startAndPlay: the engine is already running, so startAndPlay just calls node.play()
        // (~10 ms), no restart. We reschedule rather than un-pausing the node because a bare
        // node.play() resume fired a spurious end-of-data completion that bounced playback straight
        // back to paused. This mirrors startPlayback's proven autostart path. Falls through to the
        // full rebuild if the engine isn't actually running (e.g. a config-change stopped it).
        if engineGraph.isRunning, let decoded = currentDecoded, let track = currentTrack {
            let resumeAt = parkedTime
            let node = activeNode
            node.stop()
            scheduleGeneration += 1
            clearPreload()
            clock.invalidate()
            engineGraph.connect(player: node, format: decoded.processingFormat)
            node.volume = volume * currentGain
            schedule(decoded, track: track, on: node, from: resumeAt, generation: scheduleGeneration)
            if engineGraph.startAndPlay(node, format: decoded.processingFormat) {
                anchorPlayhead(at: resumeAt)
                lastListenPos = resumeAt
                state = .playing
                startDisplayTimer()
                nowPlayingUpdate()
                return true
            }
            // Couldn't play on the warm engine — fall through to the full rebuild path below.
        }
        #endif
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
            clock.invalidate()
            // FULL cold rebuild: reconnect the WHOLE chain (a route change can drop the eq→output
            // link, whose format follows the HW) AND restart the engine so its AUs re-initialize — a
            // BARE restart leaves them uninitialized and they render `-10867` forever, and play()
            // raises the uncatchable "player started when in a disconnected state". rebuildConnections
            // drops scheduled buffers, so schedule AFTER it; playSafely then only reports success if
            // the engine is actually running (no silent "success" on a dead graph).
            let ready = engineGraph.rebuildConnections(player: node, format: decoded.processingFormat)
            node.volume = volume * currentGain
            schedule(decoded, track: track, on: node, from: resumeAt, generation: scheduleGeneration)
            guard ready, engineGraph.playSafely(node, format: decoded.processingFormat) else {
                // Couldn't rebuild/start or play didn't render — the route is still settling after a
                // wired-headset plug / car BT connect. Stay paused at the parked position and retry
                // once shortly (never play() on a dead graph → no crash, no queue spin).
                parkedTime = resumeAt
                lastListenPos = resumeAt
                stopDisplayTimer()
                nowPlayingUpdate()
                if allowRetry { scheduleResumeRetry(at: resumeAt) }
                return false
            }
            anchorPlayhead(at: resumeAt)
            lastListenPos = resumeAt
        } else {
            // No decoded track to reschedule (shouldn't happen while paused) — best-effort wake.
            do { try engineGraph.resume() } catch { /* recovered by the guard below */ }
            guard engineGraph.isRunning,
                  engineGraph.playSafely(activeNode, format: engineGraph.format) else {
                stopDisplayTimer(); nowPlayingUpdate(); return false
            }
            anchorPlayhead(at: parkedTime)
        }
        state = .playing
        startDisplayTimer()
        nowPlayingUpdate()
        return true
    }

    /// One-shot retry of a (re)start that failed because the engine couldn't come up — typically
    /// the audio route was still settling right after a wired-headset plug or a car Bluetooth
    /// connect. Re-attempts on the main queue a moment later, by when the route is usually runnable.
    /// Capped at a single in-flight retry (and the retry itself passes allowRetry: false, so it
    /// can't reschedule) — a persistently dead route can't spin. Bails if the user changed track or
    /// queue meanwhile. The position is already parked in `parkedTime` by the caller before bailing.
    private func scheduleResumeRetry(at position: TimeInterval) {
        guard !resumeRetryScheduled else { return }
        resumeRetryScheduled = true
        let generation = scheduleGeneration
        let trackID = currentTrackID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.resumeRetryScheduled = false
            guard self.state == .paused,
                  self.scheduleGeneration == generation,
                  self.currentTrackID == trackID else { return }
            self.performResume(allowRetry: false)
        }
    }

    /// Called when the app leaves the foreground. While playing, it's normal background audio —
    /// keep the session live and just push a fresh now-playing snapshot. While paused we KEEP the
    /// session active too (only pausing the engine to save power), so we stay the system's "Now
    /// Playing" app and remain resumable from the lock screen / Control Center / AirPods.
    func enterBackground() {
        // Stop publishing the (invisible) scrubber while off-screen — set BEFORE the branch so it
        // also applies while playing (the main case). On iOS this is scenePhase .background; on
        // macOS it's window occlusion (minimize / Cmd-H / fully covered), where the scrubber is
        // likewise invisible. An occluded macOS window keeps PLAYING — we only freeze the per-tick
        // SwiftUI publish, so the session/engine-idling branch below stays iOS-only.
        isForeground = false
        #if os(iOS) || os(visionOS)
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
            // Paused / no anchor: parkedTime holds the render-accurate position — and is correct
            // even when the pause happened while backgrounded, where `currentTime` was frozen at the
            // lock-time value. Publish parkedTime so the in-app scrubber matches the lock screen
            // instead of rewinding to the stale frozen value.
            syncPlayheadFromClock()
            currentTime = parkedTime
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
        trackStartedAt = Date()
        // Rebase the now-playing resync throttle to this (re)start position so the first periodic
        // lock-screen correction fires ~1s into the new segment, not delayed by the old baseline.
        lastNowPlayingSyncPos = max(0, seconds)
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
        cancelGainRamp()
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
        trackStartedAt = nil
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
            guard engineGraph.startAndPlay(node, format: decoded.processingFormat) else {
                // Route still settling — don't crash on play(); drop to paused at the seek target
                // and retry once shortly.
                state = .paused
                stopDisplayTimer()
                nowPlayingUpdate()
                scheduleResumeRetry(at: target)
                return
            }
            anchorPlayhead(at: target)
        }
        nowPlayingUpdate()
    }

    // Skip relative to `playheadSeconds` (the render head), NOT the observable `currentTime`,
    // which is frozen while backgrounded — so a skip arriving from a background remote command
    // would otherwise seek relative to the stale lock-time position. (Identical in the foreground,
    // where the two are equal; this just keeps the math correct if these are ever wired to a
    // lock-screen command — the skip remote commands are disabled today.)
    func skipForward(_ seconds: TimeInterval = 15) {
        seek(to: min(playheadSeconds + seconds, duration))
    }

    func skipBackward(_ seconds: TimeInterval = 15) {
        seek(to: max(playheadSeconds - seconds, 0))
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

    /// Drop a gapless-preloaded next track whose buffers are ALREADY scheduled back-to-back on the
    /// active node. The queue calls this when its up-next changed (shuffle toggled / reshuffled /
    /// manually reordered / play-next), so the node would otherwise play the now-stale OLD next
    /// track while the queue index moves to the new one. `node.stop()` (inside `seek`) drops every
    /// scheduled buffer including the preload, so re-seeking to the live head flushes it; the next
    /// preload re-triggers naturally as the new up-next nears its end. No-op when nothing is
    /// preloaded, or the preloaded track is STILL the correct next one — so normal playback (and a
    /// reorder that didn't touch the immediate next) never glitches.
    func invalidatePreload() {
        guard preloadStarted || preloadedNext != nil else { return }
        if let preloaded = preloadedNext, preloaded.track.id == crossfadeNextTrack()?.id { return }
        seek(to: parkedTime)
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
        // SPURIOUS instant completion: a route-broken / uninitialized graph (render err -10867)
        // drains the just-scheduled buffer immediately, firing this within ms even though the track
        // never really played. Without this guard each such completion advances the queue → it
        // burns through the whole queue many times/sec. Refuse to advance (or record a play) when
        // the track effectively didn't play (≈0s elapsed and not a genuinely short track) or the
        // graph just failed to start; instead drop to paused + one self-limiting retry.
        let elapsed = trackStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let graphBroken = engineGraph.lastPlayFailure.map { Date().timeIntervalSince($0) < 1.0 } ?? false
        let playedNothing = elapsed < 1.0 && (trackDuration <= 0 || trackDuration > 1.5)
        if graphBroken || playedNothing {
            state = .paused
            stopDisplayTimer()
            clock.invalidate()
            nowPlayingUpdate()
            scheduleResumeRetry(at: parkedTime)
            return
        }
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
            // The node is already rendering `next` back-to-back, so its normalization gain is
            // applied here. Consecutive tracks of one album glide over instead of stepping, so a
            // continuous (live / mixed) album has no audible level jump at the seam.
            setCurrentGain(normalizationGain(for: next.track),
                           rampOver: Self.continuesAlbum(finished, next.track) ? 0.8 : 0.05)
            prioritizeLoudness(startingWith: next.track)
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
        maybeSyncNowPlaying(at: bounded)
        // Pass the freshly-measured play head — NOT the observable `currentTime`, which is frozen
        // while backgrounded (it's only published `if isForeground`). Reading `currentTime` here
        // meant crossfade + gapless preload never triggered on the lock screen / in the background.
        // Read the crossfade setting ONCE per tick — it backs both checks below — instead of
        // hitting UserDefaults twice on every 0.2s tick throughout playback.
        let crossfade = crossfadeDuration
        maybeStartCrossfade(at: bounded, crossfade: crossfade)
        maybePreloadGapless(at: bounded, crossfade: crossfade)
    }

    // MARK: - Gapless preload

    private func maybePreloadGapless(at pos: TimeInterval, crossfade: TimeInterval) {
        guard state == .playing, !isCrossfading, !preloadStarted,
              crossfade == 0, trackDuration > 0,
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

    private func maybeStartCrossfade(at pos: TimeInterval, crossfade: TimeInterval) {
        let xfade = crossfade
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
        cancelGainRamp()
        let incomingGain = normalizationGain(for: track)
        let outgoingGain = currentGain
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
        guard engineGraph.startAndPlay(incoming, format: decoded.processingFormat) else {
            // Route settling — abort the crossfade cleanly so the OUTGOING node keeps playing,
            // instead of crashing on incoming.play() or going silent on a half-swapped graph.
            useNodeB.toggle()              // revert: activeNode goes back to the outgoing node
            crossfadeOutgoing = nil
            isCrossfading = false
            activeNode.volume = volume * currentGain
            return
        }

        // The outgoing track is near its end; record its play if the threshold wasn't hit yet.
        if !playRecorded, let outgoing = currentTrack { playRecorded = true; onTrackPlayed?(outgoing) }
        currentTrack = track
        currentDecoded = decoded
        currentGain = incomingGain
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
        prioritizeLoudness(startingWith: track)
        nowPlayingUpdate()

        // Ramp the two nodes' gains off the main run loop (see `fadeTimerSource`). The handler runs
        // on `fadeQueue`, so it can only touch values, never main-actor state: capture the two node
        // references and the target as locals (AVAudioPlayerNode.volume is a thread-safe render-graph
        // parameter), drive `p` from a monotonic deadline, and hop to the main actor a single time to
        // run `finishCrossfade()`. 100 Hz here is cheap (two float writes/tick) and keeps every step
        // inaudibly small even on a 1 s crossfade.
        // Each node fades to/from ITS OWN track's normalized level, so two differently-loud tracks
        // cross at matched loudness.
        let outgoingTarget = volume * outgoingGain
        let incomingTarget = volume * incomingGain
        let startTime = DispatchTime.now()
        let totalNanos = Double(max(0.001, xfade)) * 1_000_000_000
        nonisolated(unsafe) let rampOutgoing = outgoing
        nonisolated(unsafe) let rampIncoming = incoming
        fadeTimerSource?.cancel()
        let source = DispatchSource.makeTimerSource(queue: fadeQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
            let p = min(1, elapsed / totalNanos)
            rampOutgoing.volume = Float(1 - p) * outgoingTarget
            rampIncoming.volume = Float(p) * incomingTarget
            if p >= 1 {
                source.cancel()
                // Stop the outgoing node HERE (off-main; AVAudioPlayerNode.stop() is thread-safe) so
                // its read-ahead worker stops contending for the render graph immediately, rather than
                // lingering (silent) until the main-actor finishCrossfade hop — which can be delayed by
                // exactly the queue work that triggers this bug. finishCrossfade still clears state.
                rampOutgoing.stop()
                Task { @MainActor in self?.finishCrossfade() }
            }
        }
        fadeTimerSource = source
        source.resume()
    }

    private func finishCrossfade() {
        fadeTimerSource?.cancel(); fadeTimerSource = nil
        crossfadeOutgoing?.stop()
        crossfadeOutgoing = nil
        activeNode.volume = volume * currentGain
        isCrossfading = false
    }

    /// Abandon any in-progress crossfade — the incoming node becomes the sole player.
    private func cancelCrossfade() {
        guard isCrossfading else { return }
        fadeTimerSource?.cancel(); fadeTimerSource = nil
        crossfadeOutgoing?.stop(); crossfadeOutgoing = nil
        activeNode.volume = volume * currentGain
        isCrossfading = false
    }

    // MARK: - Loudness normalization

    private func normalizationGain(for track: Track) -> Float {
        loudness?.nodeGain(for: track) ?? 1
    }

    /// Has the current track and the few after it measured first, so each has its real value
    /// well before it starts.
    private func prioritizeLoudness(startingWith track: Track) {
        guard let loudness else { return }
        loudness.prioritize([track] + (queue?.upNext.prefix(3) ?? []))
    }

    /// The full loudness measurement of a track arrived. If it is the one playing (it started on
    /// an estimate), glide to the measured level instead of jumping.
    func loudnessDidUpdate(for id: UUID) {
        guard id == currentTrackID, state != .stopped,
              let gain = loudness?.nodeGain(forTrackID: id) else { return }
        setCurrentGain(gain, rampOver: 1.5)
    }

    /// Normalization was wired up or switched in Settings: apply (or drop) it right away.
    func normalizationSettingChanged() {
        engineGraph.setMakeupGain(loudness?.makeupGainDB ?? 0)
        cancelGainRamp()
        currentGain = currentTrack.map(normalizationGain(for:)) ?? 1
        if !isCrossfading { activeNode.volume = volume * currentGain }
        if let track = currentTrack { prioritizeLoudness(startingWith: track) }
    }

    /// Changes the current track's normalization gain, ramping the active node there over
    /// `seconds` while playing. Mid-crossfade only the value is stored — `finishCrossfade` applies it.
    private func setCurrentGain(_ gain: Float, rampOver seconds: TimeInterval) {
        let from = currentGain
        currentGain = gain
        cancelGainRamp()
        guard !isCrossfading else { return }
        guard state == .playing, seconds > 0, abs(from - gain) > 0.005 else {
            activeNode.volume = volume * gain
            return
        }
        gainRampGeneration += 1
        let generation = gainRampGeneration
        let userVolume = volume
        let startTime = DispatchTime.now()
        let totalNanos = seconds * 1_000_000_000
        nonisolated(unsafe) let node = activeNode
        let source = DispatchSource.makeTimerSource(queue: fadeQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds)
            let p = Float(min(1, elapsed / totalNanos))
            node.volume = userVolume * (from + (gain - from) * p)
            if p >= 1 {
                source.cancel()
                Task { @MainActor in self?.finishGainRamp(generation) }
            }
        }
        gainRampSource = source
        source.resume()
    }

    private func finishGainRamp(_ generation: Int) {
        guard generation == gainRampGeneration else { return }   // superseded meanwhile
        gainRampSource = nil
        // Re-apply on the main actor so a volume change made during the ramp wins.
        if !isCrossfading { activeNode.volume = volume * currentGain }
    }

    private func cancelGainRamp() {
        gainRampGeneration += 1
        gainRampSource?.cancel()
        gainRampSource = nil
    }

    /// `next` directly follows `previous` on the same album (same disc, next track number).
    private static func continuesAlbum(_ previous: Track, _ next: Track) -> Bool {
        guard let a = previous.album, let b = next.album, a.id == b.id else { return false }
        return previous.discNumber == next.discNumber && next.trackNumber == previous.trackNumber + 1
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
        // Report the render-accurate head (`parkedTime`), NOT the observable `currentTime`.
        // `currentTime` is frozen while backgrounded (published only `if isForeground`), so a push
        // that fires in the background — the periodic maybeSyncNowPlaying resync, or a route/
        // config-change recovery — would otherwise pin the lock screen to a STALE elapsed.
        // `parkedTime` is updated from the render clock on every display tick (fg AND bg), so it is
        // always the true head; in the foreground the two are identical.
        nowPlaying.update(track: track, isPlaying: state.isPlaying, elapsed: parkedTime, duration: trackDuration)
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
        clock.invalidate()
        if wasPlaying {
            // Cold rebuild (reconnect the whole chain + restart so the AUs re-initialize), THEN
            // reschedule from the live head (the rebuild dropped the buffers), THEN play. This is
            // the real recovery for a car-BT / headset route change that arrives while playing — a
            // plain reconnect-while-running leaves the AUs uninitialized (render err -10867).
            let ready = engineGraph.rebuildConnections(player: node, format: decoded.processingFormat)
            node.volume = volume * currentGain
            schedule(decoded, track: track, on: node, from: resumeAt, generation: scheduleGeneration)
            guard ready, engineGraph.playSafely(node, format: decoded.processingFormat) else {
                // Route still settling — stay paused at the live position and retry once shortly.
                state = .paused
                parkedTime = resumeAt
                stopDisplayTimer()
                nowPlayingUpdate()
                scheduleResumeRetry(at: resumeAt)
                return
            }
            anchorPlayhead(at: resumeAt)
        } else {
            // Paused across the route change: just reconnect + reschedule so the next resume() (which
            // does its own full rebuild) is ready. No play() here.
            engineGraph.connect(player: node, format: decoded.processingFormat)
            node.volume = volume * currentGain
            schedule(decoded, track: track, on: node, from: resumeAt, generation: scheduleGeneration)
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

    /// Re-pin the lock-screen / Control-Center elapsed time to the true render head about once a
    /// second while playing. iOS does NOT read our elapsed continuously — it takes the last value
    /// we pushed and EXTRAPOLATES it forward on the wall clock at the playback rate. We only push on
    /// discrete events (play/pause/seek/track-change/bg/fg), so between them the lock screen
    /// free-runs on wall time while the in-app scrubber tracks the real audio. Output latency at
    /// start (engine spin-up + Bluetooth/AirPods buffering) means audio renders a beat AFTER we
    /// first push elapsed=0, so iOS's extrapolation runs a second or two ahead — the "lock screen
    /// shows 0:05 while the app shows 0:03" mismatch, and since the latency varies the gap does too.
    /// Pushing the render-accurate head here corrects it within ~1s and keeps the two surfaces
    /// pinned. Throttled by position delta so the MediaPlayer IPC stays ~1Hz; the pushed value is
    /// monotone, so the lock-screen scrubber only steps forward (apart from the one intended startup
    /// correction). nowPlayingUpdate() reports `parkedTime`, so this is correct in the background too.
    private func maybeSyncNowPlaying(at pos: TimeInterval) {
        guard state == .playing else { return }
        #if os(macOS)
        // Off-screen there's no Now-Playing surface reading us live: macOS Control Center
        // extrapolates from the last push, and we still push a fresh value on every discrete event
        // (play/pause/seek/track-change) and on re-show via enterForeground(). So skip the ~1Hz IPC
        // resync while not visible. iOS keeps it unconditionally (the lock screen needs the resync).
        guard isForeground else { return }
        #endif
        if abs(pos - lastNowPlayingSyncPos) >= 1 {
            lastNowPlayingSyncPos = pos
            nowPlayingUpdate()
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
            cancelGainRamp()
            activeNode.volume = volume * currentGain * Float(remaining / sleepFadeDuration)
        }
    }

    private func fireSleep() {
        flushListen()
        if state.isPlaying { pause() }
        cancelSleepTimer()   // also restores the faded volume
    }

    private func restoreSleepVolume() {
        if !isCrossfading { activeNode.volume = volume * currentGain }
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
        #elseif os(macOS)
        // macOS never delivers scenePhase .background while audio plays and the window is merely
        // occluded/minimized/hidden, so the iOS power optimization (freeze the 5Hz scrubber publish
        // off-screen) would never fire. Drive isForeground from window occlusion instead:
        // NSApp.occlusionState drops .visible exactly when no window is on-screen (incl. Cmd-H,
        // minimize, full cover) and stays .visible for an unfocused-but-visible window — so a
        // background, partially-overlapped or just-not-frontmost window keeps its live scrubber,
        // while a truly invisible one stops invalidating SwiftUI (and lets App Nap kick in).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.occlusionState.contains(.visible) ? self.enterForeground() : self.enterBackground()
            }
        }
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
