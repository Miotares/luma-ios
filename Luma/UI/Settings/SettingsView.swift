import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @Environment(AppContainer.self) private var app
    /// Library totals. Loaded when the screen appears and after the actions that change them —
    /// NOT as live queries: this tab stays mounted, and four unfiltered `@Query`s here re-read the
    /// whole library (album covers included) on every save anywhere in the app.
    @State private var stats = LibraryStats()
    @State private var showingDeleteConfirm = false
    @State private var showingImport = false
    @State private var showingEqualizer = false
    @State private var showingSmartSettings = false
    @State private var showingHomeSettings = false
    @State private var storageBytes: Int64 = 0
    #if os(iOS)
    @State private var currentIconName: String?
    #endif
    @AppStorage(MediaStorage.backupDefaultsKey) private var backupEnabled = false
    @AppStorage(AudioPlayer.crossfadeDefaultsKey) private var crossfade: Double = 0
    @AppStorage(LoudnessService.enabledKey) private var normalizeVolume = true
    @AppStorage(LyricsSettings.enabledKey) private var lyricsEnabled = true
    @AppStorage(QueueSwipeSettings.fullSwipeAddsLastKey) private var fullSwipeAddsLast = false
    @AppStorage(MainTabView.startupTabKey) private var startupTab = LumaTab.library.rawValue
    #if os(macOS)
    @AppStorage(LumaAppearance.storageKey) private var macAppearance = LumaAppearance.system.rawValue
    /// Non-nil holds the result message of a duplicate-removal pass (drives a result alert).
    @State private var dedupResult: String?
    #endif

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    #if os(macOS)
                    sectionLabel("Musikordner")
                    folderBlock
                    sectionLabel("Darstellung")
                    appearanceBlock
                    #else
                    sectionLabel("Import")
                    importBlock
                    #endif
                    sectionLabel("Allgemein")
                    startBlock
                    homeBlock
                    smartPlaylistsBlock
                    #if os(iOS)
                    sectionLabel("App-Icon")
                    appIconBlock
                    #endif
                    sectionLabel("Wiedergabe")
                    crossfadeBlock
                    normalizeBlock
                    equalizerBlock
                    lyricsBlock
                    #if os(iOS)
                    swipeBlock
                    #endif
                    sectionLabel("Mediathek")
                    statsBlock
                    #if os(iOS)
                    sectionLabel("Speicher")
                    storageBlock
                    #endif
                    sectionLabel("Tools")
                    toolsBlock
                    sectionLabel("App")
                    appBlock
                    sectionLabel("Daten")
                    #if os(macOS)
                    dedupBlock
                    #endif
                    dangerBlock
                    Text("Entfernt alle Titel, Alben und Künstler samt der importierten Audiodateien.")
                        .font(.caption)
                        .foregroundStyle(.lumaInk(0.35))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                }
            }
            .lumaScrollClearance(playerActive: app.player.isActive)
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: StatisticsRoute.self) { _ in StatisticsView() }
        .sheet(isPresented: $showingImport) { ImportView() }
        .sheet(isPresented: $showingEqualizer) { EqualizerView() }
        .sheet(isPresented: $showingSmartSettings) { SmartPlaylistSettingsView() }
        .sheet(isPresented: $showingHomeSettings) { HomeSettingsView() }
        .task { await loadStorageUsage() }
        .onAppear { reloadStats() }
        .onChange(of: app.importManager.isImporting) { _, importing in if !importing { reloadStats() } }
        .onChange(of: app.folderScanner.isScanning) { _, scanning in if !scanning { reloadStats() } }
        .alert("Alle Titel löschen?", isPresented: $showingDeleteConfirm) {
            Button("Abbrechen", role: .cancel) {}
            Button("Alles löschen", role: .destructive) { deleteAllTracks() }
        } message: {
            Text("Entfernt alle \(stats.trackCount) Titel. Kann nicht rückgängig gemacht werden.")
        }
        #if os(macOS)
        .alert("Doppelte Titel", isPresented: Binding(
            get: { dedupResult != nil }, set: { if !$0 { dedupResult = nil } })) {
            Button("OK", role: .cancel) { dedupResult = nil }
        } message: {
            Text(dedupResult ?? "")
        }
        #endif
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Text("Einstellungen")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.lumaInk())
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    // MARK: - Sections

    private func sectionLabel(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key).uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.lumaInk(0.4))
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private var statsBlock: some View {
        VStack(spacing: 0) {
            infoRow("Songs", value: "\(stats.trackCount)")
            LumaSeparator(leadingPad: 0)
            infoRow("Alben", value: "\(stats.albumCount)")
            LumaSeparator(leadingPad: 0)
            infoRow("Künstler", value: "\(stats.artistCount)")
            LumaSeparator(leadingPad: 0)
            infoRow("Playlists", value: "\(stats.playlistCount)")
            LumaSeparator(leadingPad: 0)
            infoRow("Gesamtdauer", value: DurationText.hoursMinutes(stats.totalDuration))
        }
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var storageBlock: some View {
        VStack(spacing: 0) {
            infoRow("Belegter Speicher", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
            LumaSeparator(leadingPad: 0)
            Toggle(isOn: $backupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Im iCloud-Backup sichern")
                        .foregroundStyle(.lumaInk())
                    Text("Importierte Titel ins Backup einschließen. Standardmäßig aus, um das Backup klein zu halten.")
                        .font(.caption)
                        .foregroundStyle(.lumaInk(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.lumaToggle)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .onChange(of: backupEnabled) { _, _ in
                MediaStorage.updateBackupExclusion()
            }
        }
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var importBlock: some View {
        Button {
            showingImport = true
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Musik importieren").foregroundStyle(.lumaInk())
                    Text("Dateien oder ganze Ordner aus der Dateien-App")
                        .font(.caption)
                        .foregroundStyle(.lumaInk(0.4))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lumaInk(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 60)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    #if os(macOS)
    private var appearanceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // System-Settings-style row: title left, full-width dropdown trailing.
            HStack {
                Text("Erscheinungsbild").foregroundStyle(.lumaInk())
                Spacer()
                Picker("Erscheinungsbild", selection: $macAppearance) {
                    ForEach(LumaAppearance.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("Hell oder dunkel — oder automatisch dem System folgen.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
    #endif

    private var startBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            // System-Settings-style row: title left, full-width dropdown trailing.
            HStack {
                Text("Start-Ansicht").foregroundStyle(.lumaInk())
                Spacer()
                Picker("Start-Ansicht", selection: $startupTab) {
                    Text("Mediathek").tag(LumaTab.library.rawValue)
                    Text("Playlists").tag(LumaTab.playlists.rawValue)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            #else
            Text("Start-Ansicht").foregroundStyle(.lumaInk())
            Picker("Start-Ansicht", selection: $startupTab) {
                Text("Mediathek").tag(LumaTab.library.rawValue)
                Text("Playlists").tag(LumaTab.playlists.rawValue)
            }
            .pickerStyle(.segmented)
            #endif
            Text("Welcher Tab beim Öffnen der App angezeigt wird.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var crossfadeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cross-Fade").foregroundStyle(.lumaInk())
                Spacer()
                Text(crossfade < 1 ? "Aus" : "\(Int(crossfade)) s")
                    .foregroundStyle(.lumaInk(0.45))
                    .monospacedDigit()
            }
            Slider(value: $crossfade, in: 0...12, step: 1)
                .tint(Color.lumaAccent)
            Text("Blendet aufeinanderfolgende Titel über die eingestellte Dauer ineinander über. Aus bei 0 s.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var normalizeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $normalizeVolume) {
                Text("Lautstärke angleichen").foregroundStyle(.lumaInk())
            }
            .tint(Color.lumaToggle)
            Text("Spielt alle Titel gleich laut ab – egal, wie laut die jeweilige Datei ist.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
                .fixedSize(horizontal: false, vertical: true)
            if normalizeVolume { LoudnessProgressLine() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .onChange(of: normalizeVolume) { _, _ in
            app.loudness.settingChanged()
            app.player.normalizationSettingChanged()
        }
    }

    private var lyricsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $lyricsEnabled) {
                Text("Lyrics anzeigen").foregroundStyle(.lumaInk())
            }
            .tint(Color.lumaToggle)
            Text("Zeigt im Player den Lyrics-Button. Ausgeschaltet bleibt der Player ohne Lyrics.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    #if os(iOS)
    private var swipeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wischgeste").foregroundStyle(.lumaInk())
            Picker("Wischgeste", selection: $fullSwipeAddsLast) {
                Text("Als Nächstes").tag(false)
                Text("Ans Ende").tag(true)
            }
            .pickerStyle(.segmented)
            Text("Was passiert, wenn du einen Titel ganz nach links durchwischst. Kurzes Wischen zeigt weiterhin beide Aktionen.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
    #endif

    private var homeBlock: some View {
        Button { showingHomeSettings = true } label: {
            HStack {
                Image(systemName: "house")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                Text("Startseite").foregroundStyle(.lumaInk())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lumaInk(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var smartPlaylistsBlock: some View {
        Button { showingSmartSettings = true } label: {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                Text("Smart-Playlists").foregroundStyle(.lumaInk())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lumaInk(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var equalizerBlock: some View {
        Button { showingEqualizer = true } label: {
            HStack {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                Text("Equalizer").foregroundStyle(.lumaInk())
                Spacer()
                Text(app.equalizer.isEnabled ? "An" : "Aus")
                    .foregroundStyle(.lumaInk(0.45))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lumaInk(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var toolsBlock: some View {
        NavigationLink(value: StatisticsRoute()) {
            HStack {
                Image(systemName: "chart.bar")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                Text("Statistiken").foregroundStyle(.lumaInk())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lumaInk(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var appBlock: some View {
        VStack(spacing: 0) {
            infoRow("Version", value: appVersion)
        }
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    #if os(macOS)
    private var dedupBlock: some View {
        Button {
            removeDuplicates()
        } label: {
            HStack {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Doppelte Titel entfernen").foregroundStyle(.lumaInk())
                    Text("Mehrfach importierte Titel zusammenführen")
                        .font(.caption)
                        .foregroundStyle(.lumaInk(0.4))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.lumaInk(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Merges content-duplicate tracks (same album+title+disc+track no.) into one keeper, preserving
    /// likes/play-history/playlist membership, then deletes the redundant copies. Shows the result.
    private func removeDuplicates() {
        guard let result = try? app.library.removeDuplicateTracks() else {
            dedupResult = "Die Duplikatsuche ist fehlgeschlagen."
            return
        }
        reloadStats()
        if result.removed == 0 {
            dedupResult = "Keine doppelten Titel gefunden."
        } else {
            dedupResult = "\(result.removed) doppelte Titel aus \(result.groups) "
                + (result.groups == 1 ? "Gruppe" : "Gruppen")
                + " entfernt. Likes, Wiedergabe-Verlauf und Playlist-Zuordnungen wurden zusammengeführt."
        }
    }
    #endif

    private var dangerBlock: some View {
        Button(role: .destructive) {
            showingDeleteConfirm = true
        } label: {
            HStack {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
                    .frame(width: 28)
                Text("Alle Titel löschen").foregroundStyle(.red)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func infoRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.lumaInk())
            Spacer()
            Text(value).foregroundStyle(.lumaInk(0.45))
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 50)
    }

    // MARK: - Helpers

    private func deleteAllTracks() {
        // One transaction instead of N save+@Query-republish cycles (was an O(n²) freeze).
        try? app.library.deleteAllTracks()
        reloadStats()
        Task { await loadStorageUsage() }
    }

    private func reloadStats() {
        stats = app.library.libraryStats()
    }

    private func loadStorageUsage() async {
        storageBytes = await Task.detached { MediaStorage.totalBytes }.value
    }
}

#if os(iOS)
extension SettingsView {
    /// Home-screen icon options. `alternateName == nil` is the primary (green) icon; the
    /// others map to the alternate App Icon sets registered via the asset catalog.
    fileprivate struct AppIconOption: Identifiable {
        let alternateName: String?
        let title: LocalizedStringKey
        let preview: String
        var id: String { alternateName ?? "__primary__" }
    }

    fileprivate static let appIconOptions: [AppIconOption] = [
        .init(alternateName: nil,               title: "Grün",    preview: "IconPreviewGreen"),
        .init(alternateName: "AppIconGraphite", title: "Graphit", preview: "IconPreviewGraphite"),
        .init(alternateName: "AppIconSnow",     title: "Hell",    preview: "IconPreviewSnow"),
        .init(alternateName: "AppIconBlue",     title: "Blau",    preview: "IconPreviewBlue"),
        .init(alternateName: "AppIconViolet",   title: "Violett", preview: "IconPreviewViolet"),
    ]

    var appIconBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Self.appIconOptions) { iconTile($0) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            Text("Das App-Icon auf dem Home-Bildschirm. iOS zeigt beim Wechsel einmalig einen Hinweis.")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .onAppear { currentIconName = UIApplication.shared.alternateIconName }
    }

    private func iconTile(_ option: AppIconOption) -> some View {
        let isSelected = currentIconName == option.alternateName
        return Button {
            setAppIcon(option.alternateName)
        } label: {
            VStack(spacing: 7) {
                Image(option.preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(isSelected ? Color.lumaAccent : Color.lumaInk(0.12),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(option.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .lumaInk() : .lumaInk(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    /// Switches the home-screen icon via the public `setAlternateIconName`. It presents a
    /// one-time system alert ("Du hast das Symbol … geändert.") whose layout we can't control,
    /// which we accept: the private `_setAlternateIconName:completionHandler:` selector that
    /// suppresses it puts an underscored symbol name in the binary, and App Store static
    /// analysis flags that as a private-API use (a documented rejection trigger).
    func setAppIcon(_ name: String?) {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != name else { return }

        application.setAlternateIconName(name) { error in
            Task { @MainActor in
                currentIconName = (error == nil) ? name : application.alternateIconName
            }
        }
    }
}
#endif

#if os(macOS)
extension SettingsView {
    /// Watched music folders (foobar model): referenced in place, scanned on launch.
    var folderBlock: some View {
        VStack(spacing: 0) {
            ForEach(app.libraryFolders.folders, id: \.self) { url in
                HStack(spacing: 0) {
                    Image(systemName: "folder")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.lumaAccent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent).foregroundStyle(.lumaInk())
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.lumaInk(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Button {
                        app.libraryFolders.remove(url)
                        app.rescan()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.lumaInk(0.3))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 58)
                LumaSeparator(leadingPad: 20)
            }
            Button { addFolders() } label: {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.lumaAccent)
                        .frame(width: 28)
                    Text("Ordner hinzufügen").foregroundStyle(.lumaInk())
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 52)
            }
            .buttonStyle(LumaRowStyle())
            LumaSeparator(leadingPad: 20)
            Button { app.rescan() } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.lumaAccent)
                        .frame(width: 28)
                    Text(app.folderScanner.isScanning ? "Scanne…" : "Jetzt neu scannen")
                        .foregroundStyle(.lumaInk())
                    Spacer()
                    if app.folderScanner.isScanning {
                        Text("\(Int(app.folderScanner.progress * 100)) %")
                            .foregroundStyle(.lumaInk(0.4))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 52)
            }
            .buttonStyle(LumaRowStyle())
            .disabled(app.folderScanner.isScanning)
        }
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Auswählen"
        panel.message = "Musikordner auswählen"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { app.libraryFolders.add(url) }
        app.rescan()
    }
}
#endif

/// "Still analyzing" line under the normalization switch. Its own view so the per-track countdown
/// re-renders only this line, not the whole settings screen.
private struct LoudnessProgressLine: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        if app.loudness.remaining > 0 {
            Text("Mediathek wird analysiert – noch \(app.loudness.remaining) Titel")
                .font(.caption)
                .foregroundStyle(.lumaInk(0.4))
                .monospacedDigit()
        }
    }
}
