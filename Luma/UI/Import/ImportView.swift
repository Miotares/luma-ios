import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var pickerContentTypes: [UTType] = []

    private static let audioTypes: [UTType] = [
        .mp3, .mpeg4Audio, .aiff, .wav,
        UTType("public.flac") ?? .audio,
        UTType("org.xiph.opus") ?? .audio,
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "music.note.house")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)

                    Text("Musik importieren")
                        .font(.title2.bold())

                    Text("Füge Titel aus der Dateien-App hinzu — iCloud Drive, Dropbox, Google Drive u.a. Die Dateien werden in Luma kopiert und sind danach offline verfügbar.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    importButton("Dateien auswählen", icon: "doc.badge.plus", primary: true) {
                        pickerContentTypes = ImportView.audioTypes
                        showingPicker = true
                    }
                    importButton("Ordner auswählen", icon: "folder.badge.plus", primary: false) {
                        pickerContentTypes = [.folder]
                        showingPicker = true
                    }
                }
                .padding(.horizontal, 32)

                if app.importManager.isImporting {
                    VStack(spacing: 8) {
                        if app.importManager.isScanning {
                            ProgressView().padding(.horizontal, 32)
                        } else {
                            ProgressView(value: app.importManager.progress)
                                .padding(.horizontal, 32)
                        }
                        Text(importStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut, value: app.importManager.isImporting)
                }

                if let error = app.importManager.lastError {
                    Text("Fehler: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .navigationTitle("Import")
            .lumaInlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: pickerContentTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFilePicker(result)
            }
            // Auto-close once an import finishes cleanly; stay open on failure so the
            // error stays visible.
            .onChange(of: app.importManager.isImporting) { wasImporting, isImporting in
                guard wasImporting, !isImporting,
                      app.importManager.failedCount == 0,
                      app.importManager.lastError == nil else { return }
                dismiss()
            }
        }
    }

    private func importButton(_ title: LocalizedStringKey, icon: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primary ? Color.white : Color.white.opacity(0.1))
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(primary ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private var importStatusText: String {
        let mgr = app.importManager
        if mgr.isScanning { return String(localized: "Ordner wird durchsucht…") }
        let done = mgr.importedCount
        let total = mgr.totalCount
        var text = total > 0
            ? String(localized: "\(done) von \(total) importiert")
            : String(localized: "\(done) importiert")
        if mgr.failedCount > 0 { text += String(localized: ", \(mgr.failedCount) fehlgeschlagen") }
        return text
    }

    private func handleFilePicker(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { await app.importManager.importFiles(urls) }
        case .failure(let error):
            print("File picker error: \(error)")
        }
    }
}
