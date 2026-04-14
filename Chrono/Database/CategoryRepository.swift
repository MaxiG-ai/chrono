import Foundation

enum CategoryRepository {
    private static let columns = "id, name, color, parent_id, sort_order, archived, created_at, updated_at"

    private static func decode(_ row: SQLiteRow) -> TimeCategory {
        TimeCategory(
            id: CategoryID(row.text(0)),
            name: row.text(1),
            colorHex: row.text(2),
            parentId: row.optionalText(3).map(CategoryID.init),
            sortOrder: row.intValue(4),
            archived: row.bool(5),
            createdAt: Date.fromISO8601(row.text(6)) ?? Date(),
            updatedAt: Date.fromISO8601(row.text(7)) ?? Date()
        )
    }

    static func all(includeArchived: Bool = false, in db: SQLiteConnection) throws -> [TimeCategory] {
        let where_ = includeArchived ? "" : "WHERE archived = 0"
        let sql = "SELECT \(columns) FROM category \(where_) ORDER BY parent_id IS NOT NULL, sort_order, name;"
        return try db.query(sql, row: decode)
    }

    static func find(_ id: CategoryID, in db: SQLiteConnection) throws -> TimeCategory? {
        let sql = "SELECT \(columns) FROM category WHERE id = ? LIMIT 1;"
        return try db.query(sql, [.text(id.raw)], row: decode).first
    }

    static func topLevel(includeArchived: Bool = false, in db: SQLiteConnection) throws -> [TimeCategory] {
        let where_ = includeArchived
            ? "WHERE parent_id IS NULL"
            : "WHERE parent_id IS NULL AND archived = 0"
        let sql = "SELECT \(columns) FROM category \(where_) ORDER BY sort_order, name;"
        return try db.query(sql, row: decode)
    }

    static func children(of parent: CategoryID, includeArchived: Bool = false, in db: SQLiteConnection) throws -> [TimeCategory] {
        var clauses = ["parent_id = ?"]
        if !includeArchived { clauses.append("archived = 0") }
        let sql = "SELECT \(columns) FROM category WHERE \(clauses.joined(separator: " AND ")) ORDER BY sort_order, name;"
        return try db.query(sql, [.text(parent.raw)], row: decode)
    }

    static func insert(_ category: TimeCategory, in db: SQLiteConnection) throws {
        // Enforce one-level nesting: if parent_id is set, that parent must itself be top-level.
        if let parent = category.parentId {
            guard let parentRow = try find(parent, in: db) else {
                throw SQLiteError(code: -1, message: "Parent category not found")
            }
            if parentRow.parentId != nil {
                throw SQLiteError(code: -1, message: "Subcategories cannot have their own subcategories")
            }
        }
        try db.run("""
            INSERT INTO category (id, name, color, parent_id, sort_order, archived, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text(category.id.raw),
                .text(category.name),
                .text(category.colorHex),
                .optionalText(category.parentId?.raw),
                .int(category.sortOrder),
                .bool(category.archived),
                .text(category.createdAt.iso8601),
                .text(category.updatedAt.iso8601)
            ])
    }

    static func update(_ category: TimeCategory, in db: SQLiteConnection) throws {
        var updated = category
        updated.updatedAt = Date()
        try db.run("""
            UPDATE category
               SET name = ?, color = ?, parent_id = ?, sort_order = ?, archived = ?, updated_at = ?
             WHERE id = ?;
            """, [
                .text(updated.name),
                .text(updated.colorHex),
                .optionalText(updated.parentId?.raw),
                .int(updated.sortOrder),
                .bool(updated.archived),
                .text(updated.updatedAt.iso8601),
                .text(updated.id.raw)
            ])
    }

    static func delete(_ id: CategoryID, in db: SQLiteConnection) throws {
        // Cascade removes entries and goals.
        try db.run("DELETE FROM category WHERE id = ?;", [.text(id.raw)])
    }

    static func reorder(_ ordered: [CategoryID], in db: SQLiteConnection) throws {
        for (index, id) in ordered.enumerated() {
            try db.run("UPDATE category SET sort_order = ?, updated_at = ? WHERE id = ?;",
                       [.int(index), .text(Date().iso8601), .text(id.raw)])
        }
    }

    static func nextSortOrder(parentId: CategoryID?, in db: SQLiteConnection) throws -> Int {
        let sql: String
        let params: [SQLiteValue]
        if let parentId {
            sql = "SELECT COALESCE(MAX(sort_order), -1) FROM category WHERE parent_id = ?;"
            params = [.text(parentId.raw)]
        } else {
            sql = "SELECT COALESCE(MAX(sort_order), -1) FROM category WHERE parent_id IS NULL;"
            params = []
        }
        let rows = try db.query(sql, params) { $0.intValue(0) }
        return (rows.first ?? -1) + 1
    }
}
