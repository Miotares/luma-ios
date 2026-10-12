import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

/// A context-specific destructive action for a row — "remove from queue", "remove from
/// playlist", … — distinct from the library-wide "delete track". When set on a `TrackRow`
/// it is injected into the row's own context menu (so right-click / long-press exposes it)
/// and, on macOS, surfaced as a hover-revealed trailing button — the native quick action
/// that replaces iOS swipe-to-remove.
struct TrackRowRemove {
    let label: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
}

/// How a macOS single click should mutate the song selection — decided by the modifier keys held.
/// Mirrors Finder/Music: a plain click replaces, ⌘ toggles one, ⇧ extends a contiguous range.
enum TrackSelectGesture {
    case replace
    case toggle
    case range
}

struct TrackRow: View, Equatable {
    let track: Track
    var showArtwork: Bool = false
    var showArtistName: Bool = true
    var showAlbum: Bool = false
    var showsMenu: Bool = false
    /// Shows a trailing drag-handle glyph (≡) that hints the row can be dragged to reorder.
    /// Purely a visual affordance — the actual reordering is driven by the List's `editActions`,
    /// which makes the whole row draggable (so grabbing the handle works too).
    var showsDragHandle: Bool = false
    /// When true the row shows a leading selection circle and its tap is expected to
    /// toggle membership (the parent owns the actual selection set). Other affordances
    /// (trailing menu, context menu) are suppressed by the caller while selecting.
    var selectionMode: Bool = false
    var isSelected: Bool = false
    /// Playback-derived state, passed in by the parent (NOT read from `app.player` inside the
    /// row). Reading the player here subscribed EVERY row to playback, so starting a track
    /// re-ran all ~1500 row bodies (a multi-second freeze). With these as plain values + the
    /// `Equatable` conformance below, `.equatable()` lets SwiftUI skip every row whose inputs
    /// didn't change — so a track change re-renders only the 2 affected rows.
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    /// Snapshot of `track.isLiked` (a value, so Equatable can detect a like toggling).
    var liked: Bool = false
    /// Context-specific remove (from queue / playlist). Adds an item to the row's menu and,
    /// on macOS, a hover-revealed trailing button. Library-wide delete stays separate.
    var remove: TrackRowRemove? = nil
    /// Set false to suppress the row's built-in right-click menu — used where the parent provides
    /// a selection-aware context menu instead (e.g. the macOS album multi-select).
    var showsContextMenu: Bool = true
    /// macOS: explicit play — fired by a double-click on the row and by the hover play glyph. Kept
    /// separate from `onTap` so a single click can SELECT while a double-click still PLAYS.
    var onPlay: (() -> Void)? = nil
    /// macOS: single-click selection. The parent gets the modifier-derived gesture (replace / toggle /
    /// range) and mutates its selection set. When nil the row isn't selectable. iOS keeps `onTap`.
    var onSelect: ((TrackSelectGesture) -> Void)? = nil
    /// Primary action: iOS tap (play, or toggle in selection mode); macOS fallback when no `onSelect`.
    /// All call sites pass this with an explicit `onTap:` label — never a bare trailing closure — so
    /// binding is unambiguous regardless of declaration order / Swift language mode (a bare trailing
    /// closure would forward-match to `onPlay` under Swift 6 and silently leave this nil).
    var onTap: (() -> Void)?

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var modelContext

    @State private var showMetadataEditor = false
    @State private var showDeleteConfirm = false
    @State private var isHovered = false

    // Compared by `.equatable()` — closures and @State are intentionally excluded. Title/artist
    // edits are rare and refresh on navigation; the keys here cover everything that changes live.
    static func == (l: TrackRow, r: TrackRow) -> Bool {
        l.track.persistentModelID == r.track.persistentModelID &&
        l.isCurrent == r.isCurrent && l.isPlaying == r.isPlaying && l.liked == r.liked &&
        l.selectionMode == r.selectionMode && l.isSelected == r.isSelected &&
        l.showArtwork == r.showArtwork && l.showAlbum == r.showAlbum &&
        l.showArtistName == r.showArtistName && l.showsMenu == r.showsMenu &&
        l.showsDragHandle == r.showsDragHandle
    }

