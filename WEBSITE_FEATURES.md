# Luma: Feature- & Infoliste für die Website

> Stand: Juni 2026 · Quelle: aktueller Code-Stand (Branch `ios-app`).
> Diese Liste ist die Faktenbasis für Website-Texte, Feature-Tabellen, App-Store-Listing und SEO.
>
> **Screenshots:** Jeder Abschnitt nennt die passenden Screenshots mit einer stabilen Platzhalter-ID
> (z. B. `shot-player`). Die vollständige Übersicht aller IDs steht in Abschnitt 10. Der Website-Agent
> kann diese IDs als Bild-Platzhalter einbauen, die Bilddateien werden später nachgeliefert.

---

## 1. Was ist Luma? (Elevator Pitch)

**Luma ist ein Musikplayer für deine eigene, lokale Musiksammlung auf iPhone, iPad und Mac.**
Kein Account, keine Cloud, kein Abo, keine Internetverbindung. Du importierst deine Musikdateien aus der Dateien-App, und Luma sortiert sie automatisch nach Künstler und Album. Alles bleibt auf deinem Gerät.

**Für wen:** Menschen, die ihre Musik **besitzen** statt streamen wollen. Also alle mit einer eigenen Sammlung lokaler Dateien, FLAC- und HiFi-Fans, datenschutzbewusste Hörer sowie alle mit Musik außerhalb der großen Streamingdienste (Bandcamp-Käufe, eigene Rips, Bootlegs, DJ-Sets).

### Kernversprechen (3 Säulen)
1. **Besitzen statt streamen:** deine Dateien, deine Bibliothek, offline verfügbar.
2. **Verlustfreie Qualität:** FLAC, ALAC & Co. werden nativ und bit-perfect abgespielt.
3. **Echte Privatsphäre:** kein Tracking, keine Analytics, kein Server. Was auf dem Gerät ist, bleibt dort. **Open Source**, der Code ist öffentlich einsehbar.

**📸 Screenshots:** `shot-player` (Player-Vollansicht als Hero-Bild)

---

## 2. Headline-Vorschläge & Taglines (Website)

**Hero-Headlines:**
- „Deine Musik. Auf deinem Gerät. Sonst nirgends."
- „Für alle, die ihre Musik lieber besitzen als streamen."
- „Lokale Musik in voller Qualität, ganz ohne Account."
- „Der Musikplayer, der deine Sammlung respektiert."

**Sub-Taglines:**
- „Kein Account, keine Cloud, einfach nur Musik."
- „FLAC, ALAC, MP3 & mehr, nativ und verlustfrei."
- „Importieren, fertig. Kein Login, kein Abo, kein Tracking."

---

## 3. Vollständige Feature-Liste

### 🎵 Wiedergabe & Audio-Qualität
- **Verlustfreie / bit-perfekte Wiedergabe** lokaler Dateien
- **Unterstützte Formate:** FLAC, ALAC, MP3, AAC, M4A, WAV, AIFF, Opus
- **Echtes Gapless-Playback:** aufeinanderfolgende Titel ohne Lücke (eigene AVAudioEngine-Audio-Pipeline, kein hörbarer Übergang bei Live-Alben oder Mixes)
- **Cross-Fade:** stufenlos einstellbar von 0 bis 12 Sekunden (Titel werden ineinander übergeblendet)
- **10-Band-Equalizer** (grafisch) mit Presets: *Flach, Bass-Boost, Höhen, Stimme, Loudness* sowie ein frei einstellbarer „Custom"-Modus
  - Der EQ wird komplett umgangen (Bypass), wenn er aus oder „flach" ist, und **bleibt damit bit-perfect**, solange du den Klang nicht aktiv formst
- **Hintergrundwiedergabe:** läuft weiter bei gesperrtem Bildschirm oder im Hintergrund
- **Lautstärkeregelung** (persistent gespeichert)
- **Vor- und Zurückspulen** (15-Sekunden-Sprünge) sowie freies Scrubben und Seeken
- **Sleep-Timer:** 5, 10, 15, 30, 45, 60, 90 Minuten **oder** „bis Titelende", mit sanftem Ausblenden zum Schluss
- **Sitzung fortsetzen:** beim nächsten Start sind Warteschlange und Abspielposition genau wieder da (pausiert geparkt, unterbricht keine andere App)
- **Robuste Audio-Behandlung:** Anrufe und Unterbrechungen pausieren automatisch, beim Abziehen der Kopfhörer wird pausiert, Sample-Rate- und Routenwechsel werden sauber abgefangen

