# Luma

A privacy-first, offline music player for iOS and iPadOS.

Import your own music library from the Files app — no account, no internet connection, no subscription required. All data stays on your device.

## Features

- **Lossless playback** — supports FLAC, ALAC, MP3, AAC, and WAV without quality loss
- **Library organization** — browse music by artist, album, and playlist
- **Queue management** — drag-to-reorder queue with persistent state
- **Playlists** — create and manage custom playlists
- **Listening statistics** — play counts, top songs, and favorite artists
- **System integration** — Control Center, Lock Screen, Siri, and AirPods support
- **Background playback** — continues playing when the screen is off or the app is backgrounded
- **Zero telemetry** — no analytics, no tracking, everything stays on device

## Requirements

- iOS 26.0+
- iPadOS 26.0+
- Xcode 26+

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 5.0 |
| UI | SwiftUI |
| Data | SwiftData |
| Audio | AVFoundation, MediaPlayer |
| Architecture | MVVM + `@Observable` |

## Project Structure

```
Luma/
├── App/                    # App container & dependency injection
├── Core/
│   ├── Audio/              # AudioPlayer, AudioSessionManager
│   ├── Queue/              # PlaybackQueue
│   ├── Storage/            # MediaStorage
│   └── SystemIntegration/  # NowPlayingManager, RemoteCommandHandler
├── Data/
│   ├── Models/             # Track, Album, Artist, Playlist (SwiftData models)
│   └── Repositories/       # LibraryRepository
├── Features/
│   ├── Import/             # ImportManager
│   ├── Metadata/           # MetadataParser, ArtworkCache
│   └── Colors/             # PaletteExtractor
└── UI/
    ├── Player/             # Full player & queue views
    ├── Library/            # Album, artist & playlist browsing
    ├── Search/
    ├── Import/
    ├── Settings/
    └── Components/         # Reusable components (MiniPlayer, TrackRow, …)
```

## Getting Started

1. Clone the repository
2. Open `Luma.xcodeproj` in Xcode
3. Select your target device or simulator
4. Build and run (`⌘R`)

No external dependencies or package setup required — the project uses only Apple frameworks.

## Privacy

Luma does not collect, transmit, or store any data outside of your device. Music files and metadata are processed locally and never leave your device.

## License

This project is for personal and educational use. All rights reserved.