    /// Cover thumbnail size — tighter on macOS so more songs fit per page (Apple-Music density);
    /// iOS keeps the larger touch-friendly cover.
    private var coverSize: CGFloat {
        #if os(macOS)
        36
        #else
        44
        #endif
    }
    /// Row vertical breathing room — tighter on macOS.
    private var rowVPad: CGFloat {
        #if os(macOS)
        3
        #else
        7
        #endif
    }
    /// Title size — a notch smaller on macOS so song lists read denser (Apple-Music style).
    private var titleSize: CGFloat {
        #if os(macOS)
        14
        #else
        16
        #endif
    }
    private var subtitleSize: CGFloat {
        #if os(macOS)
        12
        #else
        13
        #endif
    }
    private var durationSize: CGFloat {
        #if os(macOS)
        13
        #else
        14
        #endif
    }
    private var trackNumberSize: CGFloat {
        #if os(macOS)
        14
        #else
        16
        #endif
    }

    // MARK: - Row highlight (current / hover)

    /// macOS-only selected flag. The SELECTED fill is NOT drawn here — the parent draws it as a
    /// full-cell `.listRowBackground` block (so consecutive selected rows merge into one block with
    /// only the outer corners rounded). Here it just SUPPRESSES the current/hover pill so a selected
    /// row shows the clean block, not a pill on top of it. iOS shows the leading checkmark circle.
    private var isMacSelected: Bool {
        #if os(macOS)
        isSelected
        #else
        false
        #endif
    }
    /// The current-track and hover pills keep the inset ±8pt overhang. Suppressed while selected.
    private var rowHasHighlight: Bool { !isMacSelected && (isCurrent || isHovered) }
    private var rowHighlightColor: Color {
        if isMacSelected { return .clear }           // selection block is the List row background
        if isCurrent { return Color.lumaInk(0.07) }
        if isHovered { return Color.lumaInk(0.05) }
        return .clear
    }

