import Foundation
import Observation
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Central observable store. All screens read from and mutate the database
/// through this type, which keeps SwiftUI state in sync with the DB.
///
/// Why a single store instead of one per feature? The data set is small, and
/// any meaningful mutation (start timer, edit entry, import calendar event)
/// invalidates more than one screen. Broadcasting through one `@Observable`
/// object is simpler and faster than plumbing multiple publishers.
@Observable
@MainActor
final class ChronoStore {
    private let database: Database

    // MARK: - Published state
    private(set) var categories: [TimeCategory] = []
    private(set) var runningEntry: TimeEntry? = nil
    private(set) var recentEntries: [TimeEntry] = []
    private(set) var goals: [Goal] = []
    /// Incremented whenever entries change, so views that compute totals can refresh.
    private(set) var entriesRevision: Int = 0

    var lastError: String?

    init(database: Database = .shared) {
        self.database = database
    }

    // MARK: - Loading

    func bootstrap() async {
        await reloadAll()
        await seedDefaultCategoriesIfEmpty()
    }

    func reloadAll() async {
        await reloadCategories()
        await reloadRunningEntry()
        await reloadRecentEntries()
        await reloadGoals()
        await refreshWidgetSnapshot()
    }

    /// Rebuild the snapshot consumed by the widget extension. Called after any
    /// mutation that could affect what the widget displays.
    func refreshWidgetSnapshot() async {
        // Today total (all categories summed).
        let start = Date().startOfDay()
        let end = start.adding(days: 1)
        let totals = await totalsByCategory(from: start, to: end)
        let today = Int(totals.values.reduce(0, +))

        let top = topLevelCategories().prefix(6).map {
            WidgetSnapshot.CategorySummary(
                id: $0.id.raw,
                name: $0.name,
                colorHex: $0.colorHex
            )
        }

        var running: WidgetSnapshot.RunningEntry?
        if let entry = runningEntry, let cat = category(entry.categoryId) {
            running = WidgetSnapshot.RunningEntry(
                categoryId: entry.categoryId.raw,
                categoryName: cat.name,
                colorHex: cat.colorHex,
                startDate: entry.startTime
            )
        }

        let lastUsed = recentEntries.first?.categoryId.raw

        let snapshot = WidgetSnapshot(
            running: running,
            topCategories: Array(top),
            lastUsedCategoryId: lastUsed,
            todaySecondsTracked: today,
            updatedAt: Date()
        )
        snapshot.save()
        // Ask WidgetKit to refresh.
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Replay any timer actions initiated from the widget while the app was
    /// suspended. Called when the app becomes active.
    func replayPendingWidgetActions() async {
        let records = PendingAction.drainAll()
        guard !records.isEmpty else { return }
        for record in records {
            switch record.kind {
            case "start":
                if let id = record.categoryId {
                    await startTimer(categoryId: CategoryID(id), at: record.at)
                }
            case "stop":
                await stopTimer(at: record.at)
            default:
                break
            }
        }
    }

    func reloadCategories() async {
        do {
            let rows = try await database.readAsync { try CategoryRepository.all(includeArchived: true, in: $0) }
            self.categories = rows
        } catch {
            self.lastError = "Failed to load categories: \(error)"
        }
    }

    func reloadRunningEntry() async {
        do {
            self.runningEntry = try await database.readAsync { try EntryRepository.running(in: $0) }
        } catch {
            self.lastError = "Failed to load running entry: \(error)"
        }
    }

    func reloadRecentEntries(limit: Int = 50) async {
        do {
            self.recentEntries = try await database.readAsync { try EntryRepository.recent(limit: limit, in: $0) }
        } catch {
            self.lastError = "Failed to load recent entries: \(error)"
        }
    }

    func reloadGoals() async {
        do {
            self.goals = try await database.readAsync { try GoalRepository.all(in: $0) }
        } catch {
            self.lastError = "Failed to load goals: \(error)"
        }
    }

    // MARK: - Convenience lookups

    func category(_ id: CategoryID?) -> TimeCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func topLevelCategories(includeArchived: Bool = false) -> [TimeCategory] {
        categories.filter { $0.parentId == nil && (includeArchived || !$0.archived) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    func subcategories(of parent: CategoryID, includeArchived: Bool = false) -> [TimeCategory] {
        categories.filter { $0.parentId == parent && (includeArchived || !$0.archived) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Timer actions (one-tap core)

    /// Start a timer for the given category. If another timer is running it is
    /// stopped at the same instant so there are no overlaps.
    func startTimer(categoryId: CategoryID, at moment: Date = Date()) async {
        do {
            try await database.writeAsync { db in
                if let running = try EntryRepository.running(in: db) {
                    if running.categoryId == categoryId {
                        // Already running this category — no-op.
                        return
                    }
                    var stopped = running
                    stopped.endTime = moment
                    try EntryRepository.update(stopped, in: db)
                }
                let entry = TimeEntry.newRunning(categoryId: categoryId, startTime: moment)
                try EntryRepository.insert(entry, in: db)
            }
            await reloadRunningEntry()
            await reloadRecentEntries()
            entriesRevision &+= 1
            await refreshWidgetSnapshot()
            Haptics.start()
        } catch {
            self.lastError = "Start failed: \(error)"
            Haptics.warning()
        }
    }

    func stopTimer(at moment: Date = Date()) async {
        do {
            let changed = try await database.writeAsync { db -> Bool in
                guard var running = try EntryRepository.running(in: db) else { return false }
                running.endTime = moment
                try EntryRepository.update(running, in: db)
                return true
            }
            if changed {
                await reloadRunningEntry()
                await reloadRecentEntries()
                entriesRevision &+= 1
                await refreshWidgetSnapshot()
                Haptics.stop()
            }
        } catch {
            self.lastError = "Stop failed: \(error)"
            Haptics.warning()
        }
    }

    /// Tap behaviour used by the track list row: toggle if already running this
    /// category, otherwise switch (which atomically stops the current one).
    func toggleOrSwitch(to categoryId: CategoryID) async {
        if let running = runningEntry, running.categoryId == categoryId {
            await stopTimer()
        } else {
            await startTimer(categoryId: categoryId)
        }
    }

    // MARK: - Category CRUD

    func addCategory(name: String, colorHex: String, parent: CategoryID? = nil) async {
        do {
            let sortOrder = try await database.readAsync { try CategoryRepository.nextSortOrder(parentId: parent, in: $0) }
            let cat = TimeCategory.new(name: name, colorHex: colorHex, parentId: parent, sortOrder: sortOrder)
            try await database.writeAsync { try CategoryRepository.insert(cat, in: $0) }
            await reloadCategories()
        } catch {
            self.lastError = "Failed to add category: \(error)"
        }
    }

    func updateCategory(_ category: TimeCategory) async {
        do {
            try await database.writeAsync { try CategoryRepository.update(category, in: $0) }
            await reloadCategories()
        } catch {
            self.lastError = "Failed to update category: \(error)"
        }
    }

    func archiveCategory(_ id: CategoryID, archived: Bool = true) async {
        guard var cat = category(id) else { return }
        cat.archived = archived
        await updateCategory(cat)
    }

    func deleteCategory(_ id: CategoryID) async {
        do {
            try await database.writeAsync { try CategoryRepository.delete(id, in: $0) }
            await reloadAll()
        } catch {
            self.lastError = "Failed to delete category: \(error)"
        }
    }

    func reorderTopLevel(_ ordered: [CategoryID]) async {
        do {
            try await database.writeAsync { try CategoryRepository.reorder(ordered, in: $0) }
            await reloadCategories()
        } catch {
            self.lastError = "Failed to reorder: \(error)"
        }
    }

    // MARK: - Entry CRUD

    func addEntry(_ entry: TimeEntry) async {
        do {
            try await database.writeAsync { try EntryRepository.insert(entry, in: $0) }
            await reloadRecentEntries()
            await reloadRunningEntry()
            entriesRevision &+= 1
        } catch {
            self.lastError = "Failed to add entry: \(error)"
        }
    }

    func updateEntry(_ entry: TimeEntry) async {
        do {
            try await database.writeAsync { try EntryRepository.update(entry, in: $0) }
            await reloadRecentEntries()
            await reloadRunningEntry()
            entriesRevision &+= 1
        } catch {
            self.lastError = "Failed to update entry: \(error)"
        }
    }

    func deleteEntry(_ id: EntryID) async {
        do {
            try await database.writeAsync { try EntryRepository.delete(id, in: $0) }
            await reloadRecentEntries()
            await reloadRunningEntry()
            entriesRevision &+= 1
        } catch {
            self.lastError = "Failed to delete entry: \(error)"
        }
    }

    // MARK: - Aggregations

    func totalsByCategory(from start: Date, to end: Date) async -> [CategoryID: TimeInterval] {
        do {
            return try await database.readAsync { try EntryRepository.totalsByCategory(from: start, to: end, in: $0) }
        } catch {
            self.lastError = "Totals failed: \(error)"
            return [:]
        }
    }

    func entries(from start: Date, to end: Date) async -> [TimeEntry] {
        do {
            return try await database.readAsync { try EntryRepository.entries(from: start, to: end, in: $0) }
        } catch {
            self.lastError = "Entries query failed: \(error)"
            return []
        }
    }

    // MARK: - Goals

    func addGoal(categoryId: CategoryID, period: GoalPeriod, targetMinutes: Int) async {
        let now = Date()
        let goal = Goal(
            id: GoalID(),
            categoryId: categoryId,
            period: period,
            targetMinutes: max(1, targetMinutes),
            createdAt: now,
            updatedAt: now
        )
        do {
            try await database.writeAsync { try GoalRepository.insert(goal, in: $0) }
            await reloadGoals()
        } catch {
            self.lastError = "Failed to add goal: \(error)"
        }
    }

    func updateGoal(_ goal: Goal) async {
        do {
            try await database.writeAsync { try GoalRepository.update(goal, in: $0) }
            await reloadGoals()
        } catch {
            self.lastError = "Failed to update goal: \(error)"
        }
    }

    func deleteGoal(_ id: GoalID) async {
        do {
            try await database.writeAsync { try GoalRepository.delete(id, in: $0) }
            await reloadGoals()
        } catch {
            self.lastError = "Failed to delete goal: \(error)"
        }
    }

    // MARK: - First-run seeds

    private func seedDefaultCategoriesIfEmpty() async {
        guard categories.isEmpty else { return }
        // Give the user something to tap on first launch. They can delete or rename.
        let seeds: [(String, String)] = [
            ("Deep Work", "#3B82F6"),
            ("Meetings", "#6366F1"),
            ("Exercise", "#22C55E"),
            ("Reading", "#F59E0B"),
            ("Sleep", "#8B5CF6")
        ]
        for (i, (name, color)) in seeds.enumerated() {
            let cat = TimeCategory.new(name: name, colorHex: color, sortOrder: i)
            do {
                try await database.writeAsync { try CategoryRepository.insert(cat, in: $0) }
            } catch {
                self.lastError = "Seed failed: \(error)"
            }
        }
        await reloadCategories()
        await refreshWidgetSnapshot()
    }
}
