import Foundation

enum EntryRepository {
    private static let columns = "id, category_id, start_time, end_time, note, source, source_id, created_at, updated_at"

    private static func decode(_ row: SQLiteRow) -> TimeEntry {
        TimeEntry(
            id: EntryID(row.text(0)),
            categoryId: CategoryID(row.text(1)),
            startTime: Date.fromISO8601(row.text(2)) ?? Date(),
            endTime: row.optionalText(3).flatMap(Date.fromISO8601),
            note: row.optionalText(4),
            source: EntrySource(rawValue: row.text(5)) ?? .manual,
            sourceId: row.optionalText(6),
            createdAt: Date.fromISO8601(row.text(7)) ?? Date(),
            updatedAt: Date.fromISO8601(row.text(8)) ?? Date()
        )
    }

    static func running(in db: SQLiteConnection) throws -> TimeEntry? {
        let sql = "SELECT \(columns) FROM entry WHERE end_time IS NULL ORDER BY start_time DESC LIMIT 1;"
        return try db.query(sql, row: decode).first
    }

    static func find(_ id: EntryID, in db: SQLiteConnection) throws -> TimeEntry? {
        let sql = "SELECT \(columns) FROM entry WHERE id = ? LIMIT 1;"
        return try db.query(sql, [.text(id.raw)], row: decode).first
    }

    /// Entries that overlap the given range (start inclusive, end exclusive).
    /// An entry overlaps if `start_time < rangeEnd` AND `(end_time IS NULL OR end_time > rangeStart)`.
    static func entries(from start: Date, to end: Date, in db: SQLiteConnection) throws -> [TimeEntry] {
        let sql = """
        SELECT \(columns) FROM entry
         WHERE start_time < ?
           AND (end_time IS NULL OR end_time > ?)
         ORDER BY start_time ASC;
        """
        return try db.query(sql, [.text(end.iso8601), .text(start.iso8601)], row: decode)
    }

    static func recent(limit: Int = 50, in db: SQLiteConnection) throws -> [TimeEntry] {
        let sql = "SELECT \(columns) FROM entry ORDER BY start_time DESC LIMIT ?;"
        return try db.query(sql, [.int(limit)], row: decode)
    }

    static func insert(_ entry: TimeEntry, in db: SQLiteConnection) throws {
        try db.run("""
            INSERT INTO entry (id, category_id, start_time, end_time, note, source, source_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(entry.id.raw),
                .text(entry.categoryId.raw),
                .text(entry.startTime.iso8601),
                .optionalText(entry.endTime?.iso8601),
                .optionalText(entry.note),
                .text(entry.source.rawValue),
                .optionalText(entry.sourceId),
                .text(entry.createdAt.iso8601),
                .text(entry.updatedAt.iso8601)
            ])
    }

    static func update(_ entry: TimeEntry, in db: SQLiteConnection) throws {
        var updated = entry
        updated.updatedAt = Date()
        try db.run("""
            UPDATE entry
               SET category_id = ?, start_time = ?, end_time = ?, note = ?, source = ?, source_id = ?, updated_at = ?
             WHERE id = ?;
            """, [
                .text(updated.categoryId.raw),
                .text(updated.startTime.iso8601),
                .optionalText(updated.endTime?.iso8601),
                .optionalText(updated.note),
                .text(updated.source.rawValue),
                .optionalText(updated.sourceId),
                .text(updated.updatedAt.iso8601),
                .text(updated.id.raw)
            ])
    }

    static func delete(_ id: EntryID, in db: SQLiteConnection) throws {
        try db.run("DELETE FROM entry WHERE id = ?;", [.text(id.raw)])
    }

    // MARK: - Aggregations

    /// Total duration per category that overlaps [start, end). Running entries
    /// are counted up to `now` (or `end`, whichever is earlier).
    static func totalsByCategory(from start: Date, to end: Date, now: Date = Date(), in db: SQLiteConnection) throws -> [CategoryID: TimeInterval] {
        let entries = try entries(from: start, to: end, in: db)
        let clampEnd = min(end, now)
        var totals: [CategoryID: TimeInterval] = [:]
        for entry in entries {
            let effectiveStart = max(entry.startTime, start)
            let effectiveEnd = min(entry.endTime ?? now, clampEnd)
            let seconds = effectiveEnd.timeIntervalSince(effectiveStart)
            if seconds > 0 {
                totals[entry.categoryId, default: 0] += seconds
            }
        }
        return totals
    }

    /// Does an entry already exist with exact matching start and end?
    /// Used for calendar-import duplicate detection.
    static func exists(start: Date, end: Date, in db: SQLiteConnection) throws -> Bool {
        let sql = "SELECT 1 FROM entry WHERE start_time = ? AND end_time = ? LIMIT 1;"
        let rows = try db.query(sql, [.text(start.iso8601), .text(end.iso8601)]) { _ in 1 }
        return !rows.isEmpty
    }

    static func existsWithSourceId(_ sourceId: String, in db: SQLiteConnection) throws -> Bool {
        let sql = "SELECT 1 FROM entry WHERE source_id = ? LIMIT 1;"
        let rows = try db.query(sql, [.text(sourceId)]) { _ in 1 }
        return !rows.isEmpty
    }
}
