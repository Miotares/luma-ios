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

    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
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
