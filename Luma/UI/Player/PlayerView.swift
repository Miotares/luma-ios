import SwiftUI
import SwiftData
import AVFoundation
#if os(iOS) || os(visionOS)
import AVKit
#endif

struct PlayerView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.createdDate, order: .reverse) private var playlists: [Playlist]

    @State private var palette: ColorPalette?
    @State private var showingQueue = false
    @State private var showNavOptions = false
    @State private var albumSheet: Album?
    @State private var artistSheet: Artist?

    private var track: Track? { app.player.currentTrack }

    var body: some View {
        mainContent
            .background {
                ArtworkBackground(data: track?.album?.artworkData, palette: palette)
            }
            .sheet(isPresented: $showingQueue) { QueueView() }
            .sheet(item: $albumSheet) { album in
                NavigationStack { AlbumDetailView(album: album) }
            }
            .sheet(item: $artistSheet) { artist in
                NavigationStack { ArtistDetailView(artist: artist) }
            }
            .confirmationDialog(track?.title ?? "", isPresented: $showNavOptions, titleVisibility: .visible) {
                if let album = track?.album {
                    Button("Album anzeigen") { albumSheet = album }
                }
                if let artist = track?.artist {
                    Button("Künstler anzeigen") { artistSheet = artist }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .task(id: track?.id) {
                guard let t = track else { return }
                let p = await PaletteExtractor.shared.palette(
                    for: t.album?.id ?? t.id,
                    imageData: t.album?.artworkData
                )
                withAnimation(.easeInOut(duration: 0.8)) { palette = p }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let track {
            playerBody(track: track)
        } else {
            Color.lumaBackground.ignoresSafeArea()
                .overlay {
                    ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                        .foregroundStyle(.white)
                }
        }
    }

    @ViewBuilder
    private func playerBody(track: Track) -> some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 40, height: 4)
                .padding(.top, 14)

            // Header row
            HStack {
                Button { dismiss() } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                VStack(spacing: 1) {
                    Text("Wird gespielt")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Menu {
                    optionsMenu(track: track)
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)

            Spacer(minLength: 28)

            // Artwork — responsive, scales with play state
            ArtworkView(data: track.album?.artworkData, cornerRadius: 22, size: nil)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 28)
                .shadow(color: .black.opacity(0.75), radius: 45, y: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                        .padding(.horizontal, 28)
                )
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

            Spacer(minLength: 36)

            // Controls block
            VStack(spacing: 0) {
                // Title + like
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        MarqueeText(text: track.title, font: .system(size: 23, weight: .bold))
                            .foregroundStyle(.white)
                        Text(track.artistName)
                            .font(.system(size: 16, weight: .medium))
                            .tracking(-0.2)
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showNavOptions = true }
                    Spacer(minLength: 12)
                    PlayerLikeButton(track: track)
                }

                // Scrubber reads the player itself so the ~4×/sec time updates
                // re-render only it — not the whole player (which made the
                // transport buttons feel laggy).
                PlayerScrubber()
                    .padding(.top, 18)

                // Transport controls — isolated subview so play/shuffle/repeat taps
                // re-render only the controls, never the heavy blurred background.
                PlayerTransport()
                    .padding(.top, 24)
                    .padding(.horizontal, 4)

                // Bottom: Queue (left) + Output/AirPlay (right)
                HStack(alignment: .top) {
                    Button { showingQueue = true } label: {
                        bottomControlLabel(icon: "list.bullet", title: "Warteschlange")
                    }

                    Spacer()

                    SleepTimerIndicator()

                    Spacer()

                    VStack(spacing: 5) {
                        AirPlayRoutePicker()
                            .frame(width: 28, height: 28)
                        OutputDeviceLabel()
                    }
                }
                .padding(.top, 28)
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 34)
        }
        // Snappy press feedback for every transport/back/like button in the player.
        .buttonStyle(PressableButtonStyle())
    }

    private func bottomControlLabel(icon: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: 28)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private func optionsMenu(track: Track) -> some View {
        if let album = track.album {
            Button { albumSheet = album } label: {
                Label("Album anzeigen", systemImage: "square.stack")
            }
        }
        if let artist = track.artist {
            Button { artistSheet = artist } label: {
                Label("Künstler anzeigen", systemImage: "music.microphone")
            }
        }
        if !playlists.isEmpty {
            Menu {
                ForEach(playlists) { playlist in
                    Button {
                        try? app.library.addTracks([track], to: playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Zur Playlist hinzufügen", systemImage: "text.badge.plus")
            }
        }

        Divider()

        Menu {
            if app.player.isSleepTimerActive {
                Button(role: .destructive) { app.player.cancelSleepTimer() } label: {
                    Label("Aus", systemImage: "moon.zzz")
                }
                Divider()
            }
            ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { minutes in
                Button { app.player.startSleepTimer(minutes: minutes) } label: {
                    Text("\(minutes) Min")
                }
            }
            Button { app.player.startSleepTimerEndOfTrack() } label: {
                Label("Ende des Titels", systemImage: "text.append")
            }
        } label: {
            Label("Sleep-Timer", systemImage: "moon.zzz")
        }
    }
}

// MARK: - Blurred Artwork Background

struct ArtworkBackground: View {
    let data: Data?
    let palette: ColorPalette?
    @State private var image: Image?

    var body: some View {
        ZStack {
            Color.lumaBackground

            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.3)            // overscan so soft blurred edges stay off-screen
                    .blur(radius: 64, opaque: true)
                    .saturation(1.8)             // richer, cover-derived colour
                    .brightness(-0.20)           // keep it readable but let the colour show
                    .clipped()
            }

            // Keep the header and controls legible without washing out the cover colour.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.30),
                    .init(color: .black.opacity(0.22), location: 0.62),
                    .init(color: .black.opacity(0.82), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .task(id: data) { image = await decode(data) }
    }

    private func decode(_ data: Data?) async -> Image? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            #if os(iOS) || os(visionOS)
            guard let ui = UIImage(data: data) else { return nil }
            return Image(uiImage: ui)
            #elseif os(macOS)
            guard let ns = NSImage(data: data) else { return nil }
            return Image(nsImage: ns)
            #else
            return nil
            #endif
        }.value
    }
}

