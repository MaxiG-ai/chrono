# Models and Repositories

*2026-04-15T08:09:46Z by Showboat 0.6.1*
<!-- showboat-id: 5f960905-a460-45c0-befe-5f247bef128f -->

## Domain model

Three core value types plus three typed ID wrappers. The ID wrappers prevent categories, entries, and goals from being mixed up at compile time — no stringly-typed UUIDs flying around.

All three models are `Identifiable`, `Hashable`, and `Sendable`, which lets SwiftUI use them as list IDs, sheet items, and `onChange` tokens, and lets us hand them across the async boundary into `Database.readAsync`/`writeAsync` without warnings.

```bash
sed -n '1,24p' Chrono/Models/Models.swift
```

```output
import Foundation
import SwiftUI

/// Strongly-typed UUID wrappers keep category IDs and entry IDs from being mixed up.
/// Stored in SQLite as TEXT (UUID string).
struct CategoryID: Hashable, Codable, CustomStringConvertible, Sendable {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    init() { self.raw = UUID().uuidString }
    var description: String { raw }
}

struct EntryID: Hashable, Codable, CustomStringConvertible, Sendable {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    init() { self.raw = UUID().uuidString }
    var description: String { raw }
}

struct GoalID: Hashable, Codable, CustomStringConvertible, Sendable {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    init() { self.raw = UUID().uuidString }
    var description: String { raw }
```

### `TimeCategory`

A category has a name, hex colour, optional parent, sort order, archived flag, and creation/update timestamps. One-level nesting is enforced by `CategoryRepository.insert`, which rejects a parent that itself has a parent.

```bash
sed -n '32,59p' Chrono/Models/Models.swift
```

```output
/// per spec, which we enforce in `CategoryRepository.save`.
struct TimeCategory: Identifiable, Hashable, Sendable {
    var id: CategoryID
    var name: String
    var colorHex: String
    var parentId: CategoryID?
    var sortOrder: Int
    var archived: Bool
    var createdAt: Date
    var updatedAt: Date

    var color: Color { Color(hex: colorHex) }

    var isSubcategory: Bool { parentId != nil }

    static func new(name: String, colorHex: String, parentId: CategoryID? = nil, sortOrder: Int = 0) -> TimeCategory {
        let now = Date()
        return TimeCategory(
            id: CategoryID(),
            name: name,
            colorHex: colorHex,
            parentId: parentId,
            sortOrder: sortOrder,
            archived: false,
            createdAt: now,
            updatedAt: now
        )
    }
```

### `TimeEntry`

An entry references exactly one category, has a start and optional end time (`endTime == nil` means currently running), an optional note, and a source (`manual` or `calendar_import`) plus a `sourceId` for the original calendar event's identifier.

The helper `duration(reference:)` computes a duration against `now` by default — that's what the running banner and timeline use to draw a live-ticking timer without any branching at the call site.

```bash
sed -n '64,101p' Chrono/Models/Models.swift
```

```output
enum EntrySource: String, Sendable {
    case manual
    case calendarImport = "calendar_import"
}

struct TimeEntry: Identifiable, Hashable, Sendable {
    var id: EntryID
    var categoryId: CategoryID
    var startTime: Date
    /// `nil` means this entry is currently running.
    var endTime: Date?
    var note: String?
    var source: EntrySource
    var sourceId: String?
    var createdAt: Date
    var updatedAt: Date

    var isRunning: Bool { endTime == nil }

    /// Duration in seconds. For running entries this computes up to `reference`.
    func duration(reference: Date = Date()) -> TimeInterval {
        (endTime ?? reference).timeIntervalSince(startTime)
    }

    static func newRunning(categoryId: CategoryID, startTime: Date = Date(), note: String? = nil) -> TimeEntry {
        let now = Date()
        return TimeEntry(
            id: EntryID(),
            categoryId: categoryId,
            startTime: startTime,
            endTime: nil,
            note: note,
            source: .manual,
            sourceId: nil,
            createdAt: now,
            updatedAt: now
        )
    }
```

## Repositories

One repository per table. Each is a **caseless enum** of static functions taking a `SQLiteConnection` — not an object with state. This keeps the call sites obvious:

```swift
try await database.writeAsync { db in
    try EntryRepository.insert(entry, in: db)
}
```

Repositories never open their own connection or spawn tasks. They're just SQL.

```bash
grep -E '^[[:space:]]*static func' Chrono/Database/CategoryRepository.swift Chrono/Database/EntryRepository.swift Chrono/Database/GoalRepository.swift
```

