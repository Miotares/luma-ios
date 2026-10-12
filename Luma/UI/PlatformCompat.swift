import SwiftUI

// Cross-platform shims so the shared SwiftUI views compile on macOS, where several
// iOS-only navigation/toolbar modifiers don't exist. On iOS each forwards to the
// exact same modifier (behavior unchanged); on macOS it is a no-op.
extension View {
    /// iOS: `.navigationBarTitleDisplayMode(.inline)`. macOS: no-op.
    @ViewBuilder func lumaInlineNavTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// iOS: `.navigationBarBackButtonHidden(true)`. macOS: no-op (custom back chrome).
    @ViewBuilder func lumaHideBackButton() -> some View {
        #if os(iOS)
        navigationBarBackButtonHidden(true)
        #else
        self
        #endif
    }

    /// iOS: `.toolbarVisibility(.hidden, for: .navigationBar)`. macOS: no-op.
    @ViewBuilder func lumaHideNavBar() -> some View {
        #if os(iOS)
        toolbarVisibility(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// iOS: `.toolbarBackground(.hidden, for: .navigationBar)`. macOS: no-op.
    @ViewBuilder func lumaHiddenNavBarBackground() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// iOS: `.toolbarBackground(Color.lumaBackground, for: .navigationBar)`. macOS: no-op.
    @ViewBuilder func lumaDarkNavBackground() -> some View {
        #if os(iOS)
        toolbarBackground(Color.lumaBackground, for: .navigationBar)
        #else
        self
        #endif
    }

    /// iOS: `.toolbarColorScheme(.dark, for: .navigationBar)`. macOS: no-op.
    @ViewBuilder func lumaDarkNavScheme() -> some View {
        #if os(iOS)
        toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    /// macOS: a toolbar search field that filters the songs of a detail list (album / playlist).
    /// iOS: no-op — the iOS detail views are intentionally left unchanged. `text` is bound on both
    /// platforms so the call site compiles cross-platform; on iOS nothing is shown, so the bound
    /// text stays empty and the shared filtering below is a no-op there.
    @ViewBuilder func lumaDetailSongSearch(_ text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        #if os(macOS)
        searchable(text: text, placement: .toolbar, prompt: prompt)
        #else
        self
        #endif
    }
}

// MARK: - Gallery grid columns

/// Album / playlist gallery columns. macOS is width-responsive (`.adaptive`) so a resized
/// window flows more or fewer cards instead of stretching a fixed 4 — the desktop expectation.
/// iOS stays a fixed 2-up grid sized for the phone.
#if os(macOS)
let lumaGalleryColumnCount = 4   // retained for callers that need a nominal count
#else
let lumaGalleryColumnCount = 2
#endif

func lumaGalleryColumns(spacing: CGFloat) -> [GridItem] {
    #if os(macOS)
    return [GridItem(.adaptive(minimum: 156, maximum: 220), spacing: spacing)]
    #else
    return Array(repeating: GridItem(.flexible(), spacing: spacing), count: lumaGalleryColumnCount)
    #endif
}
