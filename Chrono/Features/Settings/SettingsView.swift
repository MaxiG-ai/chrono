import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var exportURL: URL?
    @State private var showingShareSheet = false
    @State private var importing = false
    @State private var pendingExportFormat: ExportManager.Format?
    @State private var exportError: String?
    @State private var restoreError: String?

    var body: some View {
        Form {
            Section("Data") {
                Button {
                    pendingExportFormat = .sqlite
                    runExport()
                } label: {
                    Label("Export database backup (.db)", systemImage: "square.and.arrow.up")
                }
                Button {
                    pendingExportFormat = .json
                    runExport()
                } label: {
                    Label("Export as JSON", systemImage: "curlybraces")
                }
                Button {
                    pendingExportFormat = .csv
                    runExport()
                } label: {
                    Label("Export as CSV", systemImage: "tablecells")
                }
                Button {
                    pendingExportFormat = .ics
                    runExport()
                } label: {
                    Label("Export as Calendar (ICS)", systemImage: "calendar.badge.plus")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import database backup…", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Chrono stores data locally. iCloud device backup restores it automatically when you set up a new device. Export creates a portable copy you can save anywhere.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Storage", value: storagePath)
                    .font(.caption)
                Link("Timelines app (inspiration)",
                     destination: URL(string: "https://timelines.app/")!)
            }

            Section("Open questions resolved") {
                LabeledContent("Haptic feedback", value: "On")
                LabeledContent("Appearance", value: "Follow system")
                LabeledContent("Calendar sources", value: "All")
                LabeledContent("Backup nudges", value: "Off (trust iCloud)")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "db") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Export failed", isPresented: exportErrorBinding, presenting: exportError) { _ in
            Button("OK") { exportError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert("Restore failed", isPresented: restoreErrorBinding, presenting: restoreError) { _ in
            Button("OK") { restoreError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Helpers

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private var restoreErrorBinding: Binding<Bool> {
        Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var storagePath: String {
        (try? Database.defaultPath()) ?? "unknown"
    }

    private func runExport() {
        guard let format = pendingExportFormat else { return }
        Task.detached {
            do {
                let url = try ExportManager.exportFile(format: format)
                await MainActor.run {
                    self.exportURL = url
                    self.showingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    self.exportError = error.localizedDescription
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try BackupManager.importBackup(from: url)
                // After swapping the database file we must restart the app's
                // data layer. Simplest robust path: prompt the user to restart.
                restoreError = "Restore complete. Please relaunch Chrono to use the restored data."
            } catch {
                restoreError = error.localizedDescription
            }
        case .failure(let error):
            restoreError = error.localizedDescription
        }
    }
}

/// Bridge to the UIKit share sheet so we can present a UIActivityViewController
/// from a SwiftUI `.sheet`.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
