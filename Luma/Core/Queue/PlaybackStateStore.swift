import Foundation

/// Persisted "resume where you left off" payload: the queue snapshot plus the play-head
/// position. Stored as a small JSON blob in UserDefaults — no file references, fully
/// offline, and re-resolved against the library on load.
struct PersistedPlayback: Codable {
    var queue: PlaybackQueue.Snapshot
    var position: TimeInterval
}

/// Reads/writes the last playback session. Deliberately tiny and synchronous: the payload
/// is a handful of UUIDs, so encoding it on a state change (pause, track change, ~5s tick,
/// backgrounding) is cheap.
enum PlaybackStateStore {
    private static let key = "lastPlaybackState_v1"

    /// Saves the current queue + position. A stopped/empty session clears the stored state
    /// instead — there's nothing to resume.
    static func save(queue: PlaybackQueue, position: TimeInterval) {
        let snap = queue.snapshot()
        guard !snap.itemIDs.isEmpty, snap.currentID != nil else { clear(); return }
        let payload = PersistedPlayback(queue: snap, position: max(0, position))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> PersistedPlayback? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedPlayback.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
