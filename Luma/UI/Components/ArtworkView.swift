import SwiftUI

/// In-memory cache of decoded artwork images so re-mounting a cover (scrolling, a library
/// refresh) is instant. The cache is keyed by a CHEAP stable string (the caller passes the
/// album/track UUID) — never by the raw image Data, whose hash/equality is O(bytes) and was
/// hashing multi-megabyte covers on the main thread on every lookup.
private final class ImageBox {
    let image: Image
    init(_ image: Image) { self.image = image }
}

nonisolated(unsafe) private let artworkImageCache: NSCache<NSString, ImageBox> = {
    let cache = NSCache<NSString, ImageBox>()
    cache.countLimit = 500
    return cache
}()

struct ArtworkView: View {
    let data: Data?
    var cacheKey: String?
    var cornerRadius: CGFloat = 8
    var size: CGFloat? = nil

    @State private var image: Image?

    init(data: Data?, cacheKey: String? = nil, cornerRadius: CGFloat = 8, size: CGFloat? = nil) {
        self.data = data
        self.cacheKey = cacheKey
        self.cornerRadius = cornerRadius
        self.size = size
        // Seed synchronously from the cache so a known cover shows on the first frame.
        if let key = Self.key(for: data, cacheKey: cacheKey),
           let box = artworkImageCache.object(forKey: key) {
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
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Reload when the data changes (e.g. the mini-player on a track switch). loadImage
        // hits the cache first, so a known cover swaps instantly.
        .task(id: data) { image = await Self.loadImage(from: data, cacheKey: cacheKey) }
    }

    private var placeholder: some View {
        ZStack {
            Color(.systemFill)
            Image(systemName: "music.note")
                .font(.system(size: (size ?? 60) * 0.35))
                .foregroundStyle(.secondary)
        }
    }

    /// Caller-supplied id (cheap) when available; otherwise a one-time content hash. Never
    /// lets NSCache hash the raw Data on every operation.
    private static func key(for data: Data?, cacheKey: String?) -> NSString? {
        if let cacheKey { return cacheKey as NSString }
        guard let data else { return nil }
        return String(data.hashValue) as NSString
    }

    private static func loadImage(from data: Data?, cacheKey: String?) async -> Image? {
        guard let data else { return nil }
        let key = key(for: data, cacheKey: cacheKey)
        if let key, let box = artworkImageCache.object(forKey: key) { return box.image }
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
        if let decoded, let key { artworkImageCache.setObject(ImageBox(decoded), forKey: key) }
        return decoded
    }
}
