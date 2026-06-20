import Foundation

/// Persisted "resume where you left off" payload: the queue snapshot plus the play-head
/// position. Stored as a small JSON blob in UserDefaults — no file references, fully
/// offline, and re-resolved against the library on load.
struct PersistedPlayback: Codable {
    var queue: PlaybackQueue.Snapshot
    var position: TimeInterval
}

/// Reads/writes the last playback session. The payload is usually a handful of UUIDs, but a
/// shuffle-all of a large library makes it sizeable, so the encode + write run off-main.
enum PlaybackStateStore {
    private static let key = "lastPlaybackState_v1"
    /// Serial queue for the encode + UserDefaults write so the ~5s playback ticks never stack
    /// or race, and a large (shuffle-all) JSON encode never blocks the main thread.
    private static let ioQueue = DispatchQueue(label: "app.luma.playbackstate", qos: .utility)

    /// Saves the current queue + position. A stopped/empty session clears the stored state
    /// instead — there's nothing to resume. `snapshot()` is taken on the caller (main) thread
    /// where the live queue is owned; only the encode + write are dispatched off-main.
    static func save(queue: PlaybackQueue, position: TimeInterval) {
        let snap = queue.snapshot()
        guard !snap.itemIDs.isEmpty, snap.currentID != nil else { clear(); return }
        let payload = PersistedPlayback(queue: snap, position: max(0, position))
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> PersistedPlayback? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedPlayback.self, from: data)
    }

    static func clear() {
        ioQueue.async { UserDefaults.standard.removeObject(forKey: key) }
    }
}
