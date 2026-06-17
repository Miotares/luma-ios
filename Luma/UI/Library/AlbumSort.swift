import SwiftUI

/// Album sort options for the Mediathek "Alben" filter (the standalone AlbumsView was
/// retired in favour of LibraryView's filter system; this type is still used there).
enum AlbumSort: String, CaseIterable, Identifiable {
    case title, artist, year, dateAdded
    var id: Self { self }

    var label: String {
        switch self {
        case .title:     return String(localized: "Titel")
        case .artist:    return String(localized: "Künstler")
        case .year:      return String(localized: "Jahr")
        case .dateAdded: return String(localized: "Zuletzt hinzugefügt")
        }
    }

    var icon: String {
        switch self {
        case .title:     return "textformat.abc"
        case .artist:    return "music.microphone"
        case .year:      return "calendar"
        case .dateAdded: return "clock"
        }
    }
}

extension Album {
    /// Newest track-add date in the album — used for "Zuletzt hinzugefügt" sorting.
    var dateAdded: Date {
        tracks.map(\.addedDate).max() ?? .distantPast
    }
}
