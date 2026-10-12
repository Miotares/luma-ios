import AVFoundation
import Foundation
import Observation

/// Lyrics text as shown in the app. Lyrics often come in LRC form — every line prefixed with a
/// `[mm:ss.xx]` timestamp — so the raw text is parsed into lines with optional times. With times
/// the lyrics view follows playback line by line; without, it shows the plain text.
nonisolated struct LyricsText: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var time: TimeInterval?
        var text: String
    }

    let lines: [Line]

    /// True when the text carried timestamps (an LRC file / LRC text in the lyrics tag).
    var isSynced: Bool { lines.contains { $0.time != nil } }

    /// The lyrics without any timestamps.
    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    var isEmpty: Bool { lines.allSatisfy { $0.text.isEmpty } }

    init(_ raw: String) {
        var parsed: [Line] = []
        let timestamp = #/^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/#
        let metadataTag = #/^\[[A-Za-z#]+:[^\]]*\]\s*$/#   // [ar:…], [ti:…], [offset:…], …
        let offsetTag = #/^\[offset:\s*([+-]?\d+)\s*\]/#.ignoresCase()
        let wordTimestamp = #/<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>/#   // "enhanced" LRC, per word
        // `[offset:±ms]`: a positive value means the lyrics should appear EARLIER.
        var offset: TimeInterval = 0

        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            if let match = rest.firstMatch(of: offsetTag) {
                offset = (Double(match.1) ?? 0) / 1000
                continue
            }
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
            let text = rest.replacing(wordTimestamp, with: "").trimmingCharacters(in: .whitespaces)
            if times.isEmpty {
                parsed.append(Line(time: nil, text: text))
            } else {
                for time in times { parsed.append(Line(time: time, text: text)) }
            }
        }

        if parsed.contains(where: { $0.time != nil }) {
            if offset != 0 {
                parsed = parsed.map { Line(time: $0.time.map { max(0, $0 - offset) }, text: $0.text) }
            }
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

/// The lyrics of the track that is playing, loaded once per track and shared by everything that
/// needs them: the player's Lyrics button (shown only when there ARE lyrics) and the lyrics view.
@Observable
final class LyricsStore {
    /// The track `lyrics` belongs to — nil while nothing has been looked up yet.
    private(set) var trackID: UUID?
    /// nil = this track has no lyrics.
    private(set) var lyrics: LyricsText?
    /// The last few answers, so skipping back and forth doesn't re-read the files.
    private var cache: [UUID: LyricsText?] = [:]
    private var cacheOrder: [UUID] = []
    private var loading: UUID?

    /// Whether `track` is known to have lyrics (false until its lookup has finished).
    func hasLyrics(for track: Track?) -> Bool {
        guard let track, track.id == trackID else { return false }
        return lyrics != nil
    }

    /// Looks up the lyrics of `track`: text stored with the track (a `.lrc` file picked up at
    /// import), else the lyrics tag of the audio file, else a `.lrc`/`.txt` beside it.
    func load(for track: Track?) async {
        guard let track else {
            trackID = nil
            lyrics = nil
            return
        }
        let id = track.id
        if let known = cache[id] {
            trackID = id
            lyrics = known
            return
        }
        if trackID != id {
            // Don't keep showing the previous track's lyrics (or button) while this one is read.
            trackID = id
            lyrics = nil
        }
        guard loading != id else { return }   // already being read for another caller
        loading = id
        defer { if loading == id { loading = nil } }

        var raw = track.customLyrics
        if raw == nil, let url = try? track.resolveURL() {
            let scoped = url.startAccessingSecurityScopedResource()
            raw = await LyricsReader.lyrics(for: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let parsed = raw.map(LyricsText.init).flatMap { $0.isEmpty ? nil : $0 }
        cache[id] = .some(parsed)
        cacheOrder.append(id)
        if cacheOrder.count > 30 { cache[cacheOrder.removeFirst()] = nil }
        // Another track may have started while the file was being read.
        if trackID == id { lyrics = parsed }
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
