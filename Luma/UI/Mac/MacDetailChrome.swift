#if os(macOS)
import SwiftUI

// Shared, desktop-sized chrome for the detail headers (album / artist / playlist / smart list),
// so they read as a native Mac app instead of a stretched phone layout: compact play controls
// and a plain inline options menu — no oversized touch buttons, no floating glass overlay.

/// Compact play/shuffle pill for detail headers. ~32 pt tall with a natural (content-hugging)
/// width, versus the 46–48 pt full-width touch buttons used on iOS. When `iconOnly` it collapses
/// to a 32×32 square showing just the centered glyph — used by `LumaDetailActionBar` on a narrow
/// header so the labels never wrap onto two lines.
struct LumaDetailActionButton: View {
    let label: LocalizedStringKey
    let icon: String
    var primary: Bool = false
    var iconOnly: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .font(.system(size: 13, weight: .semibold))
                .frame(height: 32)
                .background(
                    primary ? Color.lumaAccent : Color.lumaInk(0.1),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.lumaInk(0.14), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(primary ? .lumaOnAccent : .lumaInk())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        if iconOnly {
            // Square icon button — fixed width so the glyph sits centered, same height as the pill.
            Image(systemName: icon)
                .frame(width: 32)
        } else {
            // `lineLimit(1)` + `fixedSize` give the labeled pill a stable single-line width so
            // ViewThatFits can tell when it no longer fits and swap in the icon-only variant
            // (instead of the label wrapping to two lines on a narrow header).
            Label(label, systemImage: icon)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 20)
        }
    }
}

/// Play + Shuffle + options "…" for a detail header, left-aligned. On a wide header the two pills
/// show their labels; when the header gets too narrow (e.g. the queue inspector is open on a small
/// window) BOTH pills collapse together to icon-only squares via ViewThatFits — so the text never
/// wraps onto two lines. The options menu and the trailing Spacer (left-align) are unchanged.
struct LumaDetailActionBar<MenuContent: View>: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                pair(iconOnly: false)
                pair(iconOnly: true)
            }
            LumaDetailOptionsMenu { menu() }
            Spacer(minLength: 0)
        }
    }

    private func pair(iconOnly: Bool) -> some View {
        HStack(spacing: 12) {
            LumaDetailActionButton(label: "Abspielen", icon: "play.fill", primary: true,
                                   iconOnly: iconOnly, action: onPlay)
            LumaDetailActionButton(label: "Shuffle", icon: "shuffle",
                                   iconOnly: iconOnly, action: onShuffle)
        }
    }
}

/// Plain inline "…" options menu for a detail header — a small flat circle, not a floating
/// glass overlay. The caller supplies the menu items.
struct LumaDetailOptionsMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.lumaInk(0.7))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .background(Color.lumaInk(0.08), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
#endif
