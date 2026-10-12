import SwiftUI

struct QueueView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(MacNavigationState.self) private var macNav
    #endif

    private var upNext: [Track] { app.queue.upNext }

    var body: some View {
        VStack(spacing: 0) {
            queueHeader
            queueList
        }
        .background(Color.lumaBackground.ignoresSafeArea())
    }

    // MARK: - Header

    private var queueHeader: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Warteschlange")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.lumaInk())
                Spacer()

                #if os(iOS)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.lumaInk(0.85))
                        .frame(width: 30, height: 30)
                        .background(Color.lumaInk(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                #elseif os(macOS)
                // Retract (hide) the queue inspector — NOT dismiss(): inside an `.inspector`,
                // `dismiss()` tears down the whole WINDOW (it was closing the entire app), so flip
                // the same nav flag the now-playing-bar button and ⌥⌘Q toggle use. `sidebar.right`
                // reads as "collapse the right panel".
                Button { macNav.showingQueue = false } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.lumaInk(0.7))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Warteschlange ausblenden")
                #endif
            }

            if !app.queue.items.isEmpty {
                HStack(spacing: 10) {
                    // Destructive — red-tinted and deliberately narrower so it's hard to hit by mistake.
                    queueActionButton(label: "Leeren", icon: "trash",
                                      tint: Color.red.opacity(0.95),
                                      fill: Color.red.opacity(0.14),
                                      stroke: Color.red.opacity(0.22)) {
                        app.queue.clear()
                        app.player.stop()
                        dismiss()
                    }
                    #if os(iOS) || os(visionOS)
                    .frame(width: 120)
                    #endif

                    // Main, safe action — fills the remaining width on iOS; a compact pill on macOS.
                    queueActionButton(label: "Neu ordnen", icon: "shuffle",
                                      tint: .lumaInk(),
                                      fill: Color.lumaInk(0.1),
                                      stroke: Color.lumaInk(0.14)) {
                        reshuffleQueue()
                    }
                    .disabled(upNext.count < 2)
                    .opacity(upNext.count < 2 ? 0.4 : 1)
                    .accessibilityLabel("Warteschlange neu ordnen")

                    #if os(macOS)
                    // Compact pills sit left like the Abspielen/Shuffle header; spacer fills the rest.
                    Spacer(minLength: 0)
                    #endif
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    /// One of the queue actions (Neu ordnen / Leeren), styled to MATCH the Abspielen/Shuffle pills:
    /// compact content-width 32-pt pills on macOS, full-width 48-pt rows on iOS.
    private func queueActionButton(
        label: LocalizedStringKey,
        icon: String,
        tint: Color,
        fill: Color,
        stroke: Color,
        action: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        let corner: CGFloat = 9
        #else
        let corner: CGFloat = 14
        #endif
        return Button(action: action) {
            Label(label, systemImage: icon)
                #if os(macOS)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .frame(height: 32)
                #else
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.25)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                #endif
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous).fill(fill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 0.5)
                }
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var queueList: some View {
        List {
            if let current = app.queue.currentTrack {
                Section {
                    nowPlayingRow(track: current)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                        .moveDisabled(true)
                } header: {
                    sectionHeader("GERADE")
                }
            }

            Section {
                if upNext.isEmpty {
                    Text("Nichts weiteres in der Warteschlange")
                        .foregroundStyle(.lumaInk(0.35))
                        .font(.subheadline)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                } else {
                    #if os(macOS)
                    // macOS: identify rows by POSITION (offset) so a queue that legitimately repeats
                    // a track can still be reordered/removed per-slot. The old `id: \.id` form
                    // collided on duplicate tracks, and the id-based remove dropped the WRONG/extra
                    // occurrence ("removes the song after"). `.onMove` drives drag-reorder natively
                    // (no edit mode needed on macOS); the hover-✕ / right-click removes by offset.
                    ForEach(Array(upNext.enumerated()), id: \.offset) { offset, track in
                        upNextRow(track) {
                            app.queue.removeUpNext(at: offset)
                            app.savePlaybackState()
                        }
                    }
                    .onMove { from, to in
                        app.queue.moveUpNext(fromOffsets: from, toOffset: to)
                        app.savePlaybackState()
                    }
                    #else
                    // iOS: a binding + `editActions: .move` gives drag-to-reorder WITHOUT edit mode —
                    // edit mode is what suppresses `.swipeActions`, so this lets reorder and
                    // swipe-to-remove coexist.
                    ForEach(upNextBinding, id: \.id, editActions: .move) { $track in
                        upNextRow(track) { removeFromQueue(track) }
                            // iOS: swipe right-to-left to drop the track.
                            .lumaQueueRemoveSwipe { removeFromQueue(track) }
                    }
                    #endif
                }
            } header: {
                if !upNext.isEmpty { sectionHeader("ALS NÄCHSTES") }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .textCase(nil)
            .foregroundStyle(.lumaInk(0.4))
            .padding(.top, 8)
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    private func nowPlayingRow(track: Track) -> some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(data: track.resolvedArtworkData(), cacheKey: track.artworkCacheKey, cornerRadius: 6, size: 40)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.4))
                    .frame(width: 40, height: 40)
                NowPlayingGlyph(isActive: app.player.state.isPlaying,
                                size: 14, weight: .medium, tint: .lumaAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.lumaAccent)
                    .lineLimit(1)
                Text(nowPlayingSubtitle(track))
                    .font(.system(size: 12))
                    .foregroundStyle(.lumaInk(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Text(track.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.lumaInk(0.35))
        }
        .frame(minHeight: 50)
    }

    /// "Artist — Album" (Apple-Music style), falling back to just the artist when no album.
    private func nowPlayingSubtitle(_ track: Track) -> String {
        let album = track.albumTitle.trimmingCharacters(in: .whitespaces)
        return album.isEmpty ? track.artistName : "\(track.artistName) — \(album)"
    }

    // MARK: - Reorder / Delete

    /// Re-mixes the upcoming tracks into a fresh random order, animating the rows into place,
    /// then persists the new order so it survives a relaunch. A haptic confirms the tap on iOS.
    private func reshuffleQueue() {
        withAnimation(.easeInOut(duration: 0.3)) {
            app.queue.reshuffle()
        }
        app.savePlaybackState()
        queueActionHaptic()
    }

    /// Binds the up-next tracks so SwiftUI's `editActions` reordering can rewrite their order
    /// directly; the setter funnels the new order back through the queue (current track + history
    /// stay fixed) and persists it.
    private var upNextBinding: Binding<[Track]> {
        Binding(
            get: { app.queue.upNext },
            set: { newOrder in
                app.queue.replaceUpNext(with: newOrder)
                app.savePlaybackState()
            }
        )
    }

    /// One up-next row, shared by the macOS (offset-keyed) and iOS (binding) lists. The remove
    /// action is injected so each platform can target the right slot (macOS by offset, iOS by id).
    @ViewBuilder
    private func upNextRow(_ track: Track, remove: @escaping () -> Void) -> some View {
        TrackRow(track: track, showArtwork: true,
                 // Show "Artist — Album" under the title (Apple-Music queue style).
                 showAlbum: true,
                 showsMenu: false,
                 showsDragHandle: true,
                 isCurrent: false,
                 // Up-next rows are never the current track, so the waveform never shows here —
                 // pass constant false so play/pause doesn't change their Equatable key and
                 // re-render every queue row.
                 isPlaying: false, liked: track.isLiked,
                 // Right-click + macOS hover-✕ remove (iOS also has the swipe below).
                 remove: TrackRowRemove(label: "Aus Warteschlange entfernen",
                                        systemImage: "minus.circle", action: remove),
                 onTap: {
            Task { await app.queue.play(track) }
        })
        .equatable()
        .lumaSongRowMinHeight(48)
        .listRowBackground(Color.clear)
        .trackRowSeparator()    // hairline between songs, like every other list
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    /// iOS swipe-to-remove path (by identity). macOS removes by position via `removeUpNext(at:)`,
    /// which handles a queue that legitimately repeats a track.
    private func removeFromQueue(_ track: Track) {
        app.queue.removeTrack(id: track.id)
        app.savePlaybackState()
    }
}
