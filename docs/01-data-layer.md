# Data Layer — SQLite, Migrations, Database

*2026-04-15T08:08:08Z by Showboat 0.6.1*
<!-- showboat-id: 350786ae-2b08-4db8-93e1-c480629130fe -->

The data layer has three pieces, from lowest to highest:

1. **`SQLite.swift`** — minimal C-bindings wrapper: `SQLiteConnection`, `SQLiteValue`, `SQLiteRow`, `SQLiteError`. About 250 lines. Works directly with `sqlite3_*` functions.
2. **`Migrations.swift`** — incremental schema migrations tracked via `PRAGMA user_version`.
3. **`Database.swift`** — process-wide singleton that owns the connection and serialises access through a `DispatchQueue`. Exposes `read`, `write`, `readAsync`, `writeAsync`, and `checkpoint`.

## Why raw SQLite instead of GRDB?

The spec recommends GRDB, but going one level lower:

- Removes the only external dependency — project builds immediately after `xcodegen generate`.
- Aligns with the spec principle *"no ORM layer, direct SQLite"*.
- Keeps the binary-size budget comfortable (< 15 MB).
- The API surface is so small that there's nothing to abstract: `run(sql, params)`, `query(sql, params, row:)`, `transaction { ... }`.

## `SQLite.swift`

`SQLiteConnection` enables WAL mode, normal synchronous, foreign keys, and a busy timeout on open. Note the two sentinel destructors — SQLite needs a C-level hint about whether to copy bound memory:

```bash
sed -n '1,30p' Chrono/Database/SQLite.swift
```

```output
import Foundation
import SQLite3

// SQLite binds these special sentinel values to functions that take a destructor
// for the payload. SQLITE_STATIC says "don't copy, don't free" — valid only when
// the bound memory outlives the statement step. SQLITE_TRANSIENT says "make a copy".
let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// SQLite error wrapped with the code and the full human-readable message.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// Thin wrapper around a single SQLite connection. Not thread-safe on its own —
/// callers route access through `Database`, which owns a serial dispatch queue.
final class SQLiteConnection {
    fileprivate var handle: OpaquePointer?

    init(path: String) throws {
        // SQLITE_OPEN_FULLMUTEX gives us safe concurrent use, but we still
        // serialize through a queue at a higher level to keep semantics simple
        // and avoid surprising writer contention.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        if result != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
```

### Typed value binding

`SQLiteValue` is the only type callers use to bind parameters. It keeps the bind site concise while still forcing you to say what you mean — no accidental string interpolation of numbers.

```bash
sed -n '124,138p' Chrono/Database/SQLite.swift
```

```output
enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
    static func optionalText(_ value: String?) -> SQLiteValue {
        if let value { return .text(value) }
        return .null
    }
}

```

## `Migrations.swift`

Migrations append to the `all` array — each migration gets a version number (1-indexed) and is run inside a transaction along with a `PRAGMA user_version` bump. This means a migration is fully applied or fully not; it's also safe to run on a just-created database because the initial version is `0`.

```bash
sed -n '1,27p' Chrono/Database/Migrations.swift
```

```output
import Foundation

/// Incremental schema migrations. New migrations append to `all` — never edit
/// existing ones once they've shipped in a release. The `user_version` pragma
/// tracks the current applied version.
enum Migrations {
    static func run(on db: SQLiteConnection) throws {
        let current = try currentVersion(db)
        for (index, migration) in all.enumerated() {
            let version = index + 1
            guard version > current else { continue }
            try db.transaction {
                try migration(db)
                try db.execute("PRAGMA user_version = \(version);")
            }
        }
    }

    private static func currentVersion(_ db: SQLiteConnection) throws -> Int {
        let rows = try db.query("PRAGMA user_version;") { $0.intValue(0) }
        return rows.first ?? 0
    }

    private static let all: [(SQLiteConnection) throws -> Void] = [
        m1_initialSchema
    ]

```

### Schema (migration 1)

The initial schema has four tables plus indexes. A **partial index** on `entry(end_time) WHERE end_time IS NULL` means the "is anything running?" query touches at most one row and is effectively free.

```bash
sed -n '31,82p' Chrono/Database/Migrations.swift
```

```output
        try db.execute("""
        CREATE TABLE category (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            color       TEXT NOT NULL,
            parent_id   TEXT REFERENCES category(id) ON DELETE SET NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0,
            archived    INTEGER NOT NULL DEFAULT 0,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
        """)

        try db.execute("""
        CREATE TABLE entry (
            id          TEXT PRIMARY KEY,
            category_id TEXT NOT NULL REFERENCES category(id) ON DELETE CASCADE,
            start_time  TEXT NOT NULL,
            end_time    TEXT,
            note        TEXT,
            source      TEXT NOT NULL DEFAULT 'manual',
            source_id   TEXT,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
        """)

        try db.execute("CREATE INDEX idx_entry_start ON entry(start_time);")
        try db.execute("CREATE INDEX idx_entry_category ON entry(category_id);")
        try db.execute("CREATE INDEX idx_entry_source ON entry(source_id);")
        // There should only ever be zero or one running entry. Partial index
        // makes the "is anything running?" query free.
        try db.execute("CREATE INDEX idx_entry_running ON entry(end_time) WHERE end_time IS NULL;")

        try db.execute("""
        CREATE TABLE goal (
            id          TEXT PRIMARY KEY,
            category_id TEXT NOT NULL REFERENCES category(id) ON DELETE CASCADE,
            period      TEXT NOT NULL,
            target_mins INTEGER NOT NULL,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL
        );
        """)

        try db.execute("""
        CREATE TABLE app_state (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }
```

## `Database.swift`

`Database` is the process-wide entry point. It:

- Opens the file at `Library/Application Support/Chrono/chrono.db` (per spec).
- Runs migrations inside the queue on construction — if anything fails here the app deliberately crashes rather than running in a broken state.
- Exposes four blocking primitives (`read`, `write`, and their `*Async` variants) that fan all access through a single serial `DispatchQueue`.
- Has a `checkpoint()` helper that runs `PRAGMA wal_checkpoint(TRUNCATE)` so the WAL is merged before we copy the `.db` file for export.

```bash
sed -n '30,49p' Chrono/Database/Database.swift
```

```output
        }
    }

    /// Location of the production database. Lives in Application Support per spec.
    static func defaultPath() throws -> String {
        let fm = FileManager.default
        let dir = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Explicit subdirectory to keep the WAL / SHM siblings grouped.
        let chronoDir = dir.appendingPathComponent("Chrono", isDirectory: true)
        if !fm.fileExists(atPath: chronoDir.path) {
            try fm.createDirectory(at: chronoDir, withIntermediateDirectories: true)
        }
        return chronoDir.appendingPathComponent("chrono.db").path
    }

```
