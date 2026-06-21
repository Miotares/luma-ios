import SwiftUI
import PhotosUI

/// Per-playlist cover editor. The user chooses between the original track mosaic, an on-device
/// photo (via PhotosPicker — out-of-process, no photo-library permission prompt, and the image
/// never leaves the device), or an app-generated pattern they customise. Edits are held locally
/// and committed in a single save, so tweaking colours doesn't churn SwiftData per change.
struct PlaylistCoverEditor: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist
    /// Safely-resolved tracks (passed in so the Mosaik preview matches the real cover and we
    /// never touch dangling entries here).
    let tracks: [Track]

    @State private var selectedStyle: PlaylistCoverStyle
    @State private var genConfig: GeneratedCoverConfig
    @State private var photoData: Data?
    @State private var photoItem: PhotosPickerItem?
    /// Bumps to refresh the photo preview's decode cache when a new image is picked.
    @State private var previewToken = 0

    init(playlist: Playlist, tracks: [Track]) {
        self.playlist = playlist
        self.tracks = tracks
        _selectedStyle = State(initialValue: playlist.coverStyle)
        let stored = playlist.generatedCoverConfig
            .flatMap { try? JSONDecoder().decode(GeneratedCoverConfig.self, from: $0) }
        // Seed from the stored recipe, or a name-derived default so "Muster" already looks good.
        _genConfig = State(initialValue: stored ?? .seeded(forName: playlist.name))
        // Pull the existing custom photo (a deliberate action — faulting the blob once is fine).
        _photoData = State(initialValue: playlist.customArtworkData)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    preview
                    stylePicker
                    styleControls
                }
                .padding(20)
                .padding(.bottom, 30)
            }
            .background(Color.lumaBackground.ignoresSafeArea())
            .navigationTitle("Cover")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }.fontWeight(.semibold)
                }
            }
            .onChange(of: photoItem) { _, item in loadPhoto(item) }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Preview

    private var preview: some View {
        coverPreview
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 22, y: 14)
            .animation(.smooth(duration: 0.25), value: selectedStyle)
    }

    @ViewBuilder
    private var coverPreview: some View {
        switch selectedStyle {
        case .mosaic:
            // playlist: nil → a plain mosaic from tracks alone (preview is driven by the local
            // selectedStyle, not the persisted style).
            PlaylistArtworkView(playlist: nil, tracks: tracks, cornerRadius: 24)
        case .photo:
            if let photoData {
                // Key namespaced by playlist id + byte count + a per-pick token, so the shared
                // decoded-image cache can't serve another playlist's photo (same plain token
                // would otherwise collide) or a stale image after the user picks a new one.
                ArtworkView(data: photoData,
                            cacheKey: "plcover-editor-\(playlist.id.uuidString)-\(photoData.count)-\(previewToken)",
                            cornerRadius: 24, size: 220)
            } else {
                photoPlaceholder
            }
        case .generated:
            GeneratedCoverView(config: genConfig, title: playlist.name, cornerRadius: 24)
        }
    }

    private var photoPlaceholder: some View {
        ZStack {
            Color.lumaSurface
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Foto auswählen")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Style picker

    private var stylePicker: some View {
        Picker("Stil", selection: $selectedStyle) {
            ForEach(PlaylistCoverStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var styleControls: some View {
        switch selectedStyle {
        case .mosaic:    mosaicControls
        case .photo:     photoControls
        case .generated: generatedControls
        }
    }

    // MARK: - Mosaic

    private var mosaicControls: some View {
        Text("Das Cover wird automatisch aus den ersten Titeln deiner Playlist gebildet.")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.45))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Photo

    private var photoControls: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(photoData == nil ? "Foto auswählen" : "Anderes Foto", systemImage: "photo.on.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)

            if photoData != nil {
                Button(role: .destructive) {
                    photoData = nil
                    photoItem = nil
                } label: {
                    Label("Foto entfernen", systemImage: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                }
                .buttonStyle(.plain)
            }

            Label("Dein Foto bleibt auf dem Gerät – es wird nichts hochgeladen.", systemImage: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Generated

    private var generatedControls: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle(isOn: $genConfig.showTitle) {
                Text("Playlist-Titel anzeigen")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .tint(Color.lumaToggle)

            controlSection("Muster") {
                horizontalRow(spacing: 12) {
                    ForEach(GeneratedCoverConfig.Pattern.allCases) { pat in
                        patternSwatch(pat)
                    }
                }
            }
            controlSection("Farbe") {
                horizontalRow(spacing: 12) {
                    ForEach(GeneratedCoverConfig.hueChoices, id: \.self) { hue in
                        hueSwatch(hue)
                    }
                }
            }
            controlSection("Textur") {
                horizontalRow(spacing: 8) {
                    ForEach(GeneratedCoverConfig.Texture.allCases) { tex in
                        chip(tex.label, selected: genConfig.texture == tex) { genConfig.texture = tex }
                    }
                }
            }
            controlSection("Symbol") {
                horizontalRow(spacing: 10) {
                    glyphSwatch(nil)
                    ForEach(GeneratedCoverConfig.glyphChoices, id: \.self) { sym in
                        glyphSwatch(sym)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func controlSection<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            content()
        }
    }

    private func horizontalRow<C: View>(spacing: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) { content() }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
    }

    private func patternSwatch(_ pat: GeneratedCoverConfig.Pattern) -> some View {
        // Isolate the pattern shape in the swatch: current colour, no texture/glyph/title.
        var cfg = genConfig
        cfg.pattern = pat
        cfg.texture = .none
        cfg.glyph = nil
        cfg.showTitle = false
        let selected = genConfig.pattern == pat
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { genConfig.pattern = pat }
        } label: {
            GeneratedCoverView(config: cfg, cornerRadius: 12)
                .frame(width: 60, height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white, lineWidth: selected ? 2.5 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private func hueSwatch(_ hue: Double) -> some View {
        let selected = abs(genConfig.hue - hue) < 0.0001
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { genConfig.hue = hue }
        } label: {
            Circle()
                .fill(GeneratedCoverConfig.swatchGradient(hue: hue))
                .frame(width: 46, height: 46)
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.85))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func glyphSwatch(_ sym: String?) -> some View {
        let selected = genConfig.glyph == sym
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { genConfig.glyph = sym }
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                if let sym {
                    Image(systemName: sym)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: "nosign")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 46, height: 46)
            .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let raw = try? await item.loadTransferable(type: Data.self) else { return }
            // Downscale OFF the main actor — this is a full ImageIO decode + JPEG re-encode of a
            // potentially 12+ MP library photo, and running it inline would hitch the editor.
            // (The import pipeline downscales off-main for the same reason — MetadataParser is
            // nonisolated.) Downscaling to ~1024px also strips EXIF/GPS. Data is Sendable, so the
            // hop in and out is race-free.
            let down = await Task.detached(priority: .userInitiated) {
                ImageDownscaler.thumbnail(from: raw, maxPixel: 1024)
            }.value
            // Back on the MainActor (this Task is MainActor-isolated) — update state directly.
            photoData = down
            previewToken &+= 1
            selectedStyle = .photo
        }
    }

    private func save() {
        // On "Foto" without a picked image, fall back to the mosaic rather than saving an empty
        // photo cover.
        let effective: PlaylistCoverStyle = (selectedStyle == .photo && photoData == nil) ? .mosaic : selectedStyle
        try? app.library.updatePlaylistCover(playlist, style: effective,
                                             photoData: photoData, generatedConfig: genConfig)
        dismiss()
    }
}