    var body: some View {
        let isCurrentTrack = isCurrent
        // `Menu { }` and `.contextMenu { }` take NON-escaping builders, so their content is built
        // during THIS body pass (not when the menu opens). Fetch the playlists once here and hand
        // them to both, instead of each builder running its own fetch on every row body.
        let menuPlaylists = (showsMenu || (!selectionMode && showsContextMenu)) ? fetchMenuPlaylists() : []

        HStack(spacing: 4) {
            // A plain tap gesture rather than a Button: TapGesture cancels the moment the
            // finger moves, so a swipe-to-remove attempt that falls short of the swipe
            // threshold no longer fires as a tap on finger-up (which wrongly started playback
            // in the always-edit-mode queue). A Button's looser touch slop let that through.
            // It also sidesteps the macOS "first click needs the list focused" Button quirk.
            rowLabel(isCurrentTrack: isCurrentTrack)
                .contentShape(Rectangle())
                #if os(iOS) || os(visionOS)
                .onTapGesture { onTap?() }
                #endif
                .accessibilityAddTraits(.isButton)
            // macOS selection click lives on the WHOLE row (below), so the entire hover rectangle
            // is the hit target — not just this title line. Removal is right-click only now (the
            // hover-✕ button was removed); the context menu still carries the remove action.

            if showsMenu {
                Menu {
                    menuContent(menuPlaylists)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.lumaInk(0.45))
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.lumaInk(0.3))
                    .frame(width: 28, height: 44)
                    .accessibilityHidden(true)
            }
        }
        // Vertical breathing room so the active/hover highlight pill isn't flush with the
        // 44pt artwork — the cover (and text) get a few points of clearance to the pill's
        // top & bottom edges instead of touching them. Unlike the horizontal overhang below,
        // this is NOT cancelled out: rows here sit flush (listRowInsets top/bottom = 0), so a
        // negative-padding overhang would bleed the translucent pill onto the neighbour row.
        // Applying real padding to EVERY row (not just the current one) keeps all rows the
        // same height, so making a track current never shifts its row taller / jumps the list.
        .padding(.vertical, rowVPad)
        // The pill overhangs the row by 8pt each side (added here, cancelled by the negative padding
        // below so layout width is unchanged). Selection, current-track and hover all share this 8pt
        // overhang so every highlighted row's box is exactly the same width — the macOS selection pill
        // lines up with the hover box instead of bleeding full-width like the old native blue bar.
        .padding(.horizontal, rowHasHighlight ? 8 : 0)
        .background(rowHighlightColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, rowHasHighlight ? -8 : 0)
        .onHover { isHovered = $0 }
        #if os(macOS)
        // Selection click on the ENTIRE row (full height incl. the vertical breathing room), so a
        // click anywhere in the hover rectangle selects — not only the title/cover line. clickCount
        // disambiguates single (select, ⇧ = range) vs double (play); the inner controls (play glyph,
        // ⋯ menu, drag handle) are child Buttons and still take their own clicks.
        .contentShape(Rectangle())
        .onTapGesture { handleMacClick() }
        #endif
        .lumaApplyIf(!selectionMode && showsContextMenu) { $0.contextMenu { menuContent(menuPlaylists) } }
        .sheet(isPresented: $showMetadataEditor) {
            MetadataEditorView(track: track)
        }
        .alert("Titel löschen?", isPresented: $showDeleteConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) {
                try? app.library.delete(track: track)
            }
        } message: {
            Text("\"\(track.title)\" wird endgültig aus der Mediathek entfernt.")
        }
    }

    #if os(macOS)
    /// Routes a row click read from the live AppKit event (clickCount disambiguates single vs double in
    /// one gesture, so single-click selection stays instant):
    /// - Selectable rows (onSelect set — album/playlist): a single click selects per its modifiers —
    ///   plain replaces (just this song), ⌘ toggles one in/out, ⇧ extends a range from the anchor.
    ///   A double-click plays (its first click already replace-selected the row, Finder-style).
    /// - Plain rows (no onSelect — library/queue/search/…): unchanged — double-click plays, a single
    ///   click does nothing (the hover play glyph stays the one-click way to play).
    private func handleMacClick() {
        let doubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
        if let onSelect {
            if doubleClick {
                (onPlay ?? onTap)?()
            } else {
                let mods = NSEvent.modifierFlags
                let gesture: TrackSelectGesture = mods.contains(.shift) ? .range
                    : (mods.contains(.command) ? .toggle : .replace)
                onSelect(gesture)
            }
        } else if doubleClick {
            (onPlay ?? onTap)?()
        }
    }
    #endif

    /// Song artist from the track's own metadata (includes features); falls back to
    /// the album artist when the track has no song-artist tag.
    private var subtitleArtist: String {
        let a = track.artistName.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { return a }
        return (track.album?.artistName ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func rowLabel(isCurrentTrack: Bool) -> some View {
        HStack(spacing: 12) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? Color.lumaAccent : .lumaInk(0.30))
                    .transition(.scale.combined(with: .opacity))
            }
            leadingView(isCurrentTrack: isCurrentTrack)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: titleSize))
                    .tracking(-0.25)
                    .foregroundStyle(.lumaInk())
                    .fontWeight(isCurrentTrack ? .bold : .regular)
                    .lineLimit(1)
                if showArtistName, !subtitleArtist.isEmpty {
                    // "Artist — Album" (em dash, Apple-Music style) when the album is shown.
                    Text(showAlbum && !track.albumTitle.isEmpty
                         ? "\(subtitleArtist) — \(track.albumTitle)"
                         : subtitleArtist)
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(.lumaInk(0.5))
                        .lineLimit(1)
                }
            }

            Spacer()

            if liked {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.lumaInk())
            }

            Text(track.formattedDuration)
                .font(.system(size: durationSize).monospacedDigit())
                .tracking(0.2)
                .foregroundStyle(.lumaInk(0.35))
        }
    }

    // MARK: - Shared Menu

    /// One plain fetch per row body (see `body`) — NOT a per-row @Query, which meant thousands of
    /// live queries that all re-ran on every context save.
    private func fetchMenuPlaylists() -> [Playlist] {
        (try? modelContext.fetch(
            FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
    }

    @ViewBuilder
    private func menuContent(_ playlists: [Playlist]) -> some View {
        Button {
            app.playNext([track])
        } label: {
            Label("Nächster Titel", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            app.addToQueue([track])
        } label: {
            Label("Zuletzt wiedergeben", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        app.addToPlaylist([track], playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zu Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }

        Button {
            try? app.library.toggleLike(track: track)
        } label: {
            Label(
                track.isLiked ? "Aus Liked entfernen" : "Zu Liked hinzufügen",
                systemImage: track.isLiked ? "heart.slash" : "heart"
            )
        }

        Button {
            showMetadataEditor = true
        } label: {
            Label("Informationen bearbeiten", systemImage: "pencil")
        }

        if let remove {
            Divider()
            Button(role: .destructive, action: remove.action) {
                Label(remove.label, systemImage: remove.systemImage)
            }
        }

        Divider()

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Titel löschen", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .tint(.red)

        Button("Abbrechen", role: .cancel) {}
    }

    @ViewBuilder
    private func leadingView(isCurrentTrack: Bool) -> some View {
        if showArtwork {
            ZStack {
                ArtworkView(data: track.resolvedArtworkData(), cacheKey: track.artworkCacheKey, cornerRadius: 6, size: coverSize)
                if isCurrentTrack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.5))
                        .frame(width: coverSize, height: coverSize)
                    NowPlayingGlyph(isActive: isPlaying && app.player.isForeground,
                                    size: 16, weight: .medium, tint: .white)
                } else if isHovered && !selectionMode {
                    // macOS hover: a one-click play button over the cover (double-clicking the row
                    // still plays too — both gestures coexist). The button fills the full cover so a
                    // single click anywhere on it plays.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: coverSize, height: coverSize)
                    hoverPlayButton(glyph: 16, hit: CGSize(width: coverSize, height: coverSize), tint: .white)
                }
            }
        } else {
            Group {
                if isCurrentTrack {
                    NowPlayingGlyph(isActive: isPlaying && app.player.isForeground,
                                    size: 13, tint: .lumaAccent)
                } else if isHovered && !selectionMode {
                    // macOS hover: the track number becomes a one-click play button filling the
                    // whole number cell, so the click target is the full slot, not the tiny glyph.
                    hoverPlayButton(glyph: 13, hit: CGSize(width: 34, height: 36), tint: .lumaInk())
                } else {
                    Text(track.trackNumber > 0 ? "\(track.trackNumber)" : "–")
                        .font(.system(size: trackNumberSize))
                        .foregroundStyle(.lumaInk(0.38))
                }
            }
            .frame(width: 34, alignment: .center)
        }
    }

    /// One-click play affordance revealed on hover (macOS). Fires the same action as the row's
    /// double-click, so both ways of starting a track coexist. The hit area fills the whole leading
    /// slot (cover / track-number cell) — the bare glyph was only a ~16pt target, so a single click
    /// often landed just outside it and didn't register (the "playing needs more than one click,
    /// the hitbox is tiny" report). `contentShape` over the full frame makes the whole slot click.
    private func hoverPlayButton(glyph: CGFloat, hit: CGSize, tint: Color) -> some View {
        Button(action: { (onPlay ?? onTap)?() }) {
            Image(systemName: "play.fill")
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: hit.width, height: hit.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wiedergabe")
    }
}
