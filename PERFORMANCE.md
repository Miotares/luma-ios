# Performance-Runbook: große Bibliotheken (1500+ Songs)

Dieses Dokument beschreibt die Performance-Probleme, die bei ~1500 Songs auftraten,
die **genaue Ursache** und den **exakten Fix** je Problem — plus die Diagnose-Methode,
mit der wir den Hauptschuldigen gefunden haben. Wenn die App sich wieder „schwammig"
anfühlt, lange lädt oder im Hintergrund das ganze Gerät ruckelt: **hier anfangen.**

Referenz-Commit: `perf: scale the library UI to large collections (1500+ songs)` (`89ded41`).

---

## 0. Erste Regel: messen, nicht raten

Wir haben uns mehrere Runden mit Vermutungen verrannt. Der Durchbruch kam erst mit
**Messung**. Das entscheidende Signal:

> **CPU ~0 %, aber die UI friert 1–3 s ein** → der Main-Thread **wartet** (I/O / Faulting)
> oder macht teure SwiftUI-Arbeit. NICHT „zu wenig Rechenleistung". Eine CPU-Spitze würde
> auf Rechenlast deuten; 0 % + Freeze deutet auf Blockierung/Re-Rendering.

### Diagnose-Werkzeug (temporär wieder einbauen)

Leg `Luma/Core/Diagnostics.swift` an (wird bei synchronisierten Xcode-Gruppen automatisch
kompiliert), starte `HangMonitor.shared.start()` in `LumaApp.init`, und streue
`LumaPerf.mark(...)` / `LumaPerf.measure(...)` / `let _ = LumaPerf.count("…")` in die
verdächtigen Stellen. **Aus Xcode starten** (Konsole: ⇧⌘C), eine ruckelnde Aktion ausführen,
die farbigen Zeilen lesen. **Nach der Diagnose wieder entfernen.**

```swift
import Foundation
import QuartzCore

// TEMPORARY perf diagnostics — remove after use.
enum LumaPerf {
    nonisolated(unsafe) static var lastMark = "—"
    nonisolated(unsafe) static var buildCounts: [String: Int] = [:]

    static func mark(_ label: String) {
        lastMark = label; buildCounts = [:]
        print("🔵 [perf] \(label)")
    }
    @discardableResult
    static func measure<T>(_ label: String, thresholdMs: Double = 20, _ work: () -> T) -> T {
        let start = CACurrentMediaTime()
        let result = work()
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms > thresholdMs { print("🟡 [perf] \(label): \(Int(ms))ms") }
        return result
    }
    @discardableResult
    static func count(_ type: String) -> Int {        // call at top of a row/card body
        let n = (buildCounts[type] ?? 0) + 1; buildCounts[type] = n; return n
    }
    static func buildsSummary() -> String {
        buildCounts.isEmpty ? "keine" : buildCounts.sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    }
}

/// Background watchdog: logs when the MAIN THREAD is blocked (UI frozen, CPU may read ~0 %).
final class HangMonitor {
    static let shared = HangMonitor()
    private let queue = DispatchQueue(label: "app.luma.hangmonitor", qos: .utility)
    func start() { queue.async { [weak self] in self?.loop() } }
    private func loop() {
        while true {
            let sem = DispatchSemaphore(value: 0)
            let start = CACurrentMediaTime()
            DispatchQueue.main.async { sem.signal() }
            if sem.wait(timeout: .now() + 0.2) == .timedOut {
                sem.wait()
                let ms = (CACurrentMediaTime() - start) * 1000
                print("🔴 [perf] MAIN-THREAD HANG \(Int(ms))ms — während: \(LumaPerf.lastMark) — gebaut: \(LumaPerf.buildsSummary())")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}
```

**Der Build-Zähler im `body` (`let _ = LumaPerf.count("TrackRow")`) ist der wichtigste Trick:**
er zeigt, wie viele View-Bodies pro Aktion gebaut werden. `TrackRow×1543` bei einem einzigen
Tap = gebrochene Lazy-Darstellung / Re-Render-Sturm (siehe §1).

---

## Symptome → Ursache (Schnellübersicht)

