import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var pickerContentTypes: [UTType] = []

    /// Every audio file is selectable. A format Luma can't play is reported after the import
    /// instead of being greyed out in the picker with no explanation.
    private static let audioTypes: [UTType] = [.audio]

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
                        Button("Import abbrechen", role: .cancel) { app.importManager.cancel() }
                            .font(.footnote.weight(.semibold))
                            .padding(.top, 4)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut, value: app.importManager.isImporting)
                } else if let report = app.importManager.lastReport {
                    ImportReportView(report: report)
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
                guard wasImporting, !isImporting, let report = app.importManager.lastReport,
                      report.isClean else { return }
                // Nothing to read here — close and let the app-wide toast confirm the result.
                dismiss()
                app.importManager.isPresentingUI = false
                app.announceImportResult()
            }
            // While this sheet is up it shows the progress itself (see ToastHost).
            .onAppear { app.importManager.isPresentingUI = true }
            .onDisappear { app.importManager.isPresentingUI = false }
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
                        .fill(primary ? Color.lumaAccent : Color.lumaInk(0.1))
                )
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.lumaInk(0.16), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(primary ? .lumaOnAccent : .lumaInk())
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

/// Result of the last import: what was added, what was skipped and — by name — what failed.
private struct ImportReportView: View {
    let report: ImportManager.ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.wasCancelled {
                line("Import abgebrochen", icon: "xmark.circle", tint: .orange)
            }
            line("\(report.imported) importiert", icon: "checkmark.circle", tint: .green)
            if report.alreadyPresent > 0 {
                line("\(report.alreadyPresent) bereits vorhanden", icon: "equal.circle", tint: .secondary)
            }
            if report.unsupported > 0 {
                line("\(report.unsupported) nicht unterstützt", icon: "questionmark.circle", tint: .orange)
            }
            if !report.failures.isEmpty {
                line("\(report.failures.count) fehlgeschlagen", icon: "exclamationmark.circle", tint: .red)
                Group {
                    // A few failures fit as they are; a long list scrolls inside a fixed box.
                    if report.failures.count <= 3 {
                        failureList
                    } else {
                        ScrollView { failureList }.frame(height: 150)
                    }
                }
                .background(Color.lumaInk(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.failures) { failure in
                VStack(alignment: .leading, spacing: 1) {
                    Text(failure.fileName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.lumaInk(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(failure.reason)
                        .font(.caption2)
                        .foregroundStyle(.lumaInk(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func line(_ text: LocalizedStringKey, icon: String, tint: Color) -> some View {
        Label {
            Text(text).foregroundStyle(.lumaInk(0.75))
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .font(.footnote)
    }
}
