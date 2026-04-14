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
}

// MARK: - TimeCategory

/// A user-defined tracking category.
///
/// `parentId != nil` means this is a subcategory. We only support one level of nesting
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
}

// MARK: - TimeEntry

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
}

// MARK: - Goal

enum GoalPeriod: String, CaseIterable, Identifiable, Sendable {
    case daily, weekly, monthly
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

struct Goal: Identifiable, Hashable, Sendable {
    var id: GoalID
    var categoryId: CategoryID
    var period: GoalPeriod
    var targetMinutes: Int
    var createdAt: Date
    var updatedAt: Date

    var targetSeconds: TimeInterval { TimeInterval(targetMinutes) * 60 }
}
