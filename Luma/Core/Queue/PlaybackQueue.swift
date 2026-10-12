import Foundation
import Observation
import SwiftUI

@Observable
final class PlaybackQueue {
    enum ShuffleMode { case off, on }
    enum RepeatMode: Int { case off, one, all }

    // MARK: - State

    private(set) var items: [Track] = []
    private(set) var currentIndex: Int = -1
    var shuffleMode: ShuffleMode = .off
    var repeatMode: RepeatMode = .off

    private var originalOrder: [Track] = []

    /// Guards the user-facing relative-skip actions (advance / playPrevious) so rapid taps can't
    /// interleave: each mutates `currentIndex` then SUSPENDS across the track decode, and a second
    /// tap landing in that window would read the already-moved index and skip twice. Re-entrant
    /// skips are dropped while one is in flight; the user can skip again once it completes.
    private var isSkipping = false

    weak var player: AudioPlayer?

    // MARK: - Computed

    var currentTrack: Track? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// Whether "forward" leads anywhere. Observed by the transport buttons to disable forward at the
    /// end of the queue (repeat off), instead of advance() calling stop() and dismissing the player.
    var hasNext: Bool {
        switch repeatMode {
        case .all, .one: return !items.isEmpty
        case .off: return currentIndex < items.count - 1
        }
    }

    var upNext: [Track] {
        guard currentIndex >= 0, currentIndex + 1 < items.count else { return [] }
        return Array(items[(currentIndex + 1)...])
    }

    // MARK: - Queue Operations

    /// Starts a new queue. `shuffle` is always explicit: tapping a song or "Abspielen" plays the
    /// list in its order from there, only "Shuffle" starts it mixed. (It used to be optional and
    /// INHERIT the last mode on a song tap — so after one use of a Shuffle button, tapping track 1
    /// of an album anywhere in the app played that album in random order, with nothing on the page
    /// saying why.) The shuffle switch in the player still re-mixes the queue that is playing.
    func setQueue(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool = false) {
        originalOrder = tracks
        shuffleMode = shuffle ? .on : .off
        if shuffleMode == .on {
            items = shuffled(keeping: tracks[safe: index])
            currentIndex = 0
        } else {
            items = tracks
            currentIndex = index
        }
    }

    func append(_ tracks: [Track]) {
        originalOrder.append(contentsOf: tracks)
        items.append(contentsOf: tracks)
        // Appending to the LAST track changes what comes next under "repeat all" (it was the
        // first track, now it is the appended one) — drop a gapless preload of the old one.
        player?.invalidatePreload()
    }

    func playNext(_ tracks: [Track]) {
        let currentID = currentTrack?.id
        items.insert(contentsOf: tracks, at: min(currentIndex + 1, items.count))
        // Insert right AFTER the current track in `originalOrder` too. `currentIndex` indexes the
        // (possibly shuffled) `items`, so it is NOT a valid position in `originalOrder` — using it
        // there dropped "Play Next" tracks at an arbitrary spot once shuffle was turned off. Resolve
        // the current track's real position in `originalOrder` by id instead (append if not found).
        if let currentID, let oi = originalOrder.firstIndex(where: { $0.id == currentID }) {
            originalOrder.insert(contentsOf: tracks, at: oi + 1)
        } else {
            originalOrder.append(contentsOf: tracks)
        }
        player?.invalidatePreload()
    }

    /// Replaces the upcoming tracks (everything after the current one) with `newUpNext`,
    /// leaving the current track and the already-played history untouched. Backs the queue
    /// view's drag-to-reorder, which edits the up-next slice through a binding.
    func replaceUpNext(with newUpNext: [Track]) {
        let pivot = currentIndex + 1
        guard pivot >= 0, pivot <= items.count else { return }
        items.replaceSubrange(pivot..<items.count, with: newUpNext)
        // While NOT shuffled, `items` IS the canonical order, so a manual reorder must mirror into
        // `originalOrder` — otherwise a later shuffle toggle (or `shuffled(keeping:)`) would revert
        // to the pre-reorder order. While shuffled, `originalOrder` stays the un-shuffled sequence so
        // turning shuffle off still restores it; only the SET must match (a reorder never changes it).
        if shuffleMode == .off { originalOrder = items }
        player?.invalidatePreload()
    }

    func clear() {
        items = []
        originalOrder = []
        currentIndex = -1
    }

    /// Removes the up-next track at `offset` (0 = the first track after the current one). POSITION-
    /// based on purpose: a queue legitimately repeats the same track (e.g. a library with duplicate
    /// imports, or "play next" of an already-queued song), and the old id-based `removeTrack` used
    /// `removeAll`, which deleted EVERY occurrence — so removing one row also dropped its duplicate
    /// further down ("removes the song after, not the one I clicked"). This drops exactly the tapped
    /// slot. The current track + history are untouched, so `currentIndex` doesn't move.
    func removeUpNext(at offset: Int) {
        let index = currentIndex + 1 + offset
        guard index > currentIndex, items.indices.contains(index) else { return }
        let removed = items.remove(at: index)
        if shuffleMode == .off {
            // `items` is canonical while not shuffled — mirror the removal.
            originalOrder = items
        } else if let oi = originalOrder.firstIndex(where: { $0.id == removed.id }) {
            // Drop ONE matching occurrence so turning shuffle off later can't resurrect it.
            originalOrder.remove(at: oi)
        }
        player?.invalidatePreload()
    }

