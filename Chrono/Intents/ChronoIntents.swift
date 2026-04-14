import Foundation
import AppIntents

/// Shortcuts / Siri integration. Intents are small and synchronous so they run
/// from Control Center, Lock Screen widgets, and Shortcuts without launching
/// the app UI. They read and write directly through the shared `Database`.

// MARK: - Category entity

/// Bridge type used by the picker UI in Shortcuts.
struct ChronoCategoryEntity: AppEntity {
    var id: String
    var name: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Category")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = ChronoCategoryQuery()
}

struct ChronoCategoryQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ChronoCategoryEntity] {
        try await fetch().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ChronoCategoryEntity] {
        try await fetch()
    }

    private func fetch() async throws -> [ChronoCategoryEntity] {
        try await Database.shared.readAsync { db in
            try CategoryRepository.all(includeArchived: false, in: db)
                .filter { $0.parentId == nil || true }  // include subs too
                .map { ChronoCategoryEntity(id: $0.id.raw, name: $0.name) }
        }
    }
}

// MARK: - StartTimerIntent

struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Timer"
    static var description = IntentDescription("Start a time-tracking timer for a category.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Category") var category: ChronoCategoryEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await Database.shared.writeAsync { db in
            // Stop any running timer first (quick-switch semantics).
            let now = Date()
            if var running = try EntryRepository.running(in: db) {
                running.endTime = now
                try EntryRepository.update(running, in: db)
            }
            let entry = TimeEntry.newRunning(categoryId: CategoryID(category.id), startTime: now)
            try EntryRepository.insert(entry, in: db)
        }
        return .result(dialog: "Started \(category.name).")
    }
}

// MARK: - StopTimerIntent

struct StopTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Timer"
    static var description = IntentDescription("Stop the currently-running timer, if any.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stoppedName: String? = try await Database.shared.writeAsync { db -> String? in
            guard var running = try EntryRepository.running(in: db) else { return nil }
            running.endTime = Date()
            try EntryRepository.update(running, in: db)
            let cat = try CategoryRepository.find(running.categoryId, in: db)
            return cat?.name
        }
        if let stoppedName {
            return .result(dialog: "Stopped \(stoppedName).")
        }
        return .result(dialog: "Nothing was running.")
    }
}

// MARK: - LogTimeIntent

struct LogTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Time"
    static var description = IntentDescription("Log a finished block of time to a category.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Category") var category: ChronoCategoryEntity
    @Parameter(title: "Minutes", default: 30) var minutes: Int
    @Parameter(title: "Note") var note: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let safeMinutes = max(1, minutes)
        let end = Date()
        let start = end.addingTimeInterval(TimeInterval(-safeMinutes * 60))
        try await Database.shared.writeAsync { db in
            let entry = TimeEntry(
                id: EntryID(),
                categoryId: CategoryID(category.id),
                startTime: start,
                endTime: end,
                note: note,
                source: .manual,
                sourceId: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
            try EntryRepository.insert(entry, in: db)
        }
        return .result(dialog: "Logged \(safeMinutes) minutes to \(category.name).")
    }
}

// MARK: - Shortcuts bundle

struct ChronoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: [
                "Start \(.applicationName) timer",
                "Start tracking in \(.applicationName)"
            ],
            shortTitle: "Start Timer",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: [
                "Stop \(.applicationName) timer",
                "Stop tracking in \(.applicationName)"
            ],
            shortTitle: "Stop Timer",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: LogTimeIntent(),
            phrases: [
                "Log time in \(.applicationName)"
            ],
            shortTitle: "Log Time",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
