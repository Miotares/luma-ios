#if os(macOS)
import AppKit

/// Minimal app delegate so the Dock icon gets a right-click menu with transport controls —
/// a native expectation that SwiftUI doesn't expose declaratively. Reads the shared player
/// and queue via `AppContainer.shared`.
final class LumaAppDelegate: NSObject, NSApplicationDelegate {

    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let app = AppContainer.shared, app.player.currentTrack != nil else { return nil }
        let menu = NSMenu()

        let playPause = NSMenuItem(
            title: app.player.state.isPlaying ? "Pause" : "Wiedergabe",
            action: #selector(togglePlayPause), keyEquivalent: "")
        playPause.target = self
        menu.addItem(playPause)

        let next = NSMenuItem(title: "Nächster Titel", action: #selector(playNext), keyEquivalent: "")
        next.target = self
        menu.addItem(next)

        let prev = NSMenuItem(title: "Vorheriger Titel", action: #selector(playPrevious), keyEquivalent: "")
        prev.target = self
        menu.addItem(prev)

        return menu
    }

    @MainActor @objc private func togglePlayPause() {
        _ = AppContainer.shared?.player.togglePlayPause()
    }

    @MainActor @objc private func playNext() {
        guard let app = AppContainer.shared else { return }
        Task { await app.queue.advance() }
    }

    @MainActor @objc private func playPrevious() {
        guard let app = AppContainer.shared else { return }
        Task { await app.queue.playPrevious() }
    }
}
#endif
