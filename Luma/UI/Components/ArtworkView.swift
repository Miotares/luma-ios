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
    cache.totalCostLimit = 96 * 1024 * 1024 // ~96 MB of decoded bitmaps — bounds memory growth
    return cache
}()

struct ArtworkView: View {
    /// The bytes are provided lazily (autoclosure) so a row NEVER faults the SwiftData artwork
    /// blob just to pass it in — the provider is called only on a cache miss, inside `.task`
    /// (off the scroll-build frame). Call sites are unchanged: `ArtworkView(data: album.artworkData)`.
    private let dataProvider: () -> Data?
    var cacheKey: String?
    var cornerRadius: CGFloat = 8
    var size: CGFloat? = nil

    @State private var image: Image?

    init(data: @autoclosure @escaping () -> Data?, cacheKey: String? = nil,
         cornerRadius: CGFloat = 8, size: CGFloat? = nil) {
        self.dataProvider = data
        self.cacheKey = cacheKey
        self.cornerRadius = cornerRadius
        self.size = size
        // Seed from the decoded-image cache by the CHEAP key, WITHOUT reading the data, so a
        // known cover shows on the first frame and the row doesn't fault the blob to pass it.
        if let cacheKey, let box = artworkImageCache.object(forKey: cacheKey as NSString) {
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
        // Resolve off the row-build path: check the image cache by the cheap key; only call the
        // data provider (which may fault the SwiftData blob) on a miss, here on the main actor
        // but AFTER the row has been laid out — so fast scrolling never blocks on blob reads.
        // Re-runs whenever cacheKey changes (e.g. the mini-player on a track switch), so the
        // cover always reloads for the new id — cache hit is instant, miss reads the blob here.
        .task(id: cacheKey) {
            if let cacheKey, let box = artworkImageCache.object(forKey: cacheKey as NSString) {
                image = box.image
                return
            }
            guard let data = dataProvider() else { image = nil; return }
            let key: NSString? = cacheKey.map { $0 as NSString } ?? (String(data.hashValue) as NSString)
            image = await Self.decode(data, key: key)
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

    /// Decodes image bytes off the main actor and stores the result in the cache (cost =
    /// decoded pixel bytes, so the totalCostLimit can bound memory).
    private static func decode(_ data: Data, key: NSString?) async -> Image? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> (image: Image, cost: Int)? in
            #if os(iOS) || os(visionOS)
            guard let ui = UIImage(data: data) else { return nil }
            let cost = Int(ui.size.width * ui.scale * ui.size.height * ui.scale) * 4
            return (Image(uiImage: ui), cost)
            #elseif os(macOS)
            guard let ns = NSImage(data: data) else { return nil }
            let px = ns.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? Int(ns.size.width * ns.size.height)
            return (Image(nsImage: ns), px * 4)
            #else
            return nil
            #endif
        }.value
        guard let decoded else { return nil }
        if let key { artworkImageCache.setObject(ImageBox(decoded.image), forKey: key, cost: decoded.cost) }
        return decoded.image
    }
}
