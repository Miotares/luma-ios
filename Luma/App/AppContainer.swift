import Foundation
import SwiftData
import Observation

@Observable
final class AppContainer {
    let player: AudioPlayer
    let queue: PlaybackQueue
    let importManager: ImportManager
    let library: LibraryRepository
    private(set) var currentPalette: ColorPalette?

    private let remoteCommands: RemoteCommandHandler

    init(modelContext: ModelContext) {
        let p = AudioPlayer()
        let q = PlaybackQueue()

        p.queue = q
        q.player = p

        self.player = p
        self.queue = q
        self.importManager = ImportManager(modelContext: modelContext)
        let lib = LibraryRepository(context: modelContext)
        self.library = lib
        self.remoteCommands = RemoteCommandHandler(player: p, queue: q)

        // Seed listening time from existing completed plays (one-time) so the new
        // stats reflect history instead of starting from zero.
        lib.seedListenSecondsIfNeeded()

        p.onTrackComplete = { track in
            try? lib.recordPlay(track: track)
        }

        p.onListened = { track, seconds in
            lib.addListenTime(to: track, seconds: seconds)
        }

        p.onTrackChanged = { [weak self] track in
            guard let self else { return }
            let artworkData = track.album?.artworkData
            let paletteId = track.album?.id ?? track.id
            Task {
                self.currentPalette = await PaletteExtractor.shared.palette(for: paletteId, imageData: artworkData)
            }
        }
    }
}
