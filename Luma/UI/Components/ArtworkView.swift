import SwiftUI

// Renders album artwork from raw Data with a placeholder fallback.
// Uses task-based loading to avoid blocking the rendering thread.
struct ArtworkView: View {
    let data: Data?
    var cornerRadius: CGFloat = 8
    var size: CGFloat? = nil

    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .frame(width: size, height: size)
        .task(id: data) {
            image = await loadImage(from: data)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.systemFill)
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 60) * 0.35))
                .foregroundStyle(.secondary)
        }
    }

    private func loadImage(from data: Data?) async -> Image? {
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
