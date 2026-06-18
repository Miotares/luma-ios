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
}

// MARK: - Gallery grid columns

/// Album / playlist gallery columns: 4 across on macOS (wide window), 2 on iOS.
#if os(macOS)
let lumaGalleryColumnCount = 4
#else
let lumaGalleryColumnCount = 2
#endif

func lumaGalleryColumns(spacing: CGFloat) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: spacing), count: lumaGalleryColumnCount)
}
