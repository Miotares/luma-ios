import SwiftUI
import SwiftData

/// Lyrics of the track that is playing. They come from the track's stored text if it has one
/// (typed in here, or picked up from a `.lrc` file at import), otherwise straight from the audio
/// file's tags — read when this opens, so nothing has to be imported again for it to work.
struct LyricsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable {
        case loading
        case none
        case loaded(LyricsText)
    }

    @State private var state: LoadState = .loading
    /// What the file itself carries — the editor's "reset" target. nil = the file has no lyrics.
    @State private var fileLyrics: String?
    /// The edit in progress. It pins the track it was opened for: playback can move on to the next
    /// song while the editor is up, and the text must still be saved to the song it belongs to.
    @State private var editing: EditTarget?

    fileprivate struct EditTarget: Identifiable {
        let id = UUID()
        let track: Track
        let initialText: String
        let fileLyrics: String?
    }

    private var track: Track? { app.player.currentTrack }

    /// Reload when the track changes AND when its stored lyrics do (after an edit).
    private var reloadKey: String {
        guard let track else { return "-" }
        return "\(track.id.uuidString)-\(track.customLyrics?.hashValue ?? 0)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color.lumaBackground.ignoresSafeArea())
        .task(id: reloadKey) { await load() }
        .sheet(item: $editing) { target in
            LyricsEditor(target: target).environment(app)
        }
    }

    private func startEditing() {
        guard let track else { return }
        editing = EditTarget(track: track,
                             initialText: track.customLyrics ?? fileLyrics ?? "",
                             fileLyrics: fileLyrics)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lyrics")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.lumaInk())
                if let track {
                    Text("\(track.title) · \(track.artistName)")
                        .font(.system(size: 13))
                        .foregroundStyle(.lumaInk(0.5))
                        .lineLimit(1)
                }
            }
            Spacer()

            if track != nil, state != .loading {
                Button { startEditing() } label: {
                    headerIcon(state == .none ? "plus" : "pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state == .none ? "Lyrics hinzufügen" : "Lyrics bearbeiten")
            }
            #if os(iOS)
            Button { dismiss() } label: { headerIcon("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Schließen")
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.lumaInk(0.85))
            .frame(width: 30, height: 30)
            .background(Color.lumaInk(0.1), in: Circle())
            .contentShape(Circle())
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .none:
            VStack(spacing: 22) {
                LumaEmptyState(icon: "quote.bubble",
                               title: "Keine Lyrics",
                               subtitle: "Für diesen Titel sind keine Lyrics hinterlegt.")
                if track != nil {
                    Button { startEditing() } label: {
                        Label("Lyrics hinzufügen", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Color.lumaAccent, in: Capsule())
                            .foregroundStyle(.lumaOnAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let lyrics):
            ScrollView {
                Text(lyrics.plainText)
                    .font(.system(size: 21, weight: .semibold))
                    .lineSpacing(9)
                    .foregroundStyle(.lumaInk(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let track else {
            state = .none
            fileLyrics = nil
            return
        }
        let stored = track.customLyrics
        if let stored {
            state = .loaded(LyricsText(stored))
        } else {
            state = .loading
        }

        // Always look at the file too: it is what's shown when nothing is stored, and what the
        // editor can reset to when something is.
        var fromFile: String?
        if let url = try? track.resolveURL() {
            let scoped = url.startAccessingSecurityScopedResource()
            fromFile = await LyricsReader.lyrics(for: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard !Task.isCancelled else { return }   // the track changed while reading
        fileLyrics = fromFile
        if stored == nil {
            let parsed = fromFile.map(LyricsText.init)
            state = parsed.map { $0.isEmpty ? .none : .loaded($0) } ?? .none
        }
    }
}

// MARK: - Editor

/// Type, paste or correct a track's lyrics. Works on the RAW text, so LRC timestamps survive an
/// edit. Saving stores the text on the track; it then takes precedence over what the file carries.
private struct LyricsEditor: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    private let track: Track
    private let initialText: String
    private let fileLyrics: String?

    @State private var text: String

    init(target: LyricsView.EditTarget) {
        track = target.track
        initialText = target.initialText
        fileLyrics = target.fileLyrics
        _text = State(initialValue: target.initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .foregroundStyle(.lumaInk())
                    .tint(Color.lumaAccent)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Lyrics hier eingeben oder einfügen …")
                                .font(.system(size: 16))
                                .foregroundStyle(.lumaInk(0.3))
                                .padding(.horizontal, 15)
                                .padding(.vertical, 18)
                                .allowsHitTesting(false)
                        }
                    }

                if track.modelContext != nil, track.customLyrics != nil {
                    // Stored text exists: offer the way back to what the file itself says (or to
                    // nothing, when the file has no lyrics).
                    Button(role: .destructive) {
                        try? app.library.updateLyrics(track, text: nil)
                        dismiss()
                    } label: {
                        Text(fileLyrics == nil ? "Lyrics entfernen" : "Auf Lyrics aus der Datei zurücksetzen")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .padding(16)
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Lyrics")
            #if os(iOS) || os(visionOS)
            .lumaInlineNavTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .foregroundStyle(.lumaInk(0.8))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        // Skip the write if the track was deleted while the editor was open.
                        if track.modelContext != nil { try? app.library.updateLyrics(track, text: text) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.lumaAccent)
                    .disabled(text == initialText)
                }
            }
            .lumaDarkNavBackground()
            .lumaDarkNavScheme()
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
        // Don't let an accidental swipe-down silently throw away typed lyrics.
        .interactiveDismissDisabled(text != initialText)
    }
}