// MARK: - Scrubber

struct PlayerScrubber: View {
    @Environment(AppContainer.self) private var app
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var currentTime: TimeInterval { app.player.currentTime }
    private var duration: TimeInterval { app.player.duration }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return isDragging ? dragProgress : min(1, currentTime / duration)
    }

    /// Time reflected by the labels — follows the thumb while scrubbing.
    private var displayedTime: TimeInterval {
        isDragging ? dragProgress * duration : currentTime
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .frame(height: isDragging ? 5 : 3)
                    Capsule()
                        .fill(.white.opacity(0.9)) // neutral — not album/accent colour
                        .frame(width: geo.size.width * progress, height: isDragging ? 5 : 3)
                    if isDragging {
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .offset(x: geo.size.width * progress - 8)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !isDragging {
                                withAnimation(.easeOut(duration: 0.1)) { isDragging = true }
                            }
                            dragProgress = max(0, min(1, v.location.x / geo.size.width))
                        }
                        .onEnded { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            app.player.seek(to: p * duration)
                            withAnimation(.easeOut(duration: 0.1)) { isDragging = false }
                        }
                )
            }
            .frame(height: 26)

            HStack {
                Text(format(displayedTime))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                // Counts down the time remaining rather than showing the fixed length.
                Text("-" + format(max(0, duration - displayedTime)))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Marquee Text

/// One-line text that, when too wide to fit, pauses, scrolls to reveal the end,
/// pauses, scrolls back, and loops. Short text just stays put.
struct MarqueeText: View {
    let text: String
    var font: Font

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        Text(text)                                   // invisible sizer → full width + line height
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(GeometryReader { g in
                Color.clear
                    .onAppear { boxWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in boxWidth = w }
            })
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .overlay(GeometryReader { g in
                        Color.clear
                            .onAppear { textWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in textWidth = w }
                    })
                    .offset(x: offset)
            }
            .clipped()
            .onChange(of: text) {
                // New song: hard-snap back to the start (this also kills any in-flight
                // scroll animation, which otherwise keeps running independently of the
                // cancelled task) and drop the previous title's measured width — so a
                // short new title can't inherit the long title's scroll.
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { offset = 0 }
                textWidth = 0
            }
            .task(id: "\(text)|\(Int(textWidth))|\(Int(boxWidth))") { await scroll() }
    }

    private func scroll() async {
        offset = 0
        let overflow = textWidth - boxWidth
        guard overflow > 4 else { return }
        let duration = max(2, Double(overflow) / 30)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))                         // pause showing the start
            withAnimation(.linear(duration: duration)) { offset = -overflow }  // run straight through to the end
            try? await Task.sleep(for: .seconds(duration + 1.0))             // finish, then a short read pause
            offset = 0                                                       // RESET: snap back to the start, then loop
        }
    }
}

