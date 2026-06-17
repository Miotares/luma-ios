import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Fires a confirmation haptic so a queue-add swipe is perceptible even though it
/// produces no immediate on-screen change.
@MainActor func queueActionHaptic() {
    #if canImport(UIKit)
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    generator.impactOccurred()
    #endif
}

extension View {
    /// Hairline separator beneath a track row. Drawn as an overlay (not the native
    /// list separator) so it spans the row content exactly — with symmetric
    /// `.listRowInsets` this gives equal left/right margins to the screen edge.
    func trackRowSeparator() -> some View {
        self
            .listRowSeparator(.hidden)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.5)
            }
    }

    /// Queue swipe actions on the TRAILING edge only — both "Nächster" and "Ans Ende"
    /// revealed by swiping left. Used in pushed detail views so the LEADING edge stays
    /// free for the interactive back-swipe (which starts from the screen edge).
    func trackQueueSwipeTrailing(
        playNext: @escaping () -> Void,
        addLast: @escaping () -> Void
    ) -> some View {
        self.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                queueActionHaptic()
                playNext()
            } label: {
                Label("Nächster", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            // Readable blue — the app accent is white, which made this white-on-white.
            .tint(Color(red: 0.20, green: 0.48, blue: 0.95))

            Button {
                queueActionHaptic()
                addLast()
            } label: {
                Label("Ans Ende", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(Color(red: 0.20, green: 0.65, blue: 0.35))
        }
    }
}
