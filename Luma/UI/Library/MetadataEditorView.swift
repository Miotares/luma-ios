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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ArtworkView(data: track.album?.artworkData, cacheKey: track.album?.id.uuidString, cornerRadius: 14, size: 120)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                        .padding(.top, 8)

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
                        .foregroundStyle(.white.opacity(0.8))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.lumaAccent)
                }
            }
            .lumaDarkNavBackground()
            .lumaDarkNavScheme()
        }
        .onAppear(perform: load)
    }

    private func field(_ label: LocalizedStringKey, text: Binding<String>, numeric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("", text: text)
                .font(.system(size: 16))
                .foregroundStyle(.white)
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
            trackNumber: Int(trackNumber) ?? track.trackNumber,
            year: Int(year),
            genre: genre
        )
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
