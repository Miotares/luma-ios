import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Actor provides thread-safe access from both MainActor (UI) and detached tasks (import pipeline).
actor ArtworkCache {
    private let memCache = NSCache<NSString, AnyObject>()
    private let diskURL: URL

    static let shared = ArtworkCache()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        diskURL = support.appendingPathComponent("LumaArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        memCache.countLimit = 200
        memCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
    }

    func store(_ data: Data, for id: UUID) {
        let key = id.uuidString as NSString
        let fileURL = diskURL.appendingPathComponent(id.uuidString + ".jpg")
        try? data.write(to: fileURL, options: .atomic)
        #if os(iOS) || os(visionOS)
        if let img = UIImage(data: data) {
            memCache.setObject(img, forKey: key, cost: data.count)
        }
        #elseif os(macOS)
        if let img = NSImage(data: data) {
            memCache.setObject(img, forKey: key, cost: data.count)
        }
        #endif
    }

    func data(for id: UUID) -> Data? {
        let fileURL = diskURL.appendingPathComponent(id.uuidString + ".jpg")
        return try? Data(contentsOf: fileURL)
    }

    func hasArtwork(for id: UUID) -> Bool {
        let fileURL = diskURL.appendingPathComponent(id.uuidString + ".jpg")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func deleteArtwork(for id: UUID) {
        let key = id.uuidString as NSString
        memCache.removeObject(forKey: key)
        let fileURL = diskURL.appendingPathComponent(id.uuidString + ".jpg")
        try? FileManager.default.removeItem(at: fileURL)
    }

    #if os(iOS) || os(visionOS)
    func image(for id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let cached = memCache.object(forKey: key) as? UIImage { return cached }
        guard let data = data(for: id), let img = UIImage(data: data) else { return nil }
        memCache.setObject(img, forKey: key, cost: data.count)
        return img
    }
    #elseif os(macOS)
    func image(for id: UUID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = memCache.object(forKey: key) as? NSImage { return cached }
        guard let data = data(for: id), let img = NSImage(data: data) else { return nil }
        memCache.setObject(img, forKey: key, cost: data.count)
        return img
    }
    #endif
}
