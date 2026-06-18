import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(AppContainer.self) private var app
    @Query private var tracks: [Track]
    @Query private var albums: [Album]
    @Query private var artists: [Artist]
    @Query private var playlists: [Playlist]
    @State private var showingDeleteConfirm = false
    @State private var showingImport = false
    @State private var storageBytes: Int64 = 0
    @AppStorage(MediaStorage.backupDefaultsKey) private var backupEnabled = false
    @AppStorage(AudioPlayer.crossfadeDefaultsKey) private var crossfade: Double = 0
    @AppStorage(MainTabView.startupTabKey) private var startupTab = LumaTab.library.rawValue

    private var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    private var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    #if os(macOS)
                    sectionLabel("Musikordner")
                    folderBlock
                    #else
                    sectionLabel("Import")
                    importBlock
                    #endif
                    sectionLabel("Allgemein")
                    startBlock
                    sectionLabel("Wiedergabe")
                    crossfadeBlock
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
                    dangerBlock
                    Text("Entfernt alle Titel, Alben und Künstler samt der importierten Audiodateien.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 28)
                }
            }
            .lumaScrollClearance(playerActive: app.player.state.isActive)
        }
        .lumaHideNavBar()
        .background(Color.lumaBackground.ignoresSafeArea())
        .navigationDestination(for: StatisticsRoute.self) { _ in StatisticsView() }
        .sheet(isPresented: $showingImport) { ImportView() }
        .task { await loadStorageUsage() }
        .confirmationDialog(
            "Alle Titel löschen?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Alles löschen", role: .destructive) { deleteAllTracks() }
        } message: {
            Text("Entfernt alle \(tracks.count) Titel. Kann nicht rückgängig gemacht werden.")
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Text("Einstellungen")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.white)
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
            .foregroundStyle(.white.opacity(0.4))
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private var statsBlock: some View {
        VStack(spacing: 0) {
            infoRow("Songs", value: "\(tracks.count)")
            LumaSeparator(leadingPad: 20)
            infoRow("Alben", value: "\(albums.count)")
            LumaSeparator(leadingPad: 20)
            infoRow("Künstler", value: "\(artists.count)")
            LumaSeparator(leadingPad: 20)
            infoRow("Playlists", value: "\(playlists.count)")
            LumaSeparator(leadingPad: 20)
            infoRow("Gesamtdauer", value: DurationText.hoursMinutes(totalDuration))
        }
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var storageBlock: some View {
        VStack(spacing: 0) {
            infoRow("Belegter Speicher", value: ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
            LumaSeparator(leadingPad: 20)
            Toggle(isOn: $backupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Im iCloud-Backup sichern")
                        .foregroundStyle(.white)
                    Text("Importierte Titel ins Backup einschließen. Standardmäßig aus, um das Backup klein zu halten.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.lumaAccent)
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
                    Text("Musik importieren").foregroundStyle(.white)
                    Text("Dateien oder ganze Ordner aus der Dateien-App")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 60)
        }
        .buttonStyle(LumaRowStyle())
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var startBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start-Ansicht").foregroundStyle(.white)
            Picker("Start-Ansicht", selection: $startupTab) {
                Text("Mediathek").tag(LumaTab.library.rawValue)
                Text("Playlists").tag(LumaTab.playlists.rawValue)
            }
            .pickerStyle(.segmented)
            Text("Welcher Tab beim Öffnen der App angezeigt wird.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var crossfadeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cross-Fade").foregroundStyle(.white)
                Spacer()
                Text(crossfade < 1 ? "Aus" : "\(Int(crossfade)) s")
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }
            Slider(value: $crossfade, in: 0...12, step: 1)
                .tint(Color.lumaAccent)
            Text("Blendet aufeinanderfolgende Titel über die eingestellte Dauer ineinander über. Aus bei 0 s.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var toolsBlock: some View {
        NavigationLink(value: StatisticsRoute()) {
            HStack {
                Image(systemName: "chart.bar")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.lumaAccent)
                    .frame(width: 28)
                Text("Statistiken").foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
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
            LumaSeparator(leadingPad: 20)
            infoRow("Build", value: buildNumber)
        }
        .background(Color.lumaSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

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
            Text(label).foregroundStyle(.white)
            Spacer()
            Text(value).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 50)
    }

    // MARK: - Helpers

    private func deleteAllTracks() {
        for track in tracks { try? app.library.delete(track: track) }
        Task { await loadStorageUsage() }
    }

    private func loadStorageUsage() async {
        storageBytes = await Task.detached { MediaStorage.totalBytes }.value
    }
}

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
                        Text(url.lastPathComponent).foregroundStyle(.white)
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
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
                            .foregroundStyle(.white.opacity(0.3))
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
                    Text("Ordner hinzufügen").foregroundStyle(.white)
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
                        .foregroundStyle(.white)
                    Spacer()
                    if app.folderScanner.isScanning {
                        Text("\(Int(app.folderScanner.progress * 100)) %")
                            .foregroundStyle(.white.opacity(0.4))
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
