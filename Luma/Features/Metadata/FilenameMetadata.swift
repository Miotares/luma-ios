import Foundation

/// Best-effort metadata derived from a file NAME. Used only for the fields a file's tags don't
/// provide — an untagged "Artist - Title.mp3" should import as that, not as the UUID the
/// container copy is stored under.
nonisolated enum FilenameMetadata {
    struct Guess: Equatable, Sendable {
        var title: String
        var artist: String?
        var trackNumber: Int?
    }

    /// True when `name` is one of our own container filenames (a bare UUID) rather than a name a
    /// person gave the file.
    static func isPlaceholderName(_ name: String) -> Bool {
        UUID(uuidString: name.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// `stem` is the filename without its extension.
    static func guess(fromStem stem: String) -> Guess {
        let cleaned = collapseWhitespace(stem.replacingOccurrences(of: "_", with: " "))
        var rest = cleaned
        var trackNumber = stripLeadingTrackNumber(&rest, allowBareZeroPadded: true)

        var artist: String?
        if let split = splitArtistTitle(rest) {
            artist = split.artist
            rest = split.title
            // "Artist - 01 - Title": the number sits between the two.
            if trackNumber == nil {
                trackNumber = stripLeadingTrackNumber(&rest, allowBareZeroPadded: false)
            }
        }

        let title = rest.isEmpty ? cleaned : rest
        return Guess(title: title, artist: artist, trackNumber: trackNumber)
    }

    // MARK: - Private

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Removes a leading track number ("01. ", "01 - ", "3) ", "1-03 ", "07 ") and returns it.
    /// A bare number followed only by a space counts only when zero-padded or disc-prefixed, so
    /// titles that START with a number ("99 Luftballons", "21 Guns", "1979") stay intact.
    private static func stripLeadingTrackNumber(_ s: inout String, allowBareZeroPadded: Bool) -> Int? {
        let explicit = #/^(?:\d{1,2}-)?(\d{1,3})\s*(?:\.(?!\d)|\)|\s[-–—](?=\s))\s*/#
        if let m = s.firstMatch(of: explicit), let n = Int(m.1), m.range.upperBound < s.endIndex {
            s = String(s[m.range.upperBound...])
            return n
        }
        guard allowBareZeroPadded else { return nil }
        let bare = #/^(?:\d{1,2}-(\d{1,3})|(0\d{1,2}))\s+/#
        if let m = s.firstMatch(of: bare), let n = Int(m.1 ?? m.2 ?? ""), m.range.upperBound < s.endIndex {
            s = String(s[m.range.upperBound...])
            return n
        }
        return nil
    }

    /// Splits "Artist - Title" at the FIRST spaced dash (hyphen, en or em dash).
    private static func splitArtistTitle(_ s: String) -> (artist: String, title: String)? {
        guard let m = s.firstMatch(of: #/\s[-–—]\s/#) else { return nil }
        let artist = s[..<m.range.lowerBound].trimmingCharacters(in: .whitespaces)
        let title = s[m.range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return (artist, title)
    }
}