    /// Reorders the up-next slice (drag-to-reorder). Offsets are relative to the first up-next slot,
    /// so the current track + history stay put. Mirrors the existing `replaceUpNext` semantics.
    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        var up = upNext
        up.move(fromOffsets: source, toOffset: destination)
        replaceUpNext(with: up)
    }

    /// Drops a track that was just deleted from the library, keeping the current track
    /// stable. Returns true if the removed track was the one currently playing.
    @discardableResult
    func removeTrack(id: UUID) -> Bool {
        let wasCurrent = currentTrack?.id == id
        // The current track keeps its SLOT: shift the index by what was removed in front of it.
        // (Looking the current track up by id afterwards jumped to an earlier slot when the queue
        // holds the same song twice.)
        let removedBefore = items.prefix(max(currentIndex, 0)).filter { $0.id == id }.count
        items.removeAll { $0.id == id }
        originalOrder.removeAll { $0.id == id }
        if wasCurrent {
            currentIndex = min(currentIndex - removedBefore, items.count - 1)
        } else {
            currentIndex -= removedBefore
        }
        // The immediate next track may have just been removed — drop any stale gapless preload of
        // it (mirrors every other queue mutation). Harmless when the removed track wasn't preloaded.
        player?.invalidatePreload()
        return wasCurrent
    }

    // MARK: - Playback Navigation

    /// Moves the current index to `track` without (re)starting playback — the AudioPlayer has
    /// already begun it as part of a gapless hand-over or a crossfade. Normally that is simply the
    /// next slot. But the player picked the track a few seconds earlier; should the queue have
    /// changed in a way that slipped past `invalidatePreload`, the index follows the AUDIO (the
    /// nearest slot holding that track) instead of pointing at a song that isn't the one playing.
    func advanceIndexForCrossfade(to track: Track) {
        guard repeatMode != .one, !items.isEmpty else { return }
        let expected: Int?
        switch repeatMode {
        case .all: expected = (currentIndex + 1) % items.count
        default:   expected = currentIndex < items.count - 1 ? currentIndex + 1 : nil
        }
        if let expected, items[expected].id == track.id {
            currentIndex = expected
        } else if let found = nextIndex(of: track.id) {
            currentIndex = found
        } else if let expected {
            currentIndex = expected
        }
    }

    /// The slot holding `id` that comes next in playing order: after the current one first, then
    /// (wrapping) before it. A queue can hold the same song more than once.
    private func nextIndex(of id: UUID) -> Int? {
        let start = currentIndex + 1
        if start < items.count, let ahead = items[start...].firstIndex(where: { $0.id == id }) { return ahead }
        return items.firstIndex { $0.id == id }
    }

    func advance() async {
        guard !isSkipping else { return }
        isSkipping = true
        defer { isSkipping = false }
        switch repeatMode {
        case .one:
            // "Repeat one" repeats a track that ENDS (the player does that itself and never comes
            // through here). A skip the user asked for moves on — it used to restart the same song,
            // so the Next button did nothing but rewind. Only at the very end, where there is
            // nothing to move on to, does it start the track over.
            if currentIndex < items.count - 1 {
                currentIndex += 1
                await playCurrentTrack()
            } else {
                await player?.seek(to: 0)
                player?.resume()
            }
        case .all:
            currentIndex = (currentIndex + 1) % max(items.count, 1)
            await playCurrentTrack()
        case .off:
            if currentIndex < items.count - 1 {
                currentIndex += 1
                await playCurrentTrack()
            } else {
                player?.stop()
            }
        }
    }

    /// Skip an unplayable track: always move FORWARD (never repeat-one), play the next,
    /// or stop at the end. The AudioPlayer bounds the retries so an all-missing queue
    /// can't loop forever.
    func advancePastUnplayable() async {
        switch repeatMode {
        case .all:
            currentIndex = (currentIndex + 1) % max(items.count, 1)
            await playCurrentTrack()
        case .one, .off:
            if currentIndex < items.count - 1 {
                currentIndex += 1
                await playCurrentTrack()
            } else {
                player?.stop()
            }
        }
    }

    func playPrevious() async {
        guard !isSkipping else { return }
        isSkipping = true
        defer { isSkipping = false }
        if (player?.playheadSeconds ?? 0) > 3 {
            await player?.seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            await playCurrentTrack()
        } else if repeatMode == .all, items.count > 1 {
            // "Repeat all" wraps forwards from the last track to the first — so backwards too.
            currentIndex = items.count - 1
            await playCurrentTrack()
        }
    }

    func play(at index: Int) async {
        guard items.indices.contains(index) else { return }
        currentIndex = index
        await playCurrentTrack()
    }

    /// Plays an UP-NEXT track by identity — its position is resolved on the spot. Used by the
    /// queue view, where reordering means rows are addressed by value rather than a stable index.
    /// Looks AHEAD of the current track first: when the same song also sits in the played part of
    /// the queue, a tap on its up-next row must not jump back there.
    func play(_ track: Track) async {
        guard let idx = nextIndex(of: track.id) else { return }
        await play(at: idx)
    }

    /// Removes ONE up-next occurrence of `id` (the first). The played part of the queue and the
    /// current track stay — unlike `removeTrack(id:)`, which is for a song deleted from the library.
    func removeUpNext(id: UUID) {
        guard let offset = upNext.firstIndex(where: { $0.id == id }) else { return }
        removeUpNext(at: offset)
    }

    // MARK: - Shuffle / Repeat

    func toggleShuffle() {
        if shuffleMode == .off {
            shuffleMode = .on
            let current = currentTrack
            items = shuffled(keeping: current)
            currentIndex = 0
        } else {
            shuffleMode = .off
            let current = currentTrack
            items = originalOrder
            currentIndex = current.flatMap { c in items.firstIndex(where: { $0.id == c.id }) } ?? 0
        }
        // The immediate next track just changed — drop any stale gapless preload of the old one.
        player?.invalidatePreload()
    }

    /// Re-mixes the upcoming tracks into a fresh random order, leaving the current track and
    /// the already-played history in place so playback continues uninterrupted. Marks the queue
    /// as shuffled so the player's shuffle control reflects the new order. No-op when nothing is
    /// queued ahead.
    func reshuffle() {
        let pivot = currentIndex + 1                 // first "up next" slot (0 when nothing plays)
        guard pivot < items.count else { return }
        shuffleMode = .on

        let upcoming = Array(items[pivot...])
        guard upcoming.count > 1 else { return }     // a single track can't be re-ordered

        var mixed = upcoming.shuffled()
        // Guarantee a visible change for small queues, where a plain shuffle can reproduce the
        // same order (a 2-track tail stays put half the time) — pressing "mix" must do something.
        var attempts = 0
        while attempts < 5, mixed.map(\.id) == upcoming.map(\.id) {
            mixed.shuffle()
            attempts += 1
        }
        items = Array(items[..<pivot]) + mixed
        // `originalOrder` stays the canonical un-shuffled sequence (reshuffle forces shuffle ON, so
        // turning shuffle off should still restore it) — but the freshly mixed tail means the next
        // track changed, so drop any stale gapless preload of the previous one.
        player?.invalidatePreload()
    }

    func toggleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Persistence

    /// Lightweight, file-reference-free snapshot of the queue for cross-launch restore.
    /// Tracks are referenced by their stable UUID and re-resolved against the library on
    /// load, so a track deleted between sessions is simply dropped.
    struct Snapshot: Codable {
        var itemIDs: [UUID]
        var originalIDs: [UUID]
        var currentID: UUID?
        var shuffle: Bool
        var repeatRaw: Int
    }

    func snapshot() -> Snapshot {
        Snapshot(
            itemIDs: items.map(\.id),
            originalIDs: originalOrder.map(\.id),
            currentID: currentTrack?.id,
            shuffle: shuffleMode == .on,
            repeatRaw: repeatMode.rawValue
        )
    }

    /// Rebuilds the queue from a snapshot, resolving UUIDs via `resolve`. Returns false
    /// when nothing usable remains (every referenced track was deleted), leaving the queue
    /// untouched so the caller can skip restoring playback.
    @discardableResult
    func restore(from snap: Snapshot, resolve: (UUID) -> Track?) -> Bool {
        let restoredItems = snap.itemIDs.compactMap(resolve)
        guard !restoredItems.isEmpty else { return false }
        let restoredOriginal = snap.originalIDs.compactMap(resolve)

        items = restoredItems
        originalOrder = restoredOriginal.isEmpty ? restoredItems : restoredOriginal
        shuffleMode = snap.shuffle ? .on : .off
        repeatMode = RepeatMode(rawValue: snap.repeatRaw) ?? .off
        if let cid = snap.currentID, let idx = restoredItems.firstIndex(where: { $0.id == cid }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        return true
    }

    // MARK: - Private

    private func playCurrentTrack() async {
        guard let track = currentTrack else { return }
        await player?.play(track: track)
    }

    private func shuffled(keeping track: Track?) -> [Track] {
        var shuffled = originalOrder.shuffled()
        if let track, let idx = shuffled.firstIndex(where: { $0.id == track.id }) {
            shuffled.remove(at: idx)
            shuffled.insert(track, at: 0)
        }
        return shuffled
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