| Symptom | Wahrscheinliche Ursache | Abschnitt |
|---|---|---|
| Tippen auf Song / Play → UI ändert sich erst nach 1–2 s | TrackRow-Re-Render-Sturm | §1 |
| Scrollen ruckelt, CPU hoch (~180 %) | Artwork in voller Größe dekodiert | §2 |
| Tab-/View-Wechsel hängt, CPU ~0 % | SwiftData-Relationship-Faulting pro Zeile | §3 |
| Ganzes Gerät ruckelt bei Hintergrund-Wiedergabe | Stat-Save-`@Query`-Sturm + Timer | §4, §5 |
| Jede Play/Pause-Aktion fühlt sich träge an | Alle Tabs hängen an `state.isActive` | §6 |

---

## 1. ★ TrackRow-Re-Render-Sturm (der Hauptschuldige)

**Symptom:** Einen Song antippen → Audio startet sofort, aber die UI (Mini-Player,
Zeilen-Highlight) aktualisiert sich erst ~1,4 s später. `gebaut: TrackRow×1543` im Log.

**Ursache:** Jede `TrackRow` las `app.player.currentTrack` / `app.player.state.isPlaying`
direkt im `body`. Dadurch hing **jede** Zeile am Player; eine Wiedergabe-Änderung
invalidierte ALLE realisierten Zeilen, und ohne `Equatable` baute SwiftUI **alle ~1500
Zeilen-Bodies** neu auf.

**Fix:** Volatilen Status als **Wert** übergeben + Zeile `Equatable` machen + `.equatable()`.

```swift
struct TrackRow: View, Equatable {
    let track: Track
    var isCurrent = false      // vom Parent berechnet, NICHT hier aus app.player gelesen
    var isPlaying = false
    var liked = false          // Snapshot von track.isLiked (Wert → Equatable erkennt Änderung)
    // …

    static func == (l: TrackRow, r: TrackRow) -> Bool {
        l.track.persistentModelID == r.track.persistentModelID &&
        l.isCurrent == r.isCurrent && l.isPlaying == r.isPlaying && l.liked == r.liked &&
        l.selectionMode == r.selectionMode && l.isSelected == r.isSelected &&
        l.showArtwork == r.showArtwork && l.showAlbum == r.showAlbum &&
        l.showArtistName == r.showArtistName && l.showsMenu == r.showsMenu
    }
}
```

Jede Aufrufstelle berechnet den Status und wendet `.equatable()` an:

```swift
ForEach(sortedSongs) { track in
    TrackRow(track: track, showArtwork: true, showsMenu: true,
             isCurrent: track.id == app.player.currentTrack?.id,
             isPlaying: app.player.state.isPlaying,
             liked: track.isLiked) { playSong(track) }
        .equatable()
        // … weitere Modifier
}
```

**Aufrufstellen, die das brauchen:** `LibraryView` (Songs + Liked), `SearchView`,
`SmartPlaylistDetailView`, `PlaylistDetailView`, `AlbumDetailView`, `ArtistDetailView`,
`QueueView`.

**⚠️ Regression-Falle:** Niemals `app.player.*` zurück in den `TrackRow.body` holen — das
macht den Sturm sofort wieder auf. Der Equatable-Key schließt Closures + `@State` bewusst aus;
Titel-/Künstler-Umbenennungen (selten) aktualisieren erst bei Navigation, das ist ok.

---

## 2. Artwork in voller Auflösung für winzige Zeilen

**Symptom:** Scrollen ruckelt, CPU sehr hoch (~180 %), Speicher steigt.

**Ursache:** Cover liegen mit ~1024 px vor, wurden aber per `UIImage(data:)` in voller Größe
dekodiert — auch für eine 44-pt-Zeile (~4 MB Bitmap je Cover). Der NSCache war zu klein
(~24 Bilder) → beim Scrollen ständiges Neu-Dekodieren.

**Fix (`Luma/UI/Components/ArtworkView.swift`):** In **Anzeigegröße** dekodieren via ImageIO
(`CGImageSourceCreateThumbnailAtIndex`), Cache-Key nach Größe trennen, Decode mit `.utility`
(weicht der Wiedergabe).

```swift
// Zielgröße: size × 3 (für @3x), gedeckelt auf 1024; size==nil → maxPixel-Hinweis oder voll.
// Cache-Key: "<id>@<px>" — Zeilen-Thumbnail (~70 KB) verdrängt nicht das Vollbild des Players.
CGImageSourceCreateThumbnailAtIndex(src, 0, [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,   // Decode off-main erzwingen
    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
] as CFDictionary)
```

