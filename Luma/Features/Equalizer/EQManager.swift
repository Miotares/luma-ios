import AVFAudio
import Foundation
import Observation

/// 10-band graphic equalizer model. Persists to UserDefaults and pushes per-band gains into
/// the graph's `AVAudioUnitEQ`. The unit is bypassed entirely when the EQ is off OR flat, so
/// playback stays bit-perfect unless the user actually shapes the sound.
@MainActor
@Observable
final class EQManager {
    static let bandCount = 10
    static let enabledKey = "eqEnabled"
    static let gainsKey = "eqBandGains"
    static let presetKey = "eqPreset"
    static let gainRange: ClosedRange<Float> = -12...12

    private(set) var isEnabled: Bool
    /// Per-band gain in dB.
    private(set) var gains: [Float]
    /// Id of the active preset, or "custom" once a band is hand-tuned.
    private(set) var presetID: String

    private weak var graph: LumaAudioGraph?

    struct Preset: Identifiable {
        let id: String
        let nameKey: String       // String-Catalog key
        let gains: [Float]
    }

    static let presets: [Preset] = [
        .init(id: "flat",   nameKey: "Flach",      gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(id: "bass",   nameKey: "Bass-Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        .init(id: "treble", nameKey: "Höhen",      gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        .init(id: "vocal",  nameKey: "Stimme",     gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        .init(id: "loud",   nameKey: "Loudness",   gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
    ]

    init() {
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Self.enabledKey)
        if let raw = d.array(forKey: Self.gainsKey) as? [Double], raw.count == Self.bandCount {
            gains = raw.map { Float(max(Double(Self.gainRange.lowerBound), min(Double(Self.gainRange.upperBound), $0))) }
        } else {
            gains = Array(repeating: 0, count: Self.bandCount)
        }
        presetID = d.string(forKey: Self.presetKey) ?? "flat"
    }

    /// Wire to the graph and push the current settings.
    func attach(to graph: LumaAudioGraph) {
        self.graph = graph
        apply()
    }

    // MARK: - Mutations

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        apply()
    }

    func setGain(_ gain: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, gain))
        presetID = "custom"
        persist()
        apply()
    }

    func applyPreset(_ preset: Preset) {
        gains = preset.gains
        presetID = preset.id
        if !isEnabled { setEnabled(true) }   // choosing a preset implies turning EQ on
        persist()
        apply()
    }

    // MARK: - Apply / persist

    private var isFlat: Bool { gains.allSatisfy { abs($0) < 0.1 } }

    private func apply() {
        guard let eq = graph?.eq else { return }
        eq.bypass = !(isEnabled && !isFlat)   // bypass when off or flat → bit-perfect
        for (i, band) in eq.bands.enumerated() where i < gains.count {
            band.gain = isEnabled ? gains[i] : 0
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(gains.map(Double.init), forKey: Self.gainsKey)
        d.set(presetID, forKey: Self.presetKey)
    }
}