```output
Chrono/Database/CategoryRepository.swift:    static func all(includeArchived: Bool = false, in db: SQLiteConnection) throws -> [TimeCategory] {
Chrono/Database/CategoryRepository.swift:    static func find(_ id: CategoryID, in db: SQLiteConnection) throws -> TimeCategory? {
Chrono/Database/CategoryRepository.swift:    static func topLevel(includeArchived: Bool = false, in db: SQLiteConnection) throws -> [TimeCategory] {
Chrono/Database/CategoryRepository.swift:    static func children(of parent: CategoryID, includeArchived: Bool = false, in db: SQLiteConnection) throws -> [TimeCategory] {
Chrono/Database/CategoryRepository.swift:    static func insert(_ category: TimeCategory, in db: SQLiteConnection) throws {
Chrono/Database/CategoryRepository.swift:    static func update(_ category: TimeCategory, in db: SQLiteConnection) throws {
Chrono/Database/CategoryRepository.swift:    static func delete(_ id: CategoryID, in db: SQLiteConnection) throws {
Chrono/Database/CategoryRepository.swift:    static func reorder(_ ordered: [CategoryID], in db: SQLiteConnection) throws {
Chrono/Database/CategoryRepository.swift:    static func nextSortOrder(parentId: CategoryID?, in db: SQLiteConnection) throws -> Int {
Chrono/Database/EntryRepository.swift:    static func running(in db: SQLiteConnection) throws -> TimeEntry? {
Chrono/Database/EntryRepository.swift:    static func find(_ id: EntryID, in db: SQLiteConnection) throws -> TimeEntry? {
Chrono/Database/EntryRepository.swift:    static func entries(from start: Date, to end: Date, in db: SQLiteConnection) throws -> [TimeEntry] {
Chrono/Database/EntryRepository.swift:    static func recent(limit: Int = 50, in db: SQLiteConnection) throws -> [TimeEntry] {
Chrono/Database/EntryRepository.swift:    static func insert(_ entry: TimeEntry, in db: SQLiteConnection) throws {
Chrono/Database/EntryRepository.swift:    static func update(_ entry: TimeEntry, in db: SQLiteConnection) throws {
Chrono/Database/EntryRepository.swift:    static func delete(_ id: EntryID, in db: SQLiteConnection) throws {
Chrono/Database/EntryRepository.swift:    static func totalsByCategory(from start: Date, to end: Date, now: Date = Date(), in db: SQLiteConnection) throws -> [CategoryID: TimeInterval] {
Chrono/Database/EntryRepository.swift:    static func exists(start: Date, end: Date, in db: SQLiteConnection) throws -> Bool {
Chrono/Database/EntryRepository.swift:    static func existsWithSourceId(_ sourceId: String, in db: SQLiteConnection) throws -> Bool {
Chrono/Database/GoalRepository.swift:    static func all(in db: SQLiteConnection) throws -> [Goal] {
Chrono/Database/GoalRepository.swift:    static func forCategory(_ id: CategoryID, in db: SQLiteConnection) throws -> [Goal] {
Chrono/Database/GoalRepository.swift:    static func insert(_ goal: Goal, in db: SQLiteConnection) throws {
Chrono/Database/GoalRepository.swift:    static func update(_ goal: Goal, in db: SQLiteConnection) throws {
Chrono/Database/GoalRepository.swift:    static func delete(_ id: GoalID, in db: SQLiteConnection) throws {
Chrono/Database/GoalRepository.swift:    static func get(_ key: String, in db: SQLiteConnection) throws -> String? {
Chrono/Database/GoalRepository.swift:    static func set(_ key: String, _ value: String, in db: SQLiteConnection) throws {
Chrono/Database/GoalRepository.swift:    static func delete(_ key: String, in db: SQLiteConnection) throws {
```

### Range-overlap query

The most interesting query is `EntryRepository.entries(from:to:)`. Timeline and Stats need *all entries overlapping a range*, not just entries that start in it — a long session that crosses midnight has to show on both days. The SQL is deliberately tight:

- `start_time < rangeEnd` — starts before the range ends, AND
- `(end_time IS NULL OR end_time > rangeStart)` — either currently running, or ended after the range begins.

Running entries are included by the `IS NULL` branch; the `totalsByCategory` helper clamps them to `now` before summing.

```bash
sed -n '32,50p' Chrono/Database/EntryRepository.swift
```

```output
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
```
