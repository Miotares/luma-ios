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

    weak var player: AudioPlayer?

    // MARK: - Computed

    var currentTrack: Track? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var hasNext: Bool {
        switch repeatMode {
        case .all, .one: return !items.isEmpty
        case .off: return currentIndex < items.count - 1
        }
    }

    var hasPrevious: Bool {
        currentIndex > 0 || (player?.currentTime ?? 0) > 3
    }

    var upNext: [Track] {
        guard currentIndex >= 0, currentIndex + 1 < items.count else { return [] }
        return Array(items[(currentIndex + 1)...])
    }

    // MARK: - Queue Operations

    func setQueue(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool? = nil) {
        originalOrder = tracks
        if let shuffle { shuffleMode = shuffle ? .on : .off }
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
    }

    func playNext(_ tracks: [Track]) {
        let insertAt = currentIndex + 1
        items.insert(contentsOf: tracks, at: min(insertAt, items.count))
        originalOrder.insert(contentsOf: tracks, at: min(insertAt, originalOrder.count))
    }

    func remove(at offsets: IndexSet) {
        let currentId = currentTrack?.id
        items.remove(atOffsets: offsets)
        if let id = currentId {
            currentIndex = items.firstIndex(where: { $0.id == id }) ?? max(0, currentIndex - 1)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        let currentId = currentTrack?.id
        items.move(fromOffsets: source, toOffset: destination)
        if let id = currentId {
            currentIndex = items.firstIndex(where: { $0.id == id }) ?? currentIndex
        }
    }

    /// Replaces the upcoming tracks (everything after the current one) with `newUpNext`,
    /// leaving the current track and the already-played history untouched. Backs the queue
    /// view's drag-to-reorder, which edits the up-next slice through a binding.
    func replaceUpNext(with newUpNext: [Track]) {
        let pivot = currentIndex + 1
        guard pivot >= 0, pivot <= items.count else { return }
        items.replaceSubrange(pivot..<items.count, with: newUpNext)
    }

    func clear() {
        items = []
        originalOrder = []
        currentIndex = -1
    }

    /// Drops a track that was just deleted from the library, keeping the current track
    /// stable. Returns true if the removed track was the one currently playing.
    @discardableResult
    func removeTrack(id: UUID) -> Bool {
        let wasCurrent = currentTrack?.id == id
        let keepID = wasCurrent ? nil : currentTrack?.id
        items.removeAll { $0.id == id }
        originalOrder.removeAll { $0.id == id }
        if let keepID {
            currentIndex = items.firstIndex { $0.id == keepID } ?? currentIndex
        } else {
            currentIndex = min(currentIndex, items.count - 1)
        }
        return wasCurrent
    }

    // MARK: - Playback Navigation

    /// Moves the current index forward without (re)starting playback — the AudioPlayer
    /// has already begun the next track as part of a crossfade.
    func advanceIndexForCrossfade() {
        switch repeatMode {
        case .one:
            break
        case .all:
            currentIndex = (currentIndex + 1) % max(items.count, 1)
        case .off:
            if currentIndex < items.count - 1 { currentIndex += 1 }
        }
    }

    func advance() async {
        switch repeatMode {
        case .one:
            await player?.seek(to: 0)
            player?.resume()
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
        if (player?.currentTime ?? 0) > 3 {
            await player?.seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            await playCurrentTrack()
        }
    }

    func play(at index: Int) async {
        guard items.indices.contains(index) else { return }
        currentIndex = index
        await playCurrentTrack()
    }

    /// Plays a track by identity — its position is resolved on the spot. Used by the queue
    /// view, where reordering means rows are addressed by value rather than a stable index.
    func play(_ track: Track) async {
        guard let idx = items.firstIndex(where: { $0.id == track.id }) else { return }
        await play(at: idx)
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
