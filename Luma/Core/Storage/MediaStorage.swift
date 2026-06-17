import Foundation

/// Manages the on-device copy of imported audio files (the "Doppler model").
///
/// Files live in `Application Support/Media/<uuid>.<ext>`. The app-managed
/// directory is not visible in the user's Files picker. Tracks store only the
/// relative filename — never an absolute path or security-scoped bookmark — so
/// playback works offline and survives app updates / container path changes.
// Pure file I/O — explicitly nonisolated so copies/downloads run off the main actor
// (the project defaults types to @MainActor).
nonisolated enum MediaStorage {
    static let backupDefaultsKey = "backupMediaToICloud"

    enum StorageError: LocalizedError {
        case missingFile
        var errorDescription: String? {
            switch self {
            case .missingFile: return "Die Audiodatei wurde nicht gefunden."
            }
        }
    }

    /// The directory holding all imported audio, created on first access.
    static var mediaDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            setExcludedFromBackup(!backupEnabled, on: dir)
        }
        return dir
    }

    /// Copies an external file into the media container and returns its relative
    /// filename. The caller must already hold security-scoped access to `sourceURL`.
    ///
    /// Note: this blocks while an iCloud file downloads, so callers run it off the
    /// main actor with bounded concurrency.
    static func importFile(from sourceURL: URL) throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(filename)

        // iCloud Drive files arrive as dataless placeholders. Kick off the download
        // and use a coordinated read, which blocks until the provider materializes
        // the data — a plain copyItem would fail or copy an empty placeholder.
        let values = try? sourceURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let needsDownload = (values?.isUbiquitousItem ?? false)
            && values?.ubiquitousItemDownloadingStatus != .current

        if needsDownload {
            try? FileManager.default.startDownloadingUbiquitousItem(at: sourceURL)
            try coordinatedCopy(from: sourceURL, to: destination)
            return filename
        }

        do {
            // Direct copy works for local files and security-scoped folder children
            // (the parent folder's held access covers them). NSFileCoordinator can
            // fail on such inherited scopes, so try the plain path first.
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination) // clean any partial
            try coordinatedCopy(from: sourceURL, to: destination)
        }
        return filename
    }

    /// Coordinated read that materializes not-yet-downloaded cloud files, then copies.
    private static func coordinatedCopy(from sourceURL: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { readURL in
            do {
                try? FileManager.default.removeItem(at: destination) // clear any partial
                try FileManager.default.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let copyError { throw copyError }
        if let coordinatorError { throw coordinatorError }
    }

    /// Resolves a stored filename to its current on-disk URL.
    static func url(for filename: String) -> URL {
        mediaDirectory.appendingPathComponent(filename)
    }

    static func delete(filename: String) {
        try? FileManager.default.removeItem(at: mediaDirectory.appendingPathComponent(filename))
    }

    /// Total bytes used by imported media — shown in Settings.
    static var totalBytes: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return urls.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - iCloud Backup

    /// Whether imported media is included in iCloud backups. Default: false.
    static var backupEnabled: Bool {
        UserDefaults.standard.bool(forKey: backupDefaultsKey)
    }

    /// Re-applies the current backup preference to the media directory.
    static func updateBackupExclusion() {
        setExcludedFromBackup(!backupEnabled, on: mediaDirectory)
    }

    private static func setExcludedFromBackup(_ excluded: Bool, on url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? target.setResourceValues(values)
    }
}
