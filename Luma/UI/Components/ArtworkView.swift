import SwiftUI

/// In-memory cache of decoded artwork images, so re-mounting a cover (while scrolling or
/// during a library rescan) is instant — no re-decode, no placeholder flash. NSCache is
/// thread-safe; in practice it is only touched from the main actor here.
private final class ImageBox {
    let image: Image
    init(_ image: Image) { self.image = image }
}

nonisolated(unsafe) private let artworkImageCache: NSCache<NSData, ImageBox> = {
    let cache = NSCache<NSData, ImageBox>()
    cache.countLimit = 500
    return cache
}()

// Renders album artwork from raw Data with a placeholder fallback. Decoded images are
// cached so repeated renders don't re-decode (avoids flicker + CPU spikes during imports).
struct ArtworkView: View {
    let data: Data?
    var cornerRadius: CGFloat = 8
    var size: CGFloat? = nil

    @State private var image: Image?

    init(data: Data?, cornerRadius: CGFloat = 8, size: CGFloat? = nil) {
        self.data = data
        self.cornerRadius = cornerRadius
        self.size = size
        // Seed synchronously from the cache so an already-decoded cover shows on the very
        // first frame instead of flashing the placeholder.
        if let data, let box = artworkImageCache.object(forKey: data as NSData) {
            _image = State(initialValue: box.image)
        }
    }

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
        // Size FIRST, then clip: in a horizontal ScrollView the proposed width is
        // unbounded, so clipping before framing let `scaledToFill` blow up and then get
        // squashed into the frame — the smeared cover strip in "recently added". Framing
        // first constrains the fill to the square before it is clipped.
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Reload whenever the data changes (e.g. the mini-player on a track switch).
        // loadImage hits the in-memory cache first, so a known cover swaps instantly.
        .task(id: data) {
            image = await Self.loadImage(from: data)
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

    private static func loadImage(from data: Data?) async -> Image? {
        guard let data else { return nil }
        if let box = artworkImageCache.object(forKey: data as NSData) { return box.image }
        let decoded = await Task.detached(priority: .userInitiated) { () -> Image? in
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
        if let decoded { artworkImageCache.setObject(ImageBox(decoded), forKey: data as NSData) }
        return decoded
    }
}