Galerie-Karten (`size: nil`, ~150 Stück) bekommen `maxPixel: 512`. Nur der Vollbild-Player
(`PlayerView`, `size: nil` ohne `maxPixel`) dekodiert voll. Gleiches Prinzip für
`PaletteExtractor` (32-px-Thumbnail statt Voll-Decode) und `NowPlayingManager`
(Sperrbildschirm-Cover wird **lazy, off-main** im Handler dekodiert, nicht beim Track-Wechsel).

---

## 3. SwiftData-Relationship-Faulting pro Zeile

**Symptom:** Tab-/View-Wechsel hängt 1–2 s bei CPU ~0 % (Warten auf SQLite).

**Ursache:** `track.album?.id` (Artwork-Key in jeder `TrackRow`) und
`validEntryTrackMap`/`ArtistListRow` greifen auf nicht geladene Beziehungen zu → SwiftData
„faultet" sie **pro Zeile einzeln** aus der DB (bis zu 1500 Einzel-Queries auf dem Main-Thread).

**Fix:** Beziehungen, die Zeilen lesen, im `@Query` **vorab laden**
(`relationshipKeyPathsForPrefetching`) — ein gebündelter Ladevorgang statt N Faults.

```swift
// Luma/UI/Library/PlaylistsView.swift
func tracksRowDescriptor(sortByTitle: Bool = false, prefetchEntries: Bool = true) -> FetchDescriptor<Track> {
    var d = FetchDescriptor<Track>(sortBy: sortByTitle ? [SortDescriptor(\.title)] : [])
    d.relationshipKeyPathsForPrefetching = prefetchEntries ? [\.album, \.playlistEntries] : [\.album]
    return d
}
func artistsRowDescriptor() -> FetchDescriptor<Artist> {
    var d = FetchDescriptor<Artist>(sortBy: [SortDescriptor(\.name)])
    d.relationshipKeyPathsForPrefetching = [\.albums, \.tracks]
    return d
}
```

Verwendet von den `@Query`s in `LibraryView`, `PlaylistsView`, `PlaylistDetailView`,
`SearchView`, `SmartPlaylists`, sowie `recentTracksDescriptor` (`[\.album]`) und
`LikedSongsView.likedDescriptor` (`[\.album]`).

> `Album.artworkData` ist `@Attribute(.externalStorage)` — `\.album` vorzuladen zieht nur die
> kleinen Album-Zeilen, NICHT die Cover-Blobs.

---

## 4. Stat-Save-`@Query`-Invalidierungssturm (Hintergrund-Ruckeln)

**Symptom:** Während der Wiedergabe (auch im Hintergrund) ruckelt das ganze Gerät periodisch.

**Ursache:** Der Haupt-`ModelContext` hat **Autosave standardmäßig an**. Schon das Hochzählen
von `playCount`/`listenSeconds` speicherte am Runloop-Ende → **jedes lebende `@Query`** wurde
neu ausgeführt (alle Tabs sind gleichzeitig gemountet). `addListenTime` feuerte alle ~60 s.

**Fix:**
- `AppContainer.init`: `modelContext.autosaveEnabled = false`.
- `LibraryRepository.recordPlay` / `addListenTime`: **nur mutieren, NICHT speichern**.
- Speichern gebündelt an Lebenszyklus-Grenzen: `AudioPlayer.onStatsShouldPersist` (in
  `pause()`/`stop()`) → `LibraryRepository.saveStats()`, und `AppContainer.saveStats()` aus
  `LumaApp` bei scenePhase ≠ `.active`.
- `toggleLike` **behält** sein `save()` (Liked-Tab muss sofort aktualisieren).

> **Sicher**, weil ALLE anderen Mutationen ohnehin explizit über `LibraryRepository` speichern
> (kein UI-Code mutiert Modelle und verlässt sich auf Autosave). Trade-off: ein Absturz mitten
> in langer Hintergrund-Wiedergabe verliert die letzte Hör-Differenz — für Play-Stats ok.
> **Warum kein `@ModelActor`:** ein Save auf demselben Container merged trotzdem in den
> Haupt-Context und triggert `@Query`. Coalescing ist der saubere Gewinn.

