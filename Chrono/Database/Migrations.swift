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

    // MARK: - Migrations

    private static func m1_initialSchema(_ db: SQLiteConnection) throws {
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
}
