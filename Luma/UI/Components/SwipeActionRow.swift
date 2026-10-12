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
    func trackRowSeparator(showsLine: Bool = true) -> some View {
        self
            .listRowSeparator(.hidden)
            .overlay(alignment: .bottom) {
                // Dropped between two selected rows so a multi-row selection reads as one seamless
                // block (no hairline cutting through it).
                if showsLine {
                    Rectangle()
                        .fill(Color.lumaInk(0.07))
                        .frame(height: 0.5)
                }
            }
    }

    /// Floor height for a song row. macOS gets a tighter, Apple-Music-dense list; iOS keeps the
    /// touch-friendly height. Pass the iOS value — macOS shaves a few points off it. Keeping this
    /// in one place means every song list shrinks consistently on macOS without touching iOS.
    func lumaSongRowMinHeight(_ ios: CGFloat) -> some View {
        #if os(macOS)
        frame(minHeight: ios - 8)
        #else
        frame(minHeight: ios)
        #endif
    }

    /// macOS selection highlight, drawn as a FULL-CELL `.listRowBackground` so consecutive selected
    /// rows touch and read as ONE block. `UnevenRoundedRectangle` rounds only the block's outer
    /// corners: a corner stays square when the neighbouring row on that side is also selected, so a
    /// run renders rounded-top on the first row, rounded-bottom on the last, square in between; a lone
    /// selected row keeps all four corners. iOS draws nothing here (it uses the row's checkmark circle).
    func trackSelectionRowBackground(isSelected: Bool, selectedAbove: Bool, selectedBelow: Bool) -> some View {
        #if os(macOS)
        let r: CGFloat = 9
        return listRowBackground(
            Group {
                if isSelected {
                    UnevenRoundedRectangle(
                        topLeadingRadius: selectedAbove ? 0 : r,
                        bottomLeadingRadius: selectedBelow ? 0 : r,
                        bottomTrailingRadius: selectedBelow ? 0 : r,
                        topTrailingRadius: selectedAbove ? 0 : r,
                        style: .continuous
                    )
                    .fill(Color.lumaInk(0.16))
                    // listRowBackground fills the WHOLE row cell, but the current/hover pill is drawn
                    // in-content at `listRowInsets + 8pt overhang`. macOS plain-List adds an asymmetric
                    // leading content inset, so these empirically-matched insets line the block up to
                    // exactly the same width/position as the current-track pill (leading 27 / trailing 17).
                    .padding(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 17))
                } else {
                    Color.clear
                }
            }
        )
        #else
        return listRowBackground(Color.clear)
        #endif
    }

    /// macOS: a click on this view — an album/playlist header or footer, i.e. anywhere OUTSIDE the
    /// song rows — clears the current song selection (Finder/Music behaviour). No-op on iOS, which
    /// uses an explicit tap-to-select mode. `contentShape` makes the whole area clickable; embedded
    /// Buttons / links still capture their own clicks first.
    @ViewBuilder
    func clearSongSelectionOnTap(_ clear: @escaping () -> Void) -> some View {
        #if os(macOS)
        contentShape(Rectangle()).onTapGesture(perform: clear)
        #else
        self
        #endif
    }

    /// Queue swipe actions on the TRAILING edge only — both "Nächster" and "Ans Ende"
    /// revealed by swiping left. Used in pushed detail views so the LEADING edge stays
    /// free for the interactive back-swipe (which starts from the screen edge).
    ///
    /// iOS only: on macOS swipe is a hidden trackpad gesture, so these same two actions are
    /// reached through the row's right-click context menu (TrackRow's "Nächster Titel" /
    /// "Zuletzt wiedergeben"). This becomes a no-op on macOS.
    @ViewBuilder
    func trackQueueSwipeTrailing(
        playNext: @escaping () -> Void,
        addLast: @escaping () -> Void
    ) -> some View {
        #if os(iOS) || os(visionOS)
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
        #else
        self
        #endif
    }

    /// Single trailing destructive swipe — used by the queue's up-next rows to drop a track.
    /// iOS only; on macOS the same action is the hover-✕ / right-click "Aus … entfernen".
    @ViewBuilder
    func lumaQueueRemoveSwipe(_ remove: @escaping () -> Void) -> some View {
        #if os(iOS) || os(visionOS)
        self.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                remove()
            } label: {
                Label("Entfernen", systemImage: "minus.circle")
            }
            .tint(.red)
        }
        #else
        self
        #endif
    }
}
