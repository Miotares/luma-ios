import Foundation
import Observation
import SwiftData

/// Loudness normalization: owns each track's measured loudness and turns it into the gain the
/// player applies, so a quiet file and a loud one play back equally loud.
///
/// Measuring needs a full decode, so it never happens on the import or playback path. Tracks are
/// analyzed in the background — one at a time, low priority — and the result is stored on the
/// Track. Whatever is about to play jumps the line (`prioritize`), and a track that starts before
/// its full measurement exists gets a quick estimate from its first seconds (`quickEstimate`),
/// refined when the real value lands (`onResult`).
@Observable
final class LoudnessService {
    static let enabledKey = "normalizeVolume"
    /// Programme loudness every track is brought to (the level Spotify / YouTube use).
    static let targetLUFS = -14.0
    /// Most a quiet track is boosted. The player node can only attenuate (volume ≤ 1), so the
    /// graph adds this as a constant make-up gain and each node subtracts what it doesn't need.
    static let maxBoostDB = 10.0
    /// Headroom kept below full scale when boosting: the stored peak is a SAMPLE peak, and the
    /// reconstructed waveform between samples can run a little higher.
    private static let peakMarginDB = 1.0
    static let maxCutDB = -18.0
    /// Stored for a file with no measurable signal, so it isn't re-analyzed on every launch. Real
    /// music never reaches 0 LUFS; any value ≥ 0 means "leave this track alone".
    private static let unmeasurable = 0.0
    /// Assumed loudness of a track nothing is known about yet (a typical modern master).
    private static let assumedLUFS = -10.0

    /// Tracks still waiting for their measurement (drives the Settings progress line).
    private(set) var remaining = 0
    /// Fired on the main actor when a track's FULL measurement arrives.
    var onResult: ((UUID) -> Void)?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private let context: ModelContext
    /// Authoritative for playback: filled from the store on first use and by every new result, so
    /// the player never depends on when the batched save happens.
    private var measured: [UUID: LoudnessMeasurement] = [:]
    /// Quick estimates — in memory only, replaced by the full measurement.
    private var estimates: [UUID: LoudnessMeasurement] = [:]
    private var backlog: [UUID] = []
    private var urgent: [UUID] = []
    private var queued: Set<UUID> = []
    private var worker: Task<Void, Never>?
    private var unsaved = 0
    private let saveInterval = 25

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Gain

    /// Linear gain for the player node (0…1). With normalization off this is 1 — and the graph's
    /// make-up gain is 0 dB — so playback is exactly as it was before.
    func nodeGain(for track: Track) -> Float {
        guard isEnabled else { return 1 }
        return Self.nodeGain(forGainDB: gainDB(for: lookup(track)))
    }

    /// Same, by id — for callers that must not touch a Track that may have been deleted meanwhile.
    func nodeGain(forTrackID id: UUID) -> Float? {
        guard isEnabled, let value = measured[id] ?? estimates[id] else { return nil }
        return Self.nodeGain(forGainDB: gainDB(for: value))
    }

    var makeupGainDB: Float { isEnabled ? Float(Self.maxBoostDB) : 0 }

    private func gainDB(for measurement: LoudnessMeasurement?) -> Double {
        guard let measurement else { return Self.targetLUFS - Self.assumedLUFS }
        guard measurement.lufs < 0 else { return 0 }
        var gain = Self.targetLUFS - measurement.lufs
        gain = min(gain, Self.maxBoostDB)
        // Never push the track's own peak past full scale — a boosted quiet-but-dynamic track
        // would otherwise clip.
        gain = min(gain, -measurement.peakDB - Self.peakMarginDB)
        return max(gain, Self.maxCutDB)
    }

    private static func nodeGain(forGainDB gainDB: Double) -> Float {
        Float(pow(10, min(0, gainDB - maxBoostDB) / 20))
    }

    private func lookup(_ track: Track) -> LoudnessMeasurement? {
        let id = track.id
        if let known = measured[id] { return known }
        if let lufs = track.loudnessLUFS {
            let value = LoudnessMeasurement(lufs: lufs, peakDB: track.loudnessPeakDB ?? 0)
            measured[id] = value
            return value
        }
        return estimates[id]
    }

    /// Whether `track` already has a full measurement or an estimate to play with.
    func hasValue(for track: Track) -> Bool { lookup(track) != nil }

