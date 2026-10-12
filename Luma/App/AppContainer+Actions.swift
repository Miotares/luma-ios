import Foundation

// Queue / playlist actions that change nothing visible where they're triggered (a context menu,
// a swipe, a selection bar). Views call these instead of the queue/repository directly so every
// entry point confirms with the same toast.
extension AppContainer {
    /// With nothing playing (fresh start, or the queue ran out and the player closed) there is no
    /// queue to add to: the tracks would sit in an invisible list and be thrown away by the next
    /// song the user taps — while the toast claimed they were queued. Start playing them instead.
    private func startPlaybackIfIdle(with tracks: [Track]) -> Bool {
        guard !player.isActive else { return false }
        queue.setQueue(tracks, startAt: 0)
        Task { await player.play(track: tracks[0]) }
        toast.show(String(localized: "Wiedergabe gestartet"), systemImage: "play.fill")
        return true
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty, !startPlaybackIfIdle(with: tracks) else { return }
        queue.playNext(tracks)
        savePlaybackState()   // the changed queue should survive a relaunch right away
        toast.show(
            tracks.count == 1
                ? String(localized: "Wird als Nächstes gespielt")
                : String(localized: "\(tracks.count) Titel werden als Nächstes gespielt"),
            systemImage: "text.line.first.and.arrowtriangle.forward"
        )
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty, !startPlaybackIfIdle(with: tracks) else { return }
        queue.append(tracks)
        savePlaybackState()
        toast.show(
            tracks.count == 1
                ? String(localized: "Zur Warteschlange hinzugefügt")
                : String(localized: "\(tracks.count) Titel zur Warteschlange hinzugefügt"),
            systemImage: "text.line.last.and.arrowtriangle.forward"
        )
    }

    func addToPlaylist(_ tracks: [Track], _ playlist: Playlist) {
        guard !tracks.isEmpty else { return }
        let name = playlist.name
        guard let added = try? library.addTracks(tracks, to: playlist) else {
            toast.show(String(localized: "Hinzufügen fehlgeschlagen"), systemImage: "exclamationmark.triangle")
            return
        }
        switch added {
        case 0:
            toast.show(String(localized: "Bereits in „\(name)“"), systemImage: "checkmark")
        case 1:
            toast.show(String(localized: "Zu „\(name)“ hinzugefügt"), systemImage: "text.badge.plus")
        default:
            toast.show(String(localized: "\(added) Titel zu „\(name)“ hinzugefügt"), systemImage: "text.badge.plus")
        }
    }

    /// Confirms a finished import where the import sheet isn't visible to do it (closed while a
    /// long import ran, or the files came in via "Open in Luma" / drag & drop).
    func announceImportResult() {
        guard !importManager.isPresentingUI, let report = importManager.lastReport else { return }
        if report.imported > 0 {
            toast.show(String(localized: "\(report.imported) Titel importiert"), systemImage: "checkmark")
        } else if !report.failures.isEmpty {
            toast.show(String(localized: "Import fehlgeschlagen"), systemImage: "exclamationmark.triangle")
        } else if report.unsupported > 0 {
            toast.show(String(localized: "Format nicht unterstützt"), systemImage: "exclamationmark.triangle")
        } else if report.alreadyPresent > 0 {
            toast.show(String(localized: "Bereits in der Mediathek"), systemImage: "checkmark")
        }
    }

    /// Bulk like from a multi-selection. (A single like needs no toast — the heart is the feedback.)
    func like(_ tracks: [Track]) {
        guard !tracks.isEmpty, let changed = try? library.setLiked(tracks, liked: true) else { return }
        toast.show(
            changed == 0
                ? String(localized: "Bereits in Liked")
                : String(localized: "\(changed) Titel zu Liked hinzugefügt"),
            systemImage: "heart.fill"
        )
    }
}