---

## 5. Anzeige-Timer & Now-Playing im Hintergrund

- `AudioPlayer.displayTick` (0,2 s) schreibt `currentTime` jetzt nur im **Vordergrund**
  (`isForeground`-Gate) — im Hintergrund gibt es keinen sichtbaren Scrubber, aber die
  Gapless/Crossfade-Logik läuft weiter. (iOS-only; macOS-Fenster bleibt sichtbar.)
- 60-s-Listen-Flush **entfernt**; Gapless-Boundary (`handleBoundary`) flusht jetzt die Hörzeit,
  bevor `currentTrack` neu gesetzt wird (war ein Bug: Sekunden gingen verloren / falsch
  zugeordnet).
- `maybePersistProgress` 5 s → 20 s (Queue-Snapshot mappt sonst zu oft tausende UUIDs).
- `NowPlayingManager.update` wird nur bei **Statuswechseln** aufgerufen, nicht pro Tick (war
  schon so — nicht kaputt machen).

---

## 6. Coarse `isActive`-Flag (Play/Pause-Churn)

**Symptom:** Jede Play/Pause-Aktion fühlt sich träge an.

**Ursache:** Viele View-Bodies lasen `app.player.state.isActive` (Mini-Player-Sichtbarkeit,
`lumaScrollClearance`). Observation verfolgt `state` — das ändert sich bei play↔pause, auch
wenn `isActive` (≠ `.stopped`) gleich bleibt → **alle Tabs re-evaluierten**.

**Fix:** Eigenes, **gestütztes** Flag `AudioPlayer.isActive`, das nur am Übergang
`stopped ↔ aktiv` umschaltet (gesetzt in `startPlayback` / `stop()`). Alle View-Reads nutzen
`app.player.isActive` statt `app.player.state.isActive`. (Interne Player-Logik darf
`state.isActive` behalten.)

---

## Goldene Regeln (Checkliste bei neuen Listen/Views)

1. **List-/ForEach-Zeile, die einen häufig wechselnden `@Observable` liest (Player-Status):**
   → Zeile `Equatable` machen + Status als Wert übergeben + `.equatable()`. Sonst rendern bei
   jeder Änderung ALLE Zeilen neu.
2. **In SwiftData-Listen jede Beziehung vorladen, die der Zeilen-`body` anfasst**
   (`relationshipKeyPathsForPrefetching`). Pro-Zeile-Faulting = 0 % CPU + Freeze.
3. **Bilder in Anzeigegröße dekodieren** (ImageIO-Thumbnail), Cache-Key inkl. Größe. Nie das
   Vollbild für eine 44-pt-Zeile.
4. **Keine hochfrequenten Saves auf dem UI-`ModelContext`.** Autosave aus; bündeln auf
   Lebenszyklus-Grenzen. Alle Mutationen explizit über `LibraryRepository`.
5. **Keine coarse Bools aus fein-granularen Observables ableiten, die viele Bodies lesen.**
   Eigenes, gestütztes Flag, das nur bei echter Änderung umschaltet.
6. **Bei „0 % CPU, aber friert ein": SOFORT messen** (HangMonitor + Build-Zähler), nicht raten.

---

## Noch offen (optional, mit Vorsicht)

- **SwiftData `#Index`** auf Sortier-/Filterfelder (`Track.title`, `addedDate`, `playCount`,
  `lastPlayedDate`, `isLiked`). Größter Rest-Hebel für View-**Ladezeiten** (aktuell null
  Indizes → jede sortierte Query ist ein Full-Scan). **Aufgeschoben:** löst eine SwiftData-
  Migration der einzigen Bibliothekskopie aus, die hier nicht testbar ist → nur mit Backup.
- **Import läuft auf dem Haupt-`ModelContext`** (`ImportManager`): Inserts + Saves alle 50 →
  `@Query`-Sturm während des Imports. Fix: `autosaveEnabled = false` + große Batches, oder auf
  das `@ModelActor`-Muster von `FolderLibraryScanner` migrieren.
- **Alle vier Tabs gleichzeitig gemountet** (iOS 26 `TabView`): jeder hält eine eigene
  `@Query<Track>` über 1500 Songs (3–4× Materialisierung bei Launch/Änderung). Struktureller
  Rest-Posten, größerer Umbau.