**📸 Screenshots:** `shot-player` (Player mit Cover, Scrubber, Transport), `shot-eq` (Equalizer mit Presets und Bändern), `shot-sleeptimer` (Sleep-Timer-Menü)

### 📚 Bibliothek & Organisation
- **Automatische Organisation** nach Künstler und Album beim Import (liest ID3- und iTunes-Metadaten, inklusive korrekter **Album-Artist-Behandlung** für Feature-Gäste)
- **Drei Ansichten:** Alben, Künstler, Songs
- **Album-Sortierung:** nach Titel, Künstler, Jahr oder „Zuletzt hinzugefügt"
- **Album-Layout** wählbar: Kachel-Raster oder Liste
- **Album-Detailansicht:** vollständige Trackliste (mit Disc- und Titelnummern), Laufzeit, großes Cover
- **Künstler-Detailansicht:** die komplette Discography eines Künstlers, alle Alben und Songs auf einer Seite
- **Liked Songs / Favoriten:** Titel mit einem Tipp liken und sofort wiederfinden
- **Suche** über Titel, Künstler und Alben gleichzeitig (mit eigenen Künstler- und Album-Ergebnissen)
- **Metadaten bearbeiten:** Titel, Künstler, Album, Titelnummer, Jahr und Genre pro Song anpassen

**📸 Screenshots:** `shot-library-albums` (Album-Raster), `shot-artist` (Künstler-Detail mit Discography), `shot-album` (Album-Detail mit Trackliste), `shot-search` (Suche mit Ergebnissen), optional `shot-miniplayer` (Bibliothek mit aktivem Mini-Player)

### ▶️ Warteschlange (Queue)
- **Frei sortierbare Warteschlange** per Drag & Drop
- **Shuffle** (an/aus) und **Repeat** (aus / alle / einer)
- **„Als Nächstes spielen"** und **„Zuletzt wiedergeben"** (ans Ende anhängen)
- **Warteschlange neu durchmischen** und **neu ordnen**
- **Warteschlange leeren**
- **Persistente Warteschlange:** bleibt über App-Neustarts hinweg erhalten

**📸 Screenshots:** `shot-queue` (Player mit offener Warteschlange, sichtbarem Drag-Griff)

### ✨ Smart-Playlists (automatisch, dynamisch)
Automatisch generierte Listen, ohne dass du etwas pflegen musst:
- **Meistgespielt**
- **Zuletzt gespielt**
- **Zuletzt hinzugefügt**
- **Liked**
- **Nach Genre** (Genre-Übersicht mit allen Genres deiner Sammlung)
- **Nach Jahrzehnt** (z. B. „1990er", „2000er")
- **Konfigurierbar:** jede Liste einzeln ein- und ausblenden, per Drag & Drop umsortieren, Gesamt-Schalter
- **Filter direkt in der Liste:** „Meistgespielt", „Liked" und Jahrzehnte lassen sich nach Genre filtern, eine Genre-Liste nach Jahrzehnt, z. B. „Rock aus den 80ern" (Mehrfachauswahl per Chips)

**📸 Screenshots:** `shot-smartplaylists` (Smart-Playlist-Kacheln im Playlists-Tab), `shot-smartfilter` (geöffnete Smart-Liste mit aktiven Filter-Chips, z. B. Genre)

