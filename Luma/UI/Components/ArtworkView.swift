import SwiftUI
import ImageIO

/// In-memory cache of decoded artwork images so re-mounting a cover (scrolling, a library
/// refresh) is instant. The cache is keyed by a CHEAP stable string (the caller passes the
/// album/track UUID, plus the decode size) — never by the raw image Data, whose hash/equality
/// is O(bytes) and was hashing multi-megabyte covers on the main thread on every lookup.
private final class ImageBox {
    let image: Image
    init(_ image: Image) { self.image = image }
}

nonisolated(unsafe) private let artworkImageCache: NSCache<NSString, ImageBox> = {
    let cache = NSCache<NSString, ImageBox>()
    cache.countLimit = 2000
    cache.totalCostLimit = 96 * 1024 * 1024 // ~96 MB of decoded bitmaps — bounds memory growth.
    // With size-matched thumbnails (a 44pt row cover is now ~70 KB, not ~4 MB) this holds the
    // whole library's row covers many times over, so scrolling never re-decodes.
    return cache
}()

/// Serializes + DEDUPES cover decodes so they can't peg the CPU against the real-time audio render
/// thread. Two problems the on-device logs exposed while a track played:
///  (1) the SAME cover was decoded several times IN PARALLEL (e.g. now-playing shown in 3 places →
///      3 identical ImageIO decodes, ~1.2 s each cold) — pure waste that saturated the cores and
///      starved the render thread into an underrun (the "last buffer repeats" artifact);
///  (2) a queue/list reveal fired a screenful of decodes at once.
/// Fix: cap concurrency low AND coalesce same-key decodes into one shared task; the actual decode
/// runs at `.background` so it yields to playback. Covers appear a touch later cold — inaudible win.
private actor ArtworkDecodeLimiter {
    static let shared = ArtworkDecodeLimiter(limit: 2)
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// In-flight decodes keyed by cache key, so N callers wanting the same cover share ONE decode.
    private var inFlight: [NSString: Task<Image?, Never>] = [:]

    init(limit: Int) { self.limit = limit }

    private func acquire() async {
        if active < limit { active += 1; return }
        // No free slot: park until a release hands one over (the slot transfers, so `active`
        // stays at `limit` rather than being re-incremented here).
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().resume() }   // hand the slot straight to the next waiter
    }

    /// Concurrency-capped, deduped decode. `inFlight[key]` is set before the first `await`, so a
    /// concurrent caller for the same key awaits the SAME task instead of starting a duplicate.
    func decode(key: NSString?, data: Data, maxPixel: Int?) async -> Image? {
        if let key, let existing = inFlight[key] { return await existing.value }
        let task = Task<Image?, Never> {
            await self.acquire()
            let image = await ArtworkView.rawDecode(data, maxPixel: maxPixel, key: key)
            self.release()   // same-actor (the Task inherits this actor's isolation) → no await
            return image
        }
        if let key { inFlight[key] = task }
        let result = await task.value
        if let key { inFlight.removeValue(forKey: key) }
        return result
    }
}

struct ArtworkView: View {
    /// The bytes are provided lazily (autoclosure) so a row NEVER faults the SwiftData artwork
    /// blob just to pass it in — the provider is called only on a cache miss, inside `.task`
    /// (off the scroll-build frame). Call sites are unchanged: `ArtworkView(data: album.artworkData)`.
    private let dataProvider: () -> Data?
    var cacheKey: String?
    var cornerRadius: CGFloat = 8
    var size: CGFloat? = nil
    /// Optional explicit decode ceiling (long edge, px). Use for views that fill their
    /// container (`size == nil`) but don't need the full ~1024px source — e.g. the album
    /// gallery card. When nil, the target is derived from `size`; if both are nil the cover is
    /// decoded at full resolution (the full-screen player).
    var maxPixel: Int? = nil

    @State private var image: Image?

    init(data: @autoclosure @escaping () -> Data?, cacheKey: String? = nil,
         cornerRadius: CGFloat = 8, size: CGFloat? = nil, maxPixel: Int? = nil) {
        self.dataProvider = data
        self.cacheKey = cacheKey
        self.cornerRadius = cornerRadius
        self.size = size
        self.maxPixel = maxPixel
        // Seed from the decoded-image cache by the CHEAP (size-bucketed) key, WITHOUT reading
        // the data, so a known cover shows on the first frame and the row doesn't fault the blob.
        if let key = Self.resolvedKey(cacheKey, size: size, maxPixel: maxPixel),
           let box = artworkImageCache.object(forKey: key) {
            _image = State(initialValue: box.image)
        }
    }

