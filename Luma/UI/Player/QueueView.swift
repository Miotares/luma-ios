import SwiftUI

struct QueueView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var upNext: [Track] { app.queue.upNext }

    var body: some View {
        VStack(spacing: 0) {
            queueHeader
            queueList
            #if os(macOS)
            queueVolumeBar
            #endif
        }
        .background(Color.lumaBackground.ignoresSafeArea())
    }

    // MARK: - Header

    private var queueHeader: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Warteschlange")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()

                #if os(iOS)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
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
                    .frame(width: 120)

                    // Main, safe action — fills the remaining width.
                    queueActionButton(label: "Neu ordnen", icon: "shuffle",
                                      tint: .white,
                                      fill: Color.white.opacity(0.1),
                                      stroke: Color.white.opacity(0.14)) {
                        reshuffleQueue()
                    }
                    .disabled(upNext.count < 2)
                    .opacity(upNext.count < 2 ? 0.4 : 1)
                    .accessibilityLabel("Warteschlange neu ordnen")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    /// One of the large queue actions (Neu ordnen / Leeren), styled like the Abspielen/Shuffle
    /// pills on album & playlist headers: 48-pt tall, rounded, icon + label.
    private func queueActionButton(
        label: LocalizedStringKey,
        icon: String,
        tint: Color,
        fill: Color,
        stroke: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.25)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                        .foregroundStyle(.white.opacity(0.35))
                        .font(.subheadline)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                } else {
                    // A binding + `editActions: .move` gives drag-to-reorder (long-press & drag)
                    // WITHOUT putting the List into edit mode — and edit mode is exactly what
                    // suppresses `.swipeActions`. This is what lets reordering and swipe-to-remove
                    // coexist; forcing edit mode for the old grip-drag killed the swipe.
                    ForEach(upNextBinding, id: \.id, editActions: .move) { $track in
                        TrackRow(track: track, showArtwork: true, showsMenu: false,
                                 showsDragHandle: true,
                                 isCurrent: false,
                                 isPlaying: app.player.state.isPlaying, liked: track.isLiked) {
                            Task { await app.queue.play(track) }
                        }
                        .equatable()
                        .frame(minHeight: 56)   // taller rows → easier to grab & drag-reorder
                        .listRowBackground(Color.clear)
                        .trackRowSeparator()    // hairline between songs, like every other list
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        // Swipe right-to-left to drop the track from the queue. Tint forced red —
                        // the app's white accent would otherwise leave the button white-on-white.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeFromQueue(track)
                            } label: {
                                Label("Entfernen", systemImage: "minus.circle")
                            }
                            .tint(.red)
                        }
                    }
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
            .foregroundStyle(.white.opacity(0.4))
            .padding(.top, 8)
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    private func nowPlayingRow(track: Track) -> some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(data: track.album?.artworkData, cacheKey: track.album?.id.uuidString, cornerRadius: 8, size: 48)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.4))
                    .frame(width: 48, height: 48)
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: app.player.state.isPlaying)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.lumaAccent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.lumaAccent)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Text(track.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(minHeight: 60)
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

    private func removeFromQueue(_ track: Track) {
        app.queue.removeTrack(id: track.id)
        app.savePlaybackState()
    }
}

#if os(macOS)
private extension QueueView {
    /// Volume control pinned to the bottom of the queue (macOS — no hardware volume keys
    /// route to the app like on iOS).
    var queueVolumeBar: some View {
        HStack(spacing: 10) {
            LumaVolumeControl(width: 150)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}
#endif
