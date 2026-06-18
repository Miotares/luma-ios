#if os(macOS)
import SwiftUI
import SwiftData

/// Desktop "Now Playing" in the Apple-Music / Spotify mould: a two-pane layout with the
/// large artwork + controls on the left and the up-next queue on the right, over a blurred
/// artwork backdrop. Reuses the shared player building blocks.
struct MacPlayerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.createdDate, order: .reverse) private var playlists: [Playlist]

    @State private var palette: ColorPalette?

    private var track: Track? { app.player.currentTrack }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ArtworkBackground(data: track?.album?.artworkData, palette: palette)

            if let track {
                HStack(spacing: 0) {
                    nowPlaying(track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().overlay(Color.white.opacity(0.08))
                    queuePane
                        .frame(width: 320)
                }
            } else {
                ContentUnavailableView("Nichts in Wiedergabe", systemImage: "music.note")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            closeButton.padding(16)
        }
        .frame(minWidth: 900, idealWidth: 1020, minHeight: 600, idealHeight: 700)
        .task(id: track?.id) {
            guard let t = track else { return }
            let p = await PaletteExtractor.shared.palette(for: t.album?.id ?? t.id, imageData: t.album?.artworkData)
            withAnimation(.easeInOut(duration: 0.8)) { palette = p }
        }
    }

    // MARK: - Left pane: now playing

    private func nowPlaying(_ track: Track) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ArtworkView(data: track.album?.artworkData, cornerRadius: 16, size: nil)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 360, maxHeight: 360)
                .shadow(color: .black.opacity(0.6), radius: 34, y: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )

            VStack(spacing: 6) {
                MarqueeText(text: track.title, font: .system(size: 23, weight: .bold))
                    .foregroundStyle(.white)
                Text(track.artistName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: 460)
            .padding(.top, 26)

            PlayerScrubber()
                .frame(maxWidth: 460)
                .padding(.top, 16)

            PlayerTransport()
                .frame(maxWidth: 460)
                .padding(.top, 14)

            HStack(spacing: 14) {
                LumaVolumeControl(width: 150)
                Spacer()
                PlayerLikeButton(track: track)
                Menu {
                    optionsMenu(track: track)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
            }
            .frame(maxWidth: 460)
            .padding(.top, 18)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 44)
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Right pane: up next

    private var queuePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Als Nächstes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if !app.queue.upNext.isEmpty {
                    Button {
                        app.queue.clear()
                        app.player.stop()
                    } label: {
                        Text("Leeren").font(.system(size: 12)).foregroundStyle(.red.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 12)

            if app.queue.upNext.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "music.note.list").font(.system(size: 30)).foregroundStyle(.white.opacity(0.2))
                    Text("Nichts in der Warteschlange")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(app.queue.upNext.enumerated()), id: \.element.id) { offset, track in
                        let queueIndex = app.queue.currentIndex + 1 + offset
                        queueRow(track)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await app.queue.play(at: queueIndex) } }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    app.queue.remove(at: IndexSet(integer: queueIndex))
                                } label: { Label("Entfernen", systemImage: "minus.circle") }
                            }
                    }
                    .onMove { source, dest in
                        let base = app.queue.currentIndex + 1
                        app.queue.move(from: IndexSet(source.map { base + $0 }), to: base + dest)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
    }

    private func queueRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ArtworkView(data: track.album?.artworkData, cornerRadius: 5, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Text(track.artistName).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func optionsMenu(track: Track) -> some View {
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button { try? app.library.addTracks([track], to: playlist) } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zur Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }
    }
}
#endif
