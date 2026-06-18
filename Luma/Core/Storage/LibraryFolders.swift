import Foundation
import Observation

/// Persisted list of user-chosen music folders for the macOS watched-folder library
/// (foobar model). Files inside these folders are referenced in place — never copied —
/// and the library is reconciled against them on every launch / rescan.
@Observable
final class LibraryFolders {
    private static let defaultsKey = "watchedLibraryFolders"

    private(set) var folders: [URL]

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        folders = paths.map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !folders.contains(where: { $0.path == standardized.path }) else { return }
        folders.append(standardized)
        persist()
    }

    func remove(_ url: URL) {
        folders.removeAll { $0.path == url.standardizedFileURL.path }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.defaultsKey)
    }
}