    var body: some View {
        // A neutral Color.clear — NOT the image — defines this view's layout size, so the
        // box is exactly `size`×`size` (or, when size == nil, exactly the square the parent
        // proposes via `.aspectRatio(1, .fit)`). The cover is rendered as a clipped overlay:
        // `scaledToFill` reports a NON-square size for a not-perfectly-square cover, and if
        // that drove layout (as it did when the image was the primary view) the box width
        // drifted per album — visibly resizing the full-screen player and nudging its
        // controls apart on every cross-album song switch.
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Resolve off the row-build path: check the image cache by the cheap key; only call the
        // data provider (which may fault the SwiftData blob) on a miss, then DECODE AT THE
        // DISPLAY SIZE off-main. Decoding the full ~1024px cover for a 44pt row saturated the CPU
        // while scrolling and thrashed the cache; a size-matched thumbnail is ~60× cheaper.
        // Re-runs whenever cacheKey changes (e.g. the mini-player on a track switch).
        .task(id: cacheKey) {
            let key = Self.resolvedKey(cacheKey, size: size, maxPixel: maxPixel)
            if let key, let box = artworkImageCache.object(forKey: key) {
                image = box.image
                return
            }
            guard let data = dataProvider() else { image = nil; return }
            image = await Self.decode(data, maxPixel: Self.targetPixel(size: size, maxPixel: maxPixel), key: key)
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

    /// Target decode ceiling (long edge, px) for this view. `nil` means decode at full
    /// resolution (no `size`/`maxPixel` hint — the full-screen player).
    private static func targetPixel(size: CGFloat?, maxPixel: Int?) -> Int? {
        if let maxPixel { return maxPixel }
        guard let size else { return nil }
        // Decode for the densest backing scale the platform actually has: @3x on iOS, but macOS
        // tops out at @2x — decoding ×3 there inflated every cover ~2.25× past what's displayed,
        // burning CPU and filling the bitmap cache that much faster. Clamp to the stored ~1024px.
        #if os(macOS)
        let scale: CGFloat = 2
        #else
        let scale: CGFloat = 3
        #endif
        return min(1024, Int((size * scale).rounded(.up)))
    }

    /// Cache key = base id + the decode bucket, so a row's 132px thumbnail and the full-screen
    /// player's full image are separate entries instead of overwriting each other.
    private static func resolvedKey(_ base: String?, size: CGFloat?, maxPixel: Int?) -> NSString? {
        guard let base else { return nil }
        if let px = targetPixel(size: size, maxPixel: maxPixel) { return "\(base)@\(px)" as NSString }
        return "\(base)@full" as NSString
    }

    /// Decodes image bytes off the main actor at (at most) `maxPixel` on the long edge, via
    /// ImageIO thumbnailing — which decodes the source at the reduced size instead of inflating
    /// the full bitmap. Stores the result in the cache (cost = decoded pixel bytes, so the
    /// totalCostLimit can bound memory). Runs at `.utility` so a burst of cover decodes during
    /// fast scrolling yields to user-initiated work like starting playback.
    private static func decode(_ data: Data, maxPixel: Int?, key: NSString?) async -> Image? {
        // Route through the limiter so concurrency is capped and same-key decodes are deduped.
        await ArtworkDecodeLimiter.shared.decode(key: key, data: data, maxPixel: maxPixel)
    }

    /// The actual ImageIO decode (off-main at `.utility`) + cache write. Called ONLY via
    /// `ArtworkDecodeLimiter.decode` so it is concurrency-capped and deduped (so the same cover is
    /// never decoded by several views at once).
    fileprivate static func rawDecode(_ data: Data, maxPixel: Int?, key: NSString?) async -> Image? {
        let decoded = await Task.detached(priority: .utility) { () -> (image: Image, cost: Int)? in
            guard let cg = Self.cgImage(from: data, maxPixel: maxPixel) else { return nil }
            let cost = cg.width * cg.height * 4
            #if os(iOS) || os(visionOS)
            return (Image(uiImage: UIImage(cgImage: cg)), cost)
            #elseif os(macOS)
            return (Image(nsImage: NSImage(cgImage: cg, size: .zero)), cost)
            #else
            return nil
            #endif
        }.value
        guard let decoded else { return nil }
        if let key { artworkImageCache.setObject(ImageBox(decoded.image), forKey: key, cost: decoded.cost) }
        return decoded.image
    }

    /// ImageIO decode. With `maxPixel` set, decodes a thumbnail at that long-edge size (cheap);
    /// otherwise decodes the full image. `shouldCacheImmediately` forces the bitmap decode to
    /// happen here (off-main) rather than lazily on the first render frame.
    private nonisolated static func cgImage(from data: Data, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
