import SwiftUI

struct AlbumMetadataEditorView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    let album: Album

    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var genre = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ArtworkView(data: album.artworkData, cacheKey: album.id.uuidString, cornerRadius: 14, size: 120)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                        .padding(.top, 8)

                    VStack(spacing: 12) {
                        field("Albumtitel", text: $title)
                        field("Albuminterpret", text: $artist)
                        field("Jahr", text: $year, numeric: true)
                        field("Genre", text: $genre)
                    }

                    Text("Änderungen am Albuminterpret verschieben das ganze Album zu diesem Künstler.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(20)
            }
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Albuminformationen")
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
                .modifier(AlbumNumericKeyboard(enabled: numeric))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func load() {
        title = album.title
        artist = album.artistName
        year = album.year.map(String.init) ?? ""
        genre = album.genre ?? ""
    }

    private func save() {
        try? app.library.updateAlbum(
            album,
            title: title,
            artistName: artist,
            year: Int(year),
            genre: genre
        )
        dismiss()
    }
}

/// Number-pad keyboard on iOS without breaking the macOS build.
private struct AlbumNumericKeyboard: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        #if os(iOS) || os(visionOS)
        content.keyboardType(enabled ? .numberPad : .default)
        #else
        content
        #endif
    }
}
