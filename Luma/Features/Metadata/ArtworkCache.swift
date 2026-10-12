import Foundation

/// Legacy cleanup. Earlier versions wrote a full-resolution copy of every album cover to
/// `Application Support/LumaArtwork/<albumID>.jpg` alongside the ~1024px thumbnail kept inline on
/// the Album row. Nothing ever read those files — every surface (rows, gallery, and even the
/// full-screen player, which `ArtworkView` caps at ~1024px) renders the inline thumbnail — so they
/// were a write-only disk leak that grew unbounded on the (iCloud-backed) Application Support
/// directory. The import sites no longer write them; this purges any left behind, exactly once.
nonisolated enum LegacyArtworkCleanup {
    private static let didPurgeKey = "didPurgeLegacyArtworkCache_v1"

    static func purgeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: didPurgeKey) else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("LumaArtwork", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.set(true, forKey: didPurgeKey)
    }
}
