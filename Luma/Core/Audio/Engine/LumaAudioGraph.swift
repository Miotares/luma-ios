import AVFAudio
import Foundation

/// The AVAudioEngine processing graph for gapless playback + EQ.
///
/// Two player nodes let an outgoing and incoming track overlap (crossfade); both feed a
/// mixer, then the EQ, then the engine output:
///
///     playerA ┐
///             ├─ mixer ─ eq ─ output
///     playerB ┘
///
/// This type owns the graph and its lifecycle only — the scheduler (built in the AudioPlayer
/// cut-over stage) decides which node plays which track and when. It also recovers from
/// `AVAudioEngineConfigurationChange` (route / sample-rate changes), which AVPlayer handled
/// for free and an engine must handle explicitly.
///
/// NOTE: runtime behaviour (gapless scheduling, EQ audibility, config-change recovery) is
/// verified at the cut-over stage on a runnable target — this file is the compile-clean
/// foundation those stages build on.
@MainActor
final class LumaAudioGraph {
    let engine = AVAudioEngine()
    let playerA = AVAudioPlayerNode()
    let playerB = AVAudioPlayerNode()
    let eq: AVAudioUnitEQ
    private let mixer = AVAudioMixerNode()

    /// The processing format the graph is currently wired for. Reconnecting for a new sample
    /// rate briefly drops audio — the one unavoidable gap at a rate boundary.
    private(set) var format: AVAudioFormat

    /// Fired after the engine was reconfigured (HW/route change). The owner should restart
    /// the engine and reschedule playback from the current frame.
    var onConfigurationChange: (() -> Void)?

    /// 10 ISO octave-band centre frequencies (Hz).
    static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    init(bandCount: Int = 10) {
        eq = AVAudioUnitEQ(numberOfBands: bandCount)

        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outRate > 0 ? outRate : 44_100
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

        connectGraph(for: format)
        configureEQBands()
        observeConfigurationChange()
    }

    // MARK: - Wiring

    private func connectGraph(for format: AVAudioFormat) {
        for node in [playerA, playerB, mixer, eq] where node.engine == nil {
            engine.attach(node)
        }
        engine.connect(playerA, to: mixer, format: format)
        engine.connect(playerB, to: mixer, format: format)
        engine.connect(mixer, to: eq, format: format)
        engine.connect(eq, to: engine.outputNode, format: format)
    }

    /// Reconnect a player node to the mixer with a specific input format (the track's native
    /// format). The mixer resamples each input to the output rate, so different-rate tracks
    /// play without a manual converter. Crossfade uses both nodes, each at its track's format.
    func connect(player node: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: mixer, format: format)
    }

    /// Rewire the graph for a new processing format (different sample rate). The caller is
    /// expected to stop/restart the engine and reschedule around this.
    func reconfigure(for newFormat: AVAudioFormat) {
        guard newFormat.sampleRate != format.sampleRate else { return }
        format = newFormat
        engine.disconnectNodeOutput(playerA)
        engine.disconnectNodeOutput(playerB)
        engine.disconnectNodeOutput(mixer)
        engine.disconnectNodeOutput(eq)
        engine.connect(playerA, to: mixer, format: newFormat)
        engine.connect(playerB, to: mixer, format: newFormat)
        engine.connect(mixer, to: eq, format: newFormat)
        engine.connect(eq, to: engine.outputNode, format: newFormat)
    }

    // MARK: - Lifecycle

    /// Whether the engine's render pipeline is actually running. The single source of truth a
    /// caller MUST check before AVAudioPlayerNode.play() — see `startAndPlay`.
    var isRunning: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Restart rendering after `pause()` — used by `AudioPlayer.resume()` when the user taps play.
    /// This does a FULL cold restart (stop → prepare → start), NOT a bare `engine.start()`, ON
    /// PURPOSE: a *paused* engine still reports `isRunning == true`, so a bare `engine.start()`
    /// would skip `prepare()` and NOT re-acquire an output route the system idled/tore down while
    /// we were paused in the background — the classic Bluetooth/AirPods "pause works, play-after-
    /// pause is silent, but skip works" bug (skip works only because it rebuilds from a clean node
    /// state). Stopping first forces `prepare()` to re-instantiate the HAL output unit and re-grab
    /// the (possibly slept) AirPods route, so playback is audible again. CONTRACT: the caller must
    /// (re)schedule the node's buffers AFTER this returns — a stop can drop already-scheduled ones.
    func resume() throws {
        if engine.isRunning { engine.stop() }
        engine.prepare()
        try engine.start()
    }

    /// Start the engine if needed and play `node` — but ONLY if the engine is verifiably running.
    /// `AVAudioPlayerNode.play()` on a stopped engine raises an UNCATCHABLE Obj-C NSException
    /// ("required condition is false: _engine->IsRunning()") that Swift `try?`/`do-catch` cannot
    /// trap — the hard crash when an audio route change (wired-headset plug, car Bluetooth) leaves
    /// `engine.start()` momentarily failing. On a healthy route this is identical to start()+play();
    /// on a settling route it returns false WITHOUT calling play(), so the caller can stay paused
    /// and retry instead of crashing. Returns whether playback actually started.
    @discardableResult
    func startAndPlay(_ node: AVAudioPlayerNode) -> Bool {
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { return false }
        }
        guard engine.isRunning else { return false }
        node.play()
        return true
    }

    func stop() {
        engine.stop()
    }

    /// Pause the engine (vs `stop()`) so the graph, connections and scheduled buffers survive
    /// — used when backgrounding while paused so the OS sees an idle render pipeline. `start()`
    /// restarts it and the player node resumes from its paused frame (gapless).
    func pause() {
        engine.pause()
    }

    /// Gain of a player node (0...1), used for crossfade ramps and the sleep-timer fade.
    func setVolume(_ volume: Float, on node: AVAudioPlayerNode) {
        node.volume = max(0, min(1, volume))
    }

    // MARK: - EQ bands

    private func configureEQBands() {
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            if i < Self.bandFrequencies.count { band.frequency = Self.bandFrequencies[i] }
            band.bandwidth = 0.5   // octaves
            band.gain = 0
            band.bypass = false
        }
        eq.globalGain = 0
        eq.bypass = true   // flat by default → bit-perfect passthrough until the user enables EQ
    }

    // MARK: - Configuration-change recovery

    private func observeConfigurationChange() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    private func handleConfigurationChange() {
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if outRate > 0, outRate != format.sampleRate,
           let newFormat = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2) {
            reconfigure(for: newFormat)
        }
        onConfigurationChange?()
    }
}
