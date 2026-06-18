#if os(macOS)
import SwiftUI
import AppKit

/// macOS menu-bar commands wired to the shared player/queue and the watched-folder library.
struct LumaCommands: Commands {
    let app: AppContainer

    var body: some Commands {
        // Replace the document-oriented "New" items the app doesn't use.
        CommandGroup(replacing: .newItem) {
            Button("Musikordner hinzufügen…") { addFolders() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Bibliothek neu scannen") { app.rescan() }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu("Wiedergabe") {
            Button(app.player.state.isPlaying ? "Pause" : "Wiedergabe") {
                app.player.togglePlayPause()
            }
            Button("Nächster Titel") { Task { await app.queue.advance() } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Vorheriger Titel") { Task { await app.queue.playPrevious() } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Auswählen"
        panel.message = "Musikordner auswählen"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { app.libraryFolders.add(url) }
        app.rescan()
    }
}
#endif
