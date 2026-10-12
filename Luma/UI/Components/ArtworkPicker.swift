import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A cover edit that is pending in a metadata editor until the user taps "Sichern".
enum ArtworkChange: Equatable {
    case none
    case set(Data)
    case remove
}

/// The tappable cover at the top of the track / album editors: pick a new cover from Photos or
/// Files, or remove the current one. Only records the choice in `change` — the editor applies it
/// on save, together with its other fields.
///
/// Photos go through PhotosPicker (out-of-process, so no photo-library permission prompt), and
/// every picked image is downscaled to ~1024px off the main actor, which also strips EXIF/GPS —
/// the same treatment as playlist covers.
struct ArtworkPickerControl: View {
    /// The stored cover, shown while nothing is pending.
    let current: () -> Data?
    let currentKey: String?
    /// What shows once the stored cover is removed (a track falls back to its album's cover).
    var fallback: (() -> Data?)? = nil
    var fallbackKey: String? = nil
    /// Whether there is a stored cover that "remove" would take away.
    let canRemove: Bool
    let removeLabel: LocalizedStringKey
    @Binding var change: ArtworkChange

    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var previewToken = 0

    private let size: CGFloat = 120

    var body: some View {
        Menu {
            Button { showingPhotos = true } label: {
                Label("Aus Fotos wählen", systemImage: "photo.on.rectangle")
            }
            Button { showingFiles = true } label: {
                Label("Aus Dateien wählen", systemImage: "folder")
            }
            if change != .none {
                Button { change = .none } label: {
                    Label("Änderung verwerfen", systemImage: "arrow.uturn.backward")
                }
            }
            if canRemove, change != .remove {
                Button(role: .destructive) { change = .remove } label: {
                    Label(removeLabel, systemImage: "trash")
                }
            }
        } label: {
            cover
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.lumaOnAccent)
                        .frame(width: 30, height: 30)
                        .background(Color.lumaAccent, in: Circle())
                        .offset(x: 8, y: 8)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cover ändern")
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { loadFile(url) }
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
    }

    @ViewBuilder
    private var cover: some View {
        switch change {
        case .set(let data):
            // A fresh key per pick: this preview must never come out of the decoded-image cache.
            ArtworkView(data: data, cacheKey: "artwork-edit-\(previewToken)", cornerRadius: 14, size: size)
        case .remove:
            ArtworkView(data: fallback?(), cacheKey: fallbackKey, cornerRadius: 14, size: size)
        case .none:
            ArtworkView(data: current(), cacheKey: currentKey, cornerRadius: 14, size: size)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { return }
            await adopt(raw)
            photoItem = nil   // so picking the same photo again still triggers
        }
    }

    private func loadFile(_ url: URL) {
        Task {
            let raw = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: url)
            }.value
            if let raw { await adopt(raw) }
        }
    }

    private func adopt(_ raw: Data) async {
        // Full ImageIO decode + JPEG re-encode of a possibly 12+ MP image — off the main actor.
        let downscaled = await Task.detached(priority: .userInitiated) {
            ImageDownscaler.thumbnail(from: raw, maxPixel: 1024)
        }.value
        previewToken &+= 1
        change = .set(downscaled)
    }
}
