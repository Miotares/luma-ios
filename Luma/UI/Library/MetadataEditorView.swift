import SwiftUI

struct MetadataEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var trackNumber = ""
    @State private var year = ""
    @State private var genre = ""
    @State private var artworkChange: ArtworkChange = .none

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Sets this TRACK's own cover; removing it falls back to the album's.
                    ArtworkPickerControl(
                        current: { track.resolvedArtworkData() },
                        currentKey: track.artworkCacheKey,
                        fallback: { track.album?.artworkData },
                        fallbackKey: track.album?.artworkCacheKey,
                        canRemove: track.hasCustomArtwork,
                        removeLabel: "Eigenes Cover entfernen",
                        change: $artworkChange
                    )
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                    .padding(.top, 8)

                    Text("Das Cover gilt nur für diesen Titel. Das Album-Cover änderst du in den Albuminformationen.")
                        .font(.caption)
                        .foregroundStyle(.lumaInk(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    VStack(spacing: 12) {
                        field("Titel", text: $title)
                        field("Künstler", text: $artist)
                        field("Album", text: $album)
                        HStack(spacing: 12) {
                            field("Titelnummer", text: $trackNumber, numeric: true)
                            field("Jahr", text: $year, numeric: true)
                        }
                        field("Genre", text: $genre)
                    }
                }
                .padding(20)
            }
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Informationen")
            #if os(iOS) || os(visionOS)
            .lumaInlineNavTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .foregroundStyle(.lumaInk(0.8))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.lumaAccent)
                        // A track must keep a title — don't let Save persist an empty/blank one.
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .lumaDarkNavBackground()
            .lumaDarkNavScheme()
        }
        .onAppear(perform: load)
        // Don't let an accidental swipe-down silently throw away entered edits.
        .interactiveDismissDisabled(isDirty)
    }

    /// True once any field differs from the track's stored values.
    private var isDirty: Bool {
        title != track.title
            || artist != track.artistName
            || album != track.albumTitle
            || trackNumber != (track.trackNumber > 0 ? String(track.trackNumber) : "")
            || year != (track.year.map(String.init) ?? "")
            || genre != (track.genre ?? "")
            || artworkChange != .none
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.lumaInk(0.5))
            TextField("", text: text)
                .font(.system(size: 16))
                .foregroundStyle(.lumaInk())
                .tint(Color.lumaAccent)
                .modifier(NumericKeyboard(enabled: numeric))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() {
        title = track.title
        artist = track.artistName
        album = track.albumTitle
        trackNumber = track.trackNumber > 0 ? String(track.trackNumber) : ""
        year = track.year.map(String.init) ?? ""
        genre = track.genre ?? ""
    }

    private func save() {
        try? app.library.updateTrack(
            track,
            title: title,
            artistName: artist,
            albumTitle: album,
            // Empty field clears the track number (0 = none), matching how the Year field clears.
            trackNumber: Int(trackNumber) ?? 0,
            year: Int(year),
            genre: genre
        )
        switch artworkChange {
        case .none: break
        case .set(let data): try? app.library.updateTrackArtwork(track, data: data)
        case .remove: try? app.library.updateTrackArtwork(track, data: nil)
        }
        if artworkChange != .none {
            // The player derives its background colours from the cover — drop the cached palette.
            let ids = [track.id, track.album?.id].compactMap { $0 }
            Task { for id in ids { await PaletteExtractor.shared.invalidate(for: id) } }
        }
        dismiss()
    }
}

/// Applies the number-pad keyboard on iOS without breaking the macOS build.
private struct NumericKeyboard: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        #if os(iOS) || os(visionOS)
        content.keyboardType(enabled ? .numberPad : .default)
        #else
        content
        #endif
    }
}
