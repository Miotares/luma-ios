import SwiftUI
import Observation

/// Short-lived confirmation ("Zur Warteschlange hinzugefügt") for actions that otherwise change
/// nothing on screen. One toast at a time: a new one replaces the current one and restarts the
/// timer, so a burst of actions never stacks up.
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String = "checkmark") {
        dismissTask?.cancel()
        current = Toast(message: message, systemImage: systemImage)
        AccessibilityNotification.Announcement(message).post()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

extension View {
    /// Shows the app's toasts over this view. Attach to every presentation ROOT that can trigger
    /// one — an overlay on the tab view sits UNDER a sheet, so the player sheet hosts its own.
    /// `forceDark` is for surfaces that are dark regardless of the app appearance (the player).
    func lumaToastHost(forceDark: Bool = false) -> some View {
        modifier(ToastHost(forceDark: forceDark))
    }
}

private struct ToastHost: ViewModifier {
    @Environment(AppContainer.self) private var app
    let forceDark: Bool

    private var showsImportProgress: Bool {
        app.importManager.isImporting && !app.importManager.isPresentingUI
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ZStack {
                if let toast = app.toast.current {
                    ToastCapsule(toast: toast, forceDark: forceDark)
                        .id(toast.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if showsImportProgress {
                    // An import running in the background (sheet closed, "Open in Luma", drop)
                    // stays visible here until it's done.
                    ImportProgressCapsule(forceDark: forceDark)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 2)
            .padding(.horizontal, 24)
            .animation(.smooth(duration: 0.28), value: app.toast.current)
            .animation(.smooth(duration: 0.28), value: showsImportProgress)
            // Purely informational — never swallow a tap meant for the header underneath.
            .allowsHitTesting(false)
        }
    }
}

private struct ToastCapsule: View {
    let toast: ToastCenter.Toast
    let forceDark: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(toast.message)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(forceDark ? Color.white : Color.lumaInk())
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityHidden(true)   // already announced by ToastCenter.show
    }
}

/// Live "Importiere 120 / 900" pill. Its own view so the per-file count re-renders only this.
private struct ImportProgressCapsule: View {
    @Environment(AppContainer.self) private var app
    let forceDark: Bool

    var body: some View {
        let manager = app.importManager
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(manager.isScanning || manager.totalCount == 0
                 ? String(localized: "Import wird vorbereitet …")
                 : String(localized: "Importiere \(manager.importedCount) / \(manager.totalCount)"))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(forceDark ? Color.white : Color.lumaInk())
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}
