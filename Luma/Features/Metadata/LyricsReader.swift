import AVFoundation
import Foundation

/// User setting for the lyrics feature.
nonisolated enum LyricsSettings {
    /// Whether the Lyrics button is offered in the player (default on).
    static let enabledKey = "lyricsEnabled"
}

/// Lyrics text as shown in the app. Lyrics often come in LRC form — every line prefixed with a
/// `[mm:ss.xx]` timestamp — so the raw text is parsed into lines with optional times. V1 shows
/// the plain lines; the times are kept so synced display can be added without re-reading anything.
nonisolated struct LyricsText: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var time: TimeInterval?
        var text: String
    }

    let lines: [Line]

    /// True when the text carried timestamps (an LRC file / LRC text in the lyrics tag).
    var isSynced: Bool { lines.contains { $0.time != nil } }

    /// The lyrics without any timestamps, as the user reads (and edits) them.
    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    var isEmpty: Bool { lines.allSatisfy { $0.text.isEmpty } }

    init(_ raw: String) {
        var parsed: [Line] = []
        let timestamp = #/^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/#
        let metadataTag = #/^\[[A-Za-z#]+:[^\]]*\]\s*$/#   // [ar:…], [ti:…], [offset:…], …

        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            if rest.firstMatch(of: metadataTag) != nil { continue }

            // One line can carry several timestamps ("[00:12.00][01:15.00]Chorus").
            var times: [TimeInterval] = []
            while let match = rest.firstMatch(of: timestamp) {
                let minutes = Double(match.1) ?? 0
                let seconds = Double(match.2) ?? 0
                let fraction = match.3.map { Double("0." + $0) ?? 0 } ?? 0
                times.append(minutes * 60 + seconds + fraction)
                rest = rest[match.range.upperBound...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            if times.isEmpty {
                parsed.append(Line(time: nil, text: text))
            } else {
                for time in times { parsed.append(Line(time: time, text: text)) }
            }
        }

        if parsed.contains(where: { $0.time != nil }) {
            // Repeated lines were expanded above — put everything back in playing order.
            // (Stable for untimed lines, which keep their place relative to their neighbours.)
            parsed = parsed.enumerated().sorted { a, b in
                switch (a.element.time, b.element.time) {
                case let (x?, y?) where x != y: return x < y
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }

        // Trim blank lines at both ends; keep the ones in between (they separate verses).
        while parsed.first?.text.isEmpty == true { parsed.removeFirst() }
        while parsed.last?.text.isEmpty == true { parsed.removeLast() }
        lines = parsed
    }
}

/// Reads the lyrics that ship WITH an audio file: embedded in its tags, or in a `.lrc` / `.txt`
/// file of the same name next to it.
///
/// Read on demand, when the lyrics are actually opened — nothing is copied into the library
/// database, so every track already in the library has its lyrics available without a re-import
/// and the track rows stay small.
nonisolated enum LyricsReader {
    static func lyrics(for url: URL) async -> String? {
        if let embedded = await embeddedLyrics(url: url) { return embedded }
        return sidecarLyrics(for: url)
    }

    static func embeddedLyrics(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        // iTunes-style files (M4A/ALAC) answer the dedicated property.
        if let direct = clean((try? await asset.load(.lyrics)) ?? nil) { return direct }

        // Everything else: look through all tags. ID3 "USLT" is the standard MP3 lyrics frame;
        // Vorbis comments (FLAC/Opus) use LYRICS / UNSYNCEDLYRICS; some taggers write a TXXX
        // user-text frame described as "lyrics…".
        guard let items = try? await asset.load(.metadata) else { return nil }
        var userText: String?
        for item in items {
            if item.identifier == .id3MetadataUnsynchronizedLyric || item.identifier == .iTunesMetadataLyrics {
                if let text = clean(try? await item.load(.stringValue)) { return text }
                continue
            }
            guard let key = (item.key as? String)?.uppercased() else { continue }
            switch key {
            case "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS":
                if let text = clean(try? await item.load(.stringValue)) { return text }
            case "TXXX":
                let attributes = (try? await item.load(.extraAttributes)) ?? [:]
                let description = (attributes[.info] as? String)?.lowercased() ?? ""
                if userText == nil, description.hasPrefix("lyrics") || description.hasPrefix("unsynced") {
                    userText = clean(try? await item.load(.stringValue))
                }
            default: break
            }
        }
        return userText
    }

    /// `<name>.lrc` or `<name>.txt` beside the audio file. Only reachable where the folder itself
    /// is readable — a folder import, or the macOS library that plays files in place.
    static func sidecarLyrics(for url: URL) -> String? {
        let base = url.deletingPathExtension()
        for ext in ["lrc", "txt"] {
            let candidate = base.appendingPathExtension(ext)
            guard let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 512 * 1024,
                  let data = try? Data(contentsOf: candidate) else { continue }
            // LRC files in the wild are UTF-8, UTF-16 or a legacy 8-bit encoding.
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
            if let text = clean(text) { return text }
        }
        return nil
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