### 🎨 Eigene Playlists
- **Erstellen, bearbeiten, verwalten** und manuell umsortieren
- **Songs hinzufügen** direkt über das Kontextmenü jedes Titels
- **Playlists an die Startseite anheften**
- **Individuelle Playlist-Cover** in drei Stilen:
  1. **Mosaik:** automatisch aus den ersten Titeln der Playlist
  2. **Foto:** eigenes Bild aus der Fotos-App (läuft datenschutzfreundlich „out-of-process", **kein Foto-Berechtigungs-Dialog**, EXIF- und GPS-Daten werden entfernt, **nichts wird hochgeladen**)
  3. **Generiertes Muster:** anpassbar nach Muster, Farbe, Textur und Symbol, optional mit Playlist-Titel
- **Playlist-Backup:** Playlists lassen sich sichern und wiederherstellen

**📸 Screenshots:** `shot-playlists` (Playlists-Übersicht mit Covern), `shot-cover-editor` (Cover-Editor mit den drei Stilen Mosaik / Foto / Muster)

### 📊 Hörstatistiken
- **Gesamte Hörzeit** (tatsächlich gehörte Sekunden, zählt auch teilweise gehörte oder abgebrochene Titel, nicht nur „Wiedergaben × Länge")
- **Gesamtzahl der Wiedergaben**
- **Top 10 Songs** (nach Wiedergaben)
- **Top 10 Künstler** (nach gehörten Minuten)
- **Bibliotheks-Übersicht:** Anzahl Songs, Alben, Künstler, Playlists
- Eine Wiedergabe zählt fair erst, wenn ein Titel wirklich gehört wurde (~30 % der Länge), nicht beim kurzen Antippen

**📸 Screenshots:** `shot-stats` (Statistik-Ansicht mit Hörzeit-Karte, Top Songs und Top Künstlern)

### 📥 Import
- **Einzelne Dateien oder ganze Ordner** aus der Dateien-App importieren (Ordner werden rekursiv durchsucht)
- **iCloud-Dateien** werden beim Import automatisch geladen
- **Fortschrittsanzeige** beim Import, **parallele Verarbeitung** (schnell auch bei 1000+ Dateien)
- **Doppelte werden erkannt** und übersprungen
- Importierte Titel werden **in die App kopiert**, die Wiedergabe greift nie mehr auf die Originaldatei zu (sauberes, eigenständiges Archiv)

**📸 Screenshots:** `shot-import` (Import aus der Dateien-App, gern mit sichtbarem Fortschritt)

### 🔗 System-Integration
- **Control Center & Sperrbildschirm:** Cover, Titelinfos, Play/Pause/Skip
- **Siri**-Steuerung
- **AirPods / Bluetooth:** Steuerung über die Kopfhörer
- **AirPlay:** Ausgabegerät direkt im Player wählen (AirPlay, Bluetooth-Lautsprecher etc.)
- Sperrbildschirm-Status bleibt zuverlässig synchron (auch nach Hintergrund oder Pause)

**📸 Screenshots:** `shot-lockscreen` (Sperrbildschirm oder Control Center mit laufendem Titel), optional `shot-airplay` (AirPlay-Auswahl im Player)

### 🖥️ Mac-Version (Desktop), *Coming soon*
Die Mac-Version ist **in Arbeit** und wird in Kürze folgen. Geplante Funktionen:
- **Referenz-Bibliothek im foobar2000-Stil:** Musikordner werden **an Ort und Stelle** eingebunden und beim Start gescannt, ganz **ohne Kopien**
- Ordner hinzufügen und entfernen, Bibliothek neu scannen
- **Menüleisten-Befehle & Tastenkürzel:** Ordner hinzufügen (⌘O), neu scannen (⌘R), nächster oder voriger Titel (⌘→ / ⌘←), Wiedergabe und Pause
- Eigene Now-Playing-Leiste

**📸 Screenshots:** `shot-mac` (sobald verfügbar). Bis dahin auf der Website als „Coming soon"-Block ohne Screenshot oder mit stilisierter Vorschau führen.

### ⚙️ Personalisierung & Einstellungen
- **5 App-Icons** zur Auswahl: Grün, Graphit, Hell, Blau, Violett
- **Start-Ansicht** wählbar (Mediathek oder Playlists)
- **Startseite anpassen:** Standard-Album-Layout, Abschnitt „Zuletzt hinzugefügt" ein- und ausblenden, Playlists anheften
- **Cross-Fade-Dauer** einstellen
- **Equalizer** ein- und ausschalten und Presets wählen
- **Smart-Playlists** in Sichtbarkeit und Reihenfolge konfigurieren
- **iCloud-Backup-Schalter:** importierte Titel optional ins iCloud-Backup einschließen (standardmäßig aus, um das Backup klein zu halten)
- **Speicherbelegung** wird angezeigt
- **Alle Titel löschen** (mit Bestätigung)

**📸 Screenshots:** `shot-appicons` (App-Icon-Auswahl), optional `shot-settings` (Einstellungen-Übersicht)

---

## 4. Datenschutz & Open Source (wichtigster Verkaufspunkt)

- **Kein Account, kein Login:** Luma funktioniert komplett ohne Registrierung
- **Keine Internetverbindung nötig:** die App braucht das Netz für nichts
- **Null Telemetrie:** keine Analytics, kein Tracking, keine Werbe-IDs
- **Keine Server, keine Cloud:** es werden keine Daten übertragen
- **Alles bleibt auf dem Gerät:** Musikdateien und Metadaten werden ausschließlich lokal verarbeitet
- **Fotos für Cover** werden datensparsam verarbeitet (out-of-process, ohne Foto-Berechtigung, EXIF und GPS entfernt)
- Enthält ein **Privacy-Manifest** (Apple `PrivacyInfo`)
- **Open Source:** Der komplette Quellcode ist öffentlich auf GitHub einsehbar. Jeder kann nachprüfen, dass Luma genau das tut, was es verspricht, und nicht mehr. Datenschutz zum Nachlesen statt nur zum Versprechen.
  - GitHub: https://github.com/Miotares/luma-ios

**Website-Formulierung:** „Luma sammelt keine Daten und überträgt nichts an Server. Was auf deinem Gerät ist, bleibt dort. Und weil Luma Open Source ist, kannst du das im Quellcode selbst nachlesen."

**📸 Screenshots:** kein App-Screenshot nötig. Empfehlung: GitHub-Badge / Open-Source-Logo und ein Vorhängeschloss-Icon als Trust-Symbole.

---

## 5. Technische Eckdaten & Anforderungen

| Punkt | Detail |
|---|---|
| Preis | **Einmalig 6,99 €** (bzw. der entsprechende Preis in der jeweiligen Landeswährung). **Kein Abo.** |
| Plattformen | iPhone, iPad (iOS/iPadOS **26.0+**). **Mac: coming soon.** |
| Open Source | Ja, Quellcode auf GitHub: https://github.com/Miotares/luma-ios |
| Sprachen | Deutsch, Englisch |
| Technologie | 100 % native Apple-Frameworks: SwiftUI, SwiftData, AVFoundation/AVAudioEngine, MediaPlayer |
| Fremd-Abhängigkeiten | Keine |
| Design | Dunkles, ruhiges UI |

**Differenzierung gegenüber Streaming-Apps:** einmaliger Kauf statt monatlicher Kosten, funktioniert offline, keine Algorithmen, keine Verfügbarkeits-Lücken (Titel verschwinden nie aus Lizenzgründen), volle Audioqualität deiner eigenen Dateien, quelloffen und nachprüfbar.

---

## 6. SEO-Keywords

**Deutsch:** musik player, offline musik, lokale musik, mp3 player iphone, flac player ios, musik ohne account, musikplayer ohne abo, hifi player, musiksammlung, datenschutz musik, alac, gapless player, open source musik player

**Englisch:** music player, offline music, local music player, flac player ios, mp3 player iphone, music without account, no subscription music player, hifi audio player, lossless music, gapless playback, privacy music app, open source music player

---

## 7. Vorschlag: Feature-Abschnitte für die Website (Reihenfolge)

| # | Block | Inhalt | Screenshots |
|---|---|---|---|
| 1 | **Hero** | „Deine Musik. Auf deinem Gerät." + Download-Button + Preis 6,99 € | `shot-player` |
| 2 | **Verlustfreie Qualität** | Formate (FLAC/ALAC/…), Gapless, Crossfade, EQ | `shot-eq`, `shot-player` |
| 3 | **Deine Sammlung, automatisch sortiert** | Alben/Künstler/Songs, Suche, Smart-Playlists | `shot-library-albums`, `shot-artist`, `shot-smartplaylists` |
| 4 | **Du bestimmst, was läuft** | Warteschlange, Playlists, eigene Cover | `shot-queue`, `shot-playlists`, `shot-cover-editor` |
| 5 | **Echte Privatsphäre & Open Source** | kein Account, kein Tracking, offline, Code auf GitHub (großer Trust-Block) | GitHub-Badge, Schloss-Icon |
| 6 | **Statistiken & Personalisierung** | Hörzeit, App-Icons, Startseite | `shot-stats`, `shot-appicons` |
| 7 | **Überall dabei** | iPhone, iPad, Control Center, AirPlay, Sleep-Timer + Mac „coming soon" | `shot-lockscreen`, `shot-mac` (später) |
| 8 | **FAQ** | siehe Abschnitt 9 | (kein Bild) |
| 9 | **Download** | App-Store-Badge + GitHub-Link | App-Store-Badge |

---

## 8. FAQ-Bausteine (für die Website)

**Was kostet Luma?**
Luma kostet einmalig 6,99 € (bzw. den entsprechenden Preis in deiner Landeswährung). Kein Abo, keine versteckten Kosten.

**Brauche ich einen Account?**
Nein. Luma funktioniert komplett ohne Registrierung und ohne Login.

**Brauche ich Internet?**
Nein. Nach dem Import deiner Dateien läuft alles offline.

**Welche Formate werden unterstützt?**
FLAC, ALAC, MP3, AAC, M4A, WAV, AIFF und Opus, also verlustfreie Formate ohne Qualitätsverlust.

**Wie kommt meine Musik in die App?**
Du importierst Dateien oder ganze Ordner aus der Dateien-App. Luma sortiert sie automatisch nach Künstler und Album.

**Werden meine Daten gesammelt?**
Nein. Keine Analytics, kein Tracking, keine Server. Alles bleibt auf deinem Gerät, und weil Luma Open Source ist, lässt sich das im Quellcode nachprüfen.

**Gibt es Luma für den Mac?**
Die Mac-Version ist in Arbeit und kommt bald.

**Läuft die Musik im Hintergrund oder auf dem Sperrbildschirm?**
Ja, inklusive Control Center, Sperrbildschirm, AirPods und AirPlay.

---

## 9. Screenshot-Übersicht (Platzhalter-IDs für den Website-Agenten)

Stabile IDs, damit der Website-Agent Platzhalter einbauen kann. Format-Empfehlung: iPhone-Hochformat-Mockups (Geräterahmen), Mac als Querformat.

| ID | Zeigt | Verwendet in Abschnitt(en) | Priorität |
|---|---|---|---|
| `shot-player` | Player-Vollansicht (Cover, Scrubber, Transport) | Hero, 1, 3 (Audio) | Hoch |
| `shot-eq` | Equalizer mit Presets und 10 Bändern | 3 (Audio), Website-Block 2 | Hoch |
| `shot-sleeptimer` | Sleep-Timer-Menü | 3 (Audio) | Mittel |
| `shot-library-albums` | Bibliothek als Album-Raster | 3 (Bibliothek) | Hoch |
| `shot-artist` | Künstler-Detail mit ganzer Discography | 3 (Bibliothek) | Hoch |
| `shot-album` | Album-Detail mit Trackliste und großem Cover | 3 (Bibliothek) | Mittel |
| `shot-search` | Suche mit Treffern (Songs/Künstler/Alben) | 3 (Bibliothek) | Mittel |
| `shot-miniplayer` | Bibliothek mit aktivem Mini-Player | 3 (Bibliothek) | Niedrig |
| `shot-queue` | Player mit offener Warteschlange | 3 (Warteschlange) | Hoch |
| `shot-smartplaylists` | Smart-Playlist-Kacheln im Playlists-Tab | 3 (Smart-Playlists) | Hoch |
| `shot-smartfilter` | Smart-Liste mit aktiven Filter-Chips | 3 (Smart-Playlists) | Mittel |
| `shot-playlists` | Playlists-Übersicht mit Covern | 3 (Playlists) | Hoch |
| `shot-cover-editor` | Cover-Editor (Mosaik / Foto / Muster) | 3 (Playlists) | Mittel |
| `shot-stats` | Statistiken (Hörzeit, Top Songs, Top Künstler) | 3 (Statistiken) | Hoch |
| `shot-import` | Import aus der Dateien-App, mit Fortschritt | 3 (Import) | Mittel |
| `shot-lockscreen` | Sperrbildschirm / Control Center mit Titel | 3 (System) | Mittel |
| `shot-airplay` | AirPlay-Geräteauswahl im Player | 3 (System) | Niedrig |
| `shot-appicons` | App-Icon-Auswahl (5 Varianten) | 3 (Personalisierung) | Mittel |
| `shot-settings` | Einstellungen-Übersicht | 3 (Personalisierung) | Niedrig |
| `shot-mac` | Mac-App (sobald verfügbar) | 3 (Mac), Website-Block 7 | Später |

> Die zehn App-Store-Motive aus `AppStore_Texte.md` decken bereits `shot-player`, `shot-library-albums`,
> `shot-queue`, `shot-artist`, `shot-stats`, `shot-playlists`, `shot-album`, `shot-search`,
> `shot-miniplayer` und `shot-import` ab. Neu für die Website wären vor allem `shot-eq`,
> `shot-smartplaylists`, `shot-cover-editor`, `shot-lockscreen` und `shot-appicons`.
