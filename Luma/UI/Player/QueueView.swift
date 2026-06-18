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
        HStack(spacing: 12) {
            Text("Warteschlange")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()

            if !app.queue.items.isEmpty {
                Button {
                    app.queue.clear()
                    app.player.stop()
                    dismiss()
                } label: {
                    Text("Leeren")
                        .font(.system(size: 15))
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }

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
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 14)
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
                    ForEach(Array(upNext.enumerated()), id: \.element.id) { offset, track in
                        let queueIndex = app.queue.currentIndex + 1 + offset
                        TrackRow(track: track, showArtwork: true, showsMenu: true) {
                            Task { await app.queue.play(at: queueIndex) }
                        }
                        .frame(minHeight: 56)   // taller rows → easier to grab & drag-reorder
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeTrack(at: queueIndex)
                            } label: {
                                Label("Entfernen", systemImage: "minus.circle")
                            }
                        }
                    }
                    .onMove(perform: moveTracks)
                }
            } header: {
                if !upNext.isEmpty { sectionHeader("ALS NÄCHSTES") }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .queueEditMode(true)
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

    private func moveTracks(from source: IndexSet, to destination: Int) {
        let base = app.queue.currentIndex + 1
        let queueSource = IndexSet(source.map { base + $0 })
        let queueDestination = base + destination
        app.queue.move(from: queueSource, to: queueDestination)
    }

    private func removeTrack(at queueIndex: Int) {
        app.queue.remove(at: IndexSet(integer: queueIndex))
    }
}

private extension View {
    /// Drives List edit mode from a Bool on platforms that have `EditMode`
    /// (iOS/iPadOS/visionOS). macOS Lists reorder via `.onMove` without it.
    @ViewBuilder
    func queueEditMode(_ editing: Bool) -> some View {
        #if os(iOS) || os(visionOS)
        environment(\.editMode, .constant(editing ? .active : .inactive))
        #else
        self
        #endif
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
