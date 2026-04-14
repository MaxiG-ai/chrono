import Foundation

/// Replaces the current database with a user-supplied `.db` file.
///
/// The spec intentionally uses iCloud *device* backup (safe for SQLite) and
/// this explicit manual import flow. We intentionally do NOT place the live DB
/// in iCloud Drive — see the spec rationale under "Why not iCloud Drive sync".
enum BackupManager {
    enum BackupError: Error, LocalizedError {
        case sourceMissing
        case invalidDatabase(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing: "Backup file is missing."
            case .invalidDatabase(let msg): "Not a valid Chrono database: \(msg)"
            case .copyFailed(let msg): "Restore failed: \(msg)"
            }
        }
    }

    /// Validate the source by opening it and probing the schema, then atomically
    /// swap it in. Existing database is preserved under `.bak` until the next
    /// successful restore, giving us a free escape hatch.
    static func importBackup(from url: URL) throws {
        let fm = FileManager.default

        // Resolve any security-scoped bookmarks. The UIDocumentPicker grants
        // access only within a startAccessingSecurityScopedResource() / stop pair.
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        guard fm.fileExists(atPath: url.path) else { throw BackupError.sourceMissing }

        // Probe the incoming file.
        do {
            let probe = try SQLiteConnection(path: url.path)
            // Must have our tables.
            _ = try probe.query("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('category','entry','goal','app_state');") { $0.text(0) }
        } catch {
            throw BackupError.invalidDatabase("\(error)")
        }

        let destination = try Database.defaultPath()
        let destinationURL = URL(fileURLWithPath: destination)
        let backupURL = destinationURL.appendingPathExtension("bak")

        // Remove sibling WAL/SHM so SQLite re-creates them cleanly.
        let siblings = [destination + "-wal", destination + "-shm"]

        do {
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            if fm.fileExists(atPath: destination) {
                try fm.moveItem(at: destinationURL, to: backupURL)
            }
            for sibling in siblings where fm.fileExists(atPath: sibling) {
                try? fm.removeItem(atPath: sibling)
            }
            try fm.copyItem(at: url, to: destinationURL)
        } catch {
            throw BackupError.copyFailed(error.localizedDescription)
        }
    }
}
