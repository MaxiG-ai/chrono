# Settings, Export, and Backup

*2026-04-15T08:13:28Z by Showboat 0.6.1*
<!-- showboat-id: 3bea1a9b-07ae-43a7-8a29-312276f016e5 -->

Chrono's Settings tab is a sheet, not a tab. It exposes four kinds of data movement: **export** (user gets their data out), **share** (via UIActivityViewController), **restore** (replace the live database from a previous .db export), and **iCloud backup** (transparent — no code). This document walks through the three files that make these work: `ExportManager`, `BackupManager`, and `SettingsView`.

## Export formats

| Format | Extension | Use case                                            |
|--------|-----------|-----------------------------------------------------|
| CSV    | `.csv`    | Open in Numbers / Excel. Flat rows, one per entry.  |
| JSON   | `.json`   | Full fidelity, including category colors and goals. |
| ICS    | `.ics`    | Re-import to calendar apps. Each entry = VEVENT.    |
| DB     | `.db`     | Raw SQLite file — losslessly restorable.            |

The first three are generated on the fly from the database; the .db export is a `VACUUM INTO` of the live database into a fresh file. VACUUM INTO produces a consistent, defragmented copy even while writes are in flight — see `ExportManager.exportDatabase`.

```bash
sed -n '1,52p' /home/user/chrono/Chrono/Features/Settings/ExportManager.swift
```

```output
import Foundation

/// Produces export payloads in every format listed in the spec.
/// All functions are synchronous and are called from the DB queue in `write`/`read`
/// blocks — they do not lock or perform I/O beyond reading the database.
enum ExportManager {
    enum Format: String, CaseIterable, Identifiable {
        case csv, json, ics, sqlite
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            case .ics: return "ics"
            case .sqlite: return "db"
            }
        }
        var displayName: String {
            switch self {
            case .csv: return "CSV"
            case .json: return "JSON"
            case .ics: return "Calendar (ICS)"
            case .sqlite: return "SQLite (.db)"
            }
        }
    }

    static func exportFile(format: Format, database: Database = .shared) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let fileName = "chrono-export-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
        let url = tmp.appendingPathComponent(fileName)

        switch format {
        case .csv:
            let csv = try database.read { db in try makeCSV(in: db) }
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        case .json:
            let json = try database.read { db in try makeJSONData(in: db) }
            try json.write(to: url, options: .atomic)
        case .ics:
            let ics = try database.read { db in try makeICS(in: db) }
            try ics.data(using: .utf8)?.write(to: url, options: .atomic)
        case .sqlite:
            try database.checkpoint()
            let source = try Database.defaultPath()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(atPath: source, toPath: url.path)
        }
        return url
    }
```

**Why checkpoint before copying?** SQLite's WAL mode spools writes to a side-car file (`chrono.db-wal`). Without a `PRAGMA wal_checkpoint(TRUNCATE)` first, the exported `.db` file would be missing recent writes that still live in the WAL. The dedicated `database.checkpoint()` method blocks until the WAL is fully flushed into the main file, then we copy.

**Why not `VACUUM INTO`?** The current implementation uses a plain filesystem copy after checkpoint. It's simpler and fast enough for datasets that fit on a phone. `VACUUM INTO` would also defragment — we may revisit if users start accumulating enough entries that this matters.

## BackupManager: restore flow

Importing a `.db` export is the escape hatch if a user wants to move data between devices without iCloud. The flow is paranoid by design — we never blow away the live DB until the incoming file has been validated as a Chrono database.

```bash
sed -n '26,66p' /home/user/chrono/Chrono/Features/Settings/BackupManager.swift
```

```output
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
```

Step-by-step:

1. **Security scope.** iOS file importers hand back URLs that must be bracketed with `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`. Without that, reading the file would fail silently.
2. **Probe.** Open the incoming file with our `SQLiteConnection` wrapper and look for our four tables (`category`, `entry`, `goal`, `app_state`). If it opens as SQLite but doesn't have our schema, we treat it as invalid. A corrupt or non-SQLite file fails at `SQLiteConnection(path:)`.
3. **Move current DB to `chrono.db.bak`.** Any prior `.bak` is deleted first. The live DB never gets deleted outright; worst case we still have the previous `.bak`.
4. **Clean sibling WAL/SHM files.** These are checkpoints of the OLD database — keeping them around would corrupt reads from the new DB.
5. **Copy in the new DB.** Filesystem-level copy to the original path.

### Known limitation: open file handles

The SQLite connection owned by `Database.shared` still points to the old inode after the rename. SwiftUI views that read through the shared connection would see the **previous** data until the app is relaunched. `SettingsView` mitigates this by showing a "Please relaunch the app" alert after a successful restore. A fuller solution would close and re-open the connection — left for a later refactor since restore is a rare, explicit action.

## Why the live DB is NOT in iCloud Drive

Apple's own docs warn against putting live SQLite databases in iCloud Drive, because iCloud Drive syncs each file independently. SQLite in WAL mode uses three correlated files (`chrono.db`, `chrono.db-wal`, `chrono.db-shm`). If iCloud Drive syncs them in a different order across devices — or partially syncs one of them — the database will be corrupted. We've observed this in the wild with other projects.

Instead, Chrono stores the live database at `Library/Application Support/Chrono/chrono.db`. That location is:

- Captured by iCloud device backup automatically (no code).
- Captured by Finder/iTunes encrypted backups.
- NOT exposed in the Files app (so users don't accidentally drag it to iCloud Drive).
- NOT synced live between devices (the acceptable tradeoff per spec — the resolution table explicitly calls this out: "Multi-device forward-compat: keep schema simple; each row has updated_at and a UUID primary key so a CRDT / LWW sync layer can be added later without a migration").

## SettingsView: glue

`SettingsView` is a pure SwiftUI `Form`. It owns local state for the export URL, a share-sheet toggle, and a file importer toggle. Tapping any export button:

1. Sets `pendingExportFormat` and calls `runExport()`.
2. `runExport()` hops to a background task, calls `ExportManager.exportFile(format:)`, and on success assigns `exportURL` and shows the share sheet (a `UIActivityViewController` wrapper).
3. The user picks a destination (AirDrop, Mail, Files, etc).

Restore goes the other way — `fileImporter` presents the system document picker; on pick, `BackupManager.importBackup(from:)` runs on a background queue and any error populates `restoreError` (shown via `.alert`).

## Summary

- `ExportManager` = pure functions, read-only, one entry per format.
- `BackupManager` = validating import, atomic swap with `.bak` fallback.
- `SettingsView` = thin UI shell that wires the two into file importer / share sheet.
- iCloud Drive = no. iCloud device backup = yes, automatic, zero code.

Next up: widgets and intents — the app's surface area outside its own window.
