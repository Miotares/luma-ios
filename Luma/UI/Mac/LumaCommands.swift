#if os(macOS)
import SwiftUI
import AppKit

/// macOS menu-bar commands wired to the shared player/queue and the watched-folder library,
/// plus View-menu navigation that drives the same window as the sidebar (`MacNavigationState`).
struct LumaCommands: Commands {
    let app: AppContainer
    @Bindable var nav: MacNavigationState

    var body: some Commands {
        // Replace the document-oriented "New" items the app doesn't use.
        CommandGroup(replacing: .newItem) {
            Button("Musikordner hinzufügen…") { addFolders() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Bibliothek neu scannen") { app.rescan() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Playlists importieren…") { nav.showingPlaylistImporter = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Alle Playlists exportieren…") {
                nav.playlistExportRequest = PlaylistExportRequest(playlistID: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        // Einstellungen + Statistiken live only in the menu bar now (removed from the sidebar):
        // the native ⌘, Settings item, plus the "Ansicht" menu below (⌘4 Statistiken / ⌘5
        // Einstellungen, via MacSection.allCases).
        CommandGroup(replacing: .appSettings) {
            Button("Einstellungen…") { nav.select(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        // MARK: Playback
        CommandMenu("Wiedergabe") {
            // The player-dependent items live in their own View so a play/pause or track change
            // re-renders just these items. Reading `app.player` directly in THIS `body` made every
            // such change re-evaluate (and re-bridge to AppKit) the entire menu bar.
            TransportCommandItems(app: app)

            Divider()

            Toggle("Zufällig", isOn: Binding(
                get: { app.queue.shuffleMode == .on },
                set: { _ in app.queue.toggleShuffle() }
            ))
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Picker("Wiederholen", selection: Binding(
                get: { app.queue.repeatMode },
                set: { app.queue.repeatMode = $0 }
            )) {
                Text("Aus").tag(PlaybackQueue.RepeatMode.off)
                Text("Alle").tag(PlaybackQueue.RepeatMode.all)
                Text("Titel").tag(PlaybackQueue.RepeatMode.one)
            }

            Divider()

            Button("Equalizer…") { nav.showingEqualizer = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }

        // MARK: View — sidebar sections + queue, sharing the window's navigation state.
        CommandMenu("Ansicht") {
            ForEach(MacSection.allCases) { section in
                Button(section.title) { nav.select(section) }
                    .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command)
            }
            Divider()
            QueueToggleCommandItem(nav: nav)
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

/// Play/pause + skip items of the "Wiedergabe" menu — isolated so only they observe the player.
private struct TransportCommandItems: View {
    let app: AppContainer

    var body: some View {
        let hasTrack = app.player.currentTrack != nil
        Button(app.player.state.isPlaying ? "Pause" : "Wiedergabe") {
            _ = app.player.togglePlayPause()
        }
        .disabled(!hasTrack)

        Button("Nächster Titel") { Task { await app.queue.advance() } }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!hasTrack)
        Button("Vorheriger Titel") { Task { await app.queue.playPrevious() } }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!hasTrack)

        Button("15 Sekunden vor") { app.player.skipForward() }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(!hasTrack)
        Button("15 Sekunden zurück") { app.player.skipBackward() }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(!hasTrack)
    }
}

/// "Warteschlange ein-/ausblenden" — isolated so only this item observes the inspector flag.
private struct QueueToggleCommandItem: View {
    let nav: MacNavigationState

    var body: some View {
        Button(nav.showingQueue ? "Warteschlange ausblenden" : "Warteschlange einblenden") {
            nav.showingQueue.toggle()
        }
        .keyboardShortcut("q", modifiers: [.command, .option])
    }
}
#endif
