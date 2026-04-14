import Foundation

enum GoalRepository {
    private static let columns = "id, category_id, period, target_mins, created_at, updated_at"

    private static func decode(_ row: SQLiteRow) -> Goal {
        Goal(
            id: GoalID(row.text(0)),
            categoryId: CategoryID(row.text(1)),
            period: GoalPeriod(rawValue: row.text(2)) ?? .daily,
            targetMinutes: row.intValue(3),
            createdAt: Date.fromISO8601(row.text(4)) ?? Date(),
            updatedAt: Date.fromISO8601(row.text(5)) ?? Date()
        )
    }

    static func all(in db: SQLiteConnection) throws -> [Goal] {
        let sql = "SELECT \(columns) FROM goal ORDER BY created_at ASC;"
        return try db.query(sql, row: decode)
    }

    static func forCategory(_ id: CategoryID, in db: SQLiteConnection) throws -> [Goal] {
        let sql = "SELECT \(columns) FROM goal WHERE category_id = ? ORDER BY period;"
        return try db.query(sql, [.text(id.raw)], row: decode)
    }

    static func insert(_ goal: Goal, in db: SQLiteConnection) throws {
        try db.run("""
            INSERT INTO goal (id, category_id, period, target_mins, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """, [
                .text(goal.id.raw),
                .text(goal.categoryId.raw),
                .text(goal.period.rawValue),
                .int(goal.targetMinutes),
                .text(goal.createdAt.iso8601),
                .text(goal.updatedAt.iso8601)
            ])
    }

    static func update(_ goal: Goal, in db: SQLiteConnection) throws {
        var updated = goal
        updated.updatedAt = Date()
        try db.run("""
            UPDATE goal SET category_id = ?, period = ?, target_mins = ?, updated_at = ?
             WHERE id = ?;
            """, [
                .text(updated.categoryId.raw),
                .text(updated.period.rawValue),
                .int(updated.targetMinutes),
                .text(updated.updatedAt.iso8601),
                .text(updated.id.raw)
            ])
    }

    static func delete(_ id: GoalID, in db: SQLiteConnection) throws {
        try db.run("DELETE FROM goal WHERE id = ?;", [.text(id.raw)])
    }
}

enum AppStateRepository {
    static func get(_ key: String, in db: SQLiteConnection) throws -> String? {
        let rows = try db.query("SELECT value FROM app_state WHERE key = ? LIMIT 1;", [.text(key)]) { $0.text(0) }
        return rows.first
    }

    static func set(_ key: String, _ value: String, in db: SQLiteConnection) throws {
        try db.run("""
            INSERT INTO app_state(key, value) VALUES(?, ?)
              ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, [.text(key), .text(value)])
    }

    static func delete(_ key: String, in db: SQLiteConnection) throws {
        try db.run("DELETE FROM app_state WHERE key = ?;", [.text(key)])
    }
}