    // MARK: - Analysis

    /// Measures the first seconds of a track that is about to play unmeasured, so even its first
    /// play starts near the right level. Cheap (a few ms of decode) and never persisted.
    func quickEstimate(for track: Track, url: URL) async {
        guard isEnabled, lookup(track) == nil else { return }
        let id = track.id
        let estimate = await Task.detached(priority: .userInitiated) {
            await LoudnessMeter.measure(url: url, maxSeconds: 20)
        }.value
        if let estimate, measured[id] == nil { estimates[id] = estimate }
    }

    /// Moves these tracks to the front of the queue (the current track and what follows it).
    func prioritize(_ tracks: [Track]) {
        guard isEnabled else { return }
        let ids = tracks.filter { measured[$0.id] == nil && $0.loudnessLUFS == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        urgent.removeAll { ids.contains($0) }
        backlog.removeAll { ids.contains($0) }
        urgent.insert(contentsOf: ids, at: 0)
        for id in ids where queued.insert(id).inserted { remaining += 1 }
        startWorkerIfNeeded()
    }

    /// Queues every track that has no measurement yet (launch, after an import, after a rescan).
    func enqueueMissing() {
        guard isEnabled else { return }
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.loudnessLUFS == nil })
        descriptor.propertiesToFetch = [\.id]
        guard let missing = try? context.fetch(descriptor) else { return }
        for track in missing {
            let id = track.id
            if queued.insert(id).inserted {
                backlog.append(id)
                remaining += 1
            }
        }
        startWorkerIfNeeded()
    }

    /// The setting was switched: start the backlog when turned on, drop it when turned off.
    func settingChanged() {
        if isEnabled {
            enqueueMissing()
        } else {
            worker?.cancel()
            worker = nil
            backlog.removeAll()
            urgent.removeAll()
            queued.removeAll()
            remaining = 0
            saveIfNeeded(force: true)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !(urgent.isEmpty && backlog.isEmpty) else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
            // Anything queued while the last item was finishing.
            self?.startWorkerIfNeeded()
        }
    }

    private func drain() async {
        while !Task.isCancelled {
            let id: UUID
            if !urgent.isEmpty {
                id = urgent.removeFirst()
            } else if !backlog.isEmpty {
                // The backlog is housekeeping — don't burn battery or heat for it. What's about
                // to play (`urgent`) is still measured.
                if Self.shouldDeferBacklog {
                    saveIfNeeded(force: true)
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                id = backlog.removeFirst()
            } else {
                break
            }
            await analyze(id)
            queued.remove(id)
            remaining = max(0, remaining - 1)
        }
        saveIfNeeded(force: true)
    }

    private func analyze(_ id: UUID) async {
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let track = try? context.fetch(descriptor).first, track.loudnessLUFS == nil,
              let url = try? track.resolveURL() else { return }
        // Legacy bookmark-based tracks need their security scope for the read.
        let scoped = url.startAccessingSecurityScopedResource()
        let result = await Task.detached(priority: .utility) {
            await LoudnessMeter.measure(url: url)
        }.value
        if scoped { url.stopAccessingSecurityScopedResource() }
        // Deleted while its file was being read, or the read was cancelled.
        guard !Task.isCancelled, track.modelContext != nil else { return }

        if let result {
            measured[id] = result
            estimates[id] = nil
            track.loudnessLUFS = result.lufs
            track.loudnessPeakDB = result.peakDB
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Readable but silent / undecodable: remember that, so it isn't retried every launch.
            // A file that is merely missing right now stays unmeasured and is retried later.
            measured[id] = LoudnessMeasurement(lufs: Self.unmeasurable, peakDB: 0)
            track.loudnessLUFS = Self.unmeasurable
            track.loudnessPeakDB = 0
        } else {
            return
        }
        unsaved += 1
        saveIfNeeded(force: false)
        onResult?(id)
    }

    /// Autosave is off on the main context and every save republishes all live queries, so results
    /// are written in batches rather than one save per track.
    private func saveIfNeeded(force: Bool) {
        guard unsaved > 0, force || unsaved >= saveInterval else { return }
        try? context.save()
        unsaved = 0
    }

    private static var shouldDeferBacklog: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
    }
}
