import Foundation
import Observation
import SwiftData

/// Loudness normalization: owns each track's measured loudness and turns it into the gain the
/// player applies, so a quiet file and a loud one play back equally loud.
///
/// Measuring needs a full decode, so it never happens on the import or playback path. Tracks are
/// analyzed in the background — one at a time, low priority. Whatever is about to play jumps the
/// line (`prioritize`), and a track that starts before its full measurement exists gets a quick
/// estimate from its first seconds (`quickEstimate`), refined when the real value lands (`onResult`).
///
/// PERFORMANCE RULE: nothing here touches a Track model while the analysis runs. Setting a property
/// on a main-context model — even without saving — makes every live `@Query` re-fetch, and doing
/// that once per measured track froze the UI for a moment about once a second for the whole first
/// pass over a library. Results therefore live in memory (`measured`, which is what playback reads)
/// and are written to the store in ONE go: when a pass over the library is finished, together
/// with the save on pause / leaving the foreground, or after a large batch. A result lost to a
/// kill is simply measured again.
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
    /// What the worker needs to measure a track without going back to the store.
    nonisolated private struct Job: Sendable {
        let id: UUID
        let url: URL
    }
    private var backlog: [Job] = []
    private var urgent: [Job] = []
    private var queued: Set<UUID> = []
    private var worker: Task<Void, Never>?
    /// Measurements not yet written to the store (see the performance rule above).
    private var unflushed: [UUID: LoudnessMeasurement] = [:]
    /// Safety net for a very long pass: write after this many results even while in the foreground.
    private let flushThreshold = 500
    private let minimumOwnFlush = 50

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
        lookupMeasured(track) ?? estimates[track.id]
    }

    /// The FULL measurement, from memory or (first use) from the stored value.
    private func lookupMeasured(_ track: Track) -> LoudnessMeasurement? {
        let id = track.id
        if let known = measured[id] { return known }
        if let lufs = track.loudnessLUFS {
            let value = LoudnessMeasurement(lufs: lufs, peakDB: track.loudnessPeakDB ?? 0)
            measured[id] = value
            return value
        }
        return nil
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
        let jobs = tracks.compactMap { track -> Job? in
            guard lookupMeasured(track) == nil, let url = try? track.resolveURL() else { return nil }
            return Job(id: track.id, url: url)
        }
        guard !jobs.isEmpty else { return }
        let ids = Set(jobs.map(\.id))
        urgent.removeAll { ids.contains($0.id) }
        backlog.removeAll { ids.contains($0.id) }
        urgent.insert(contentsOf: jobs, at: 0)
        for id in ids where queued.insert(id).inserted { remaining += 1 }
        startWorkerIfNeeded()
    }

    /// Queues every track that has no measurement yet (launch, after an import, after a rescan).
    /// The list is read on a throwaway background context, so even a whole library costs the main
    /// thread nothing.
    func enqueueMissing() {
        guard isEnabled else { return }
        let container = context.container
        Task { [weak self] in
            let jobs = await Task.detached(priority: .utility) { () -> [Job] in
                let reader = ModelContext(container)
                let descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.loudnessLUFS == nil })
                let tracks = (try? reader.fetch(descriptor)) ?? []
                return tracks.compactMap { track in
                    (try? track.resolveURL()).map { Job(id: track.id, url: $0) }
                }
            }.value
            self?.enqueue(jobs)
        }
    }

    private func enqueue(_ jobs: [Job]) {
        guard isEnabled else { return }
        for job in jobs where measured[job.id] == nil && queued.insert(job.id).inserted {
            backlog.append(job)
            remaining += 1
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
            flush()
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
            let job: Job
            if !urgent.isEmpty {
                job = urgent.removeFirst()
            } else if !backlog.isEmpty {
                // The backlog is housekeeping — don't burn battery or heat for it. What's about
                // to play (`urgent`) is still measured.
                if Self.shouldDeferBacklog {
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                job = backlog.removeFirst()
            } else {
                break
            }
            await analyze(job)
            queued.remove(job.id)
            remaining = max(0, remaining - 1)
            if unflushed.count >= flushThreshold { flush() }
        }
        // The pass is done (or was cancelled): one write for what it found. A handful of results
        // (the few tracks around the one that is playing) isn't worth a refresh of its own — they
        // go out with the next save the app does anyway (pause, leaving the foreground).
        if unflushed.count >= minimumOwnFlush { flush() }
    }

    private func analyze(_ job: Job) async {
        guard measured[job.id] == nil else { return }
        let url = job.url
        // Legacy bookmark-based tracks need their security scope for the read.
        let scoped = url.startAccessingSecurityScopedResource()
        let result = await Task.detached(priority: .utility) {
            await LoudnessMeter.measure(url: url)
        }.value
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard !Task.isCancelled else { return }

        let value: LoudnessMeasurement
        if let result {
            value = result
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Readable but silent / undecodable: remember that, so it isn't retried every launch.
            // A file that is merely missing right now stays unmeasured and is retried later.
            value = LoudnessMeasurement(lufs: Self.unmeasurable, peakDB: 0)
        } else {
            return
        }
        measured[job.id] = value
        estimates[job.id] = nil
        unflushed[job.id] = value
        onResult?(job.id)
    }

    /// Writes the measurements collected so far onto their tracks. Deliberately rare (see the
    /// performance rule at the top) and WITHOUT its own save when called ahead of one: the caller
    /// that is about to save anyway (leaving the foreground) passes `save: false`.
    func flush(save: Bool = true) {
        guard !unflushed.isEmpty else { return }
        let pending = unflushed
        unflushed.removeAll()
        let ids = Array(pending.keys)
        // A track deleted in the meantime simply isn't in the result.
        let descriptor = FetchDescriptor<Track>(predicate: #Predicate { ids.contains($0.id) })
        guard let tracks = try? context.fetch(descriptor) else {
            unflushed = pending   // keep them for the next attempt
            return
        }
        for track in tracks {
            guard let value = pending[track.id] else { continue }
            track.loudnessLUFS = value.lufs
            track.loudnessPeakDB = value.peakDB
        }
        if save { try? context.save() }
    }

    private static var shouldDeferBacklog: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
    }
}