// MARK: - Isolated Player Controls

/// Heart button isolated so toggling "liked" re-renders only this — not the whole
/// player (which would re-run the expensive blurred background).
struct PlayerLikeButton: View {
    @Environment(AppContainer.self) private var app
    let track: Track

    var body: some View {
        Button {
            try? app.library.toggleLike(track: track)
        } label: {
            // No symbol transition/bounce + animation(nil): the like must flip INSTANTLY.
            // Any ambient transaction (e.g. from the button press) is explicitly opted out
            // so neither the glyph nor the white→pink colour ever slow-morphs.
            Image(systemName: track.isLiked ? "heart.fill" : "heart")
                .font(.system(size: 24))
                .foregroundStyle(track.isLiked ? Color.white : Color.white.opacity(0.5))
                .contentTransition(.identity)
                .frame(width: 44, height: 44)
                .animation(nil, value: track.isLiked)
        }
    }
}

/// Transport row isolated so play/pause/shuffle/repeat taps re-render only here.
struct PlayerTransport: View {
    @Environment(AppContainer.self) private var app
    private var isPlaying: Bool { app.player.state.isPlaying }

    var body: some View {
        HStack(spacing: 0) {
            Button { app.queue.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(app.queue.shuffleMode == .on ? Color.lumaAccent : Color.white.opacity(0.4))
            }
            .frame(width: 44, height: 44)
            .frame(maxWidth: .infinity)

            Button { Task { await app.queue.playPrevious() } } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .frame(maxWidth: .infinity)

            Button { app.player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                        .contentTransition(.identity)
                        .offset(x: isPlaying ? 0 : 2)
                }
                .frame(width: 76, height: 76)
                .animation(nil, value: isPlaying)   // instant play↔pause, no slow morph/slide
            }
            .frame(maxWidth: .infinity)

            Button { Task { await app.queue.advance() } } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .frame(maxWidth: .infinity)

            Button { app.queue.toggleRepeat() } label: {
                Image(systemName: app.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20))
                    .foregroundStyle(app.queue.repeatMode == .off ? Color.white.opacity(0.4) : Color.lumaAccent)
            }
            .frame(width: 44, height: 44)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Sleep Timer Indicator

/// Small countdown pill shown in the player while a sleep timer runs. Isolated so its
/// ~2×/sec updates re-render only this capsule, not the blurred player background. Tap to
/// cancel.
struct SleepTimerIndicator: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        if app.player.isSleepTimerActive {
            Button { app.player.cancelSleepTimer() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 12))
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private var label: String {
        if app.player.sleepMode == .endOfTrack { return String(localized: "Titelende") }
        let r = Int(app.player.sleepRemaining.rounded())
        return String(format: "%d:%02d", r / 60, r % 60)
    }
}

// MARK: - Current Output Device

/// Shows the name of the active audio output (e.g. "iPhone", "AirPods Pro") and
/// updates live when the route changes.
struct OutputDeviceLabel: View {
    @State private var name = OutputDeviceLabel.currentName()

    var body: some View {
        Text(name)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            #if os(iOS) || os(visionOS)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                name = OutputDeviceLabel.currentName()
            }
            #endif
    }

    static func currentName() -> String {
        #if os(iOS) || os(visionOS)
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "Ausgabe" }
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver: return "iPhone"
        default: return output.portName
        }
        #else
        return "Ausgabe"
        #endif
    }
}

// MARK: - AirPlay Output Picker

#if os(iOS) || os(visionOS)
/// Wraps the system `AVRoutePickerView` so users can pick the audio output
/// device (AirPlay, Bluetooth, etc.) from the Now Playing screen.
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.7)
        picker.activeTintColor = UIColor(Color.lumaAccent)
        picker.backgroundColor = .clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayRoutePicker: View {
    var body: some View {
        Image(systemName: "airplayaudio")
            .font(.system(size: 19))
            .foregroundStyle(.white.opacity(0.7))
    }
}
#endif
