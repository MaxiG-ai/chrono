# Widgets, Intents, and Live Activity

*2026-04-15T08:17:24Z by Showboat 0.6.1*
<!-- showboat-id: e90fa029-cc30-4eb6-9651-9416f5e36383 -->

Chrono's one-tap philosophy has to reach surfaces outside the app itself — Home Screen widgets, the Lock Screen, the Dynamic Island, Siri, and Shortcuts. This document traces the three building blocks that make that work:

- **AppIntents** — Siri / Shortcuts verbs (`StartTimerIntent`, `StopTimerIntent`, `LogTimeIntent`).
- **Widgets** — Home/Lock widgets rendered by the `ChronoWidget` extension.
- **Live Activity** — the Dynamic Island / Lock Screen "currently running" UI.

Cross-process data flow (written out in detail in doc 07) is the most interesting part: widgets never open SQLite, the app writes a snapshot, and widget taps enqueue a `PendingAction` that the app drains on next launch.

## Shared types: `WidgetSnapshot` and `PendingAction`

Two files live in `Chrono/Shared/WidgetShared/` and are compiled into **both** the app and the widget extension (see `project.yml`). They are the protocol between the two processes.

### WidgetSnapshot — app → widget

The app writes this after every mutation that would affect what a widget shows. Widgets read it with one `UserDefaults` call.

```bash
sed -n '7,42p' /home/user/chrono/Chrono/Shared/WidgetShared/WidgetSnapshot.swift
```

```output
public struct WidgetSnapshot: Codable, Equatable {
    public struct CategorySummary: Codable, Equatable {
        public var id: String
        public var name: String
        public var colorHex: String
    }

    public struct RunningEntry: Codable, Equatable {
        public var categoryId: String
        public var categoryName: String
        public var colorHex: String
        public var startDate: Date
    }

    public var running: RunningEntry?
    public var topCategories: [CategorySummary]
    public var lastUsedCategoryId: String?
    public var todaySecondsTracked: Int
    public var updatedAt: Date

    public init(
        running: RunningEntry? = nil,
        topCategories: [CategorySummary] = [],
        lastUsedCategoryId: String? = nil,
        todaySecondsTracked: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.running = running
        self.topCategories = topCategories
        self.lastUsedCategoryId = lastUsedCategoryId
        self.todaySecondsTracked = todaySecondsTracked
        self.updatedAt = updatedAt
    }

    public static let appGroupIdentifier = "group.app.chrono.Chrono"
    public static let userDefaultsKey = "widget.snapshot.v1"
```

**Design choice.** The snapshot is deliberately small — just the six visible top-level categories, the currently-running entry (if any), today's total seconds, and the last-used category id. No entry history, no goals, no subcategories. Widgets don't need more than that, and a small snapshot means `UserDefaults` writes stay under the ~16KB sweet spot where they're cheap.

### PendingAction — widget → app

When the user taps a widget button (e.g. "Start Deep Work"), the widget extension needs to record that action. **It does not open SQLite.** It appends a `Record` to the shared mailbox:

```bash
sed -n '9,42p' /home/user/chrono/Chrono/Shared/WidgetShared/PendingAction.swift
```

```output
public enum PendingAction {
    private static let suiteName = WidgetSnapshot.appGroupIdentifier
    private static let key = "widget.pendingActions.v1"

    public struct Record: Codable {
        public let kind: String   // "start" or "stop"
        public let categoryId: String?
        public let at: Date

        public init(kind: String, categoryId: String?, at: Date) {
            self.kind = kind
            self.categoryId = categoryId
            self.at = at
        }
    }

    public static func enqueueStart(categoryId: String, at: Date) {
        append(Record(kind: "start", categoryId: categoryId, at: at))
    }

    public static func enqueueStop(at: Date) {
        append(Record(kind: "stop", categoryId: nil, at: at))
    }

    public static func drainAll() -> [Record] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        defaults.removeObject(forKey: key)
        return records
    }

```

`drainAll()` is atomic-ish — it decodes, then `removeObject`s the key. If the app crashes between decoding and replaying, the action is lost; we accept that in exchange for not needing a real inter-process queue. App-side replay lives at `ChronoStore.replayPendingWidgetActions()` and is invoked in two places: the initial `.task` in `ChronoApp`, and the `.active` scene-phase handler.

## AppIntents

Chrono defines three intents, all in `Chrono/Intents/ChronoIntents.swift`:

| Intent              | Parameters                 | Invoked from                  |
|---------------------|----------------------------|-------------------------------|
| `StartTimerIntent`  | category                   | Siri, Shortcuts, home widget  |
| `StopTimerIntent`   | —                          | Siri, Shortcuts, home widget  |
| `LogTimeIntent`     | category, minutes, note?   | Siri, Shortcuts               |

All three have `openAppWhenRun = false` so they execute in the Shortcuts process without bringing the UI forward. They call `Database.shared.writeAsync` directly — unlike the Widget-Kit intents, **AppIntents run in a context where direct DB writes are permissible**, because AppIntents hosted by the main app are serialised into its own memory space when it's foregrounded and use a separate file-coordinator-aware SQLite path otherwise. (The widget extension is a different process and must go through `PendingAction`.)

**`StartTimerIntent`** implements the same quick-switch semantics as the in-app tap: stop any running timer first, then insert a new one. This matches the core one-tap promise.

```bash
sed -n '44,64p' /home/user/chrono/Chrono/Intents/ChronoIntents.swift
```

```output
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
```

**`ChronoCategoryEntity`** is the bridge type Shortcuts uses to display a category picker; `ChronoCategoryQuery.suggestedEntities()` populates the picker by reading from the real DB. Users get exactly the same list they see inside the app.

**`ChronoShortcuts`** registers the built-in phrases ("Start Chrono timer", "Stop Chrono timer", "Log time in Chrono") so users don't need to configure anything — the Shortcuts.app and Siri surface them automatically.

## Widgets

The widget extension target (`ChronoWidget`) lives in its own bundle with its own `Info.plist` and entitlements. It shares the App Group identifier with the app so it can read the snapshot and write to the pending-action queue. The bundle registers a status widget plus a quick-start widget.

Two widgets are exposed (see `ChronoWidget/ChronoWidgetBundle.swift`):

- **`ChronoStatusWidget`** — shows the running timer and today's total. Supported families: `systemSmall`, `systemMedium`, `accessoryRectangular`, `accessoryCircular` (Lock Screen + Home Screen, plus watch-style circular).
- **`ChronoQuickStartWidget`** — a one-button "tap to start your favourite category" widget. The favourite falls back to the last-used category, then the first top-level category.

Both use the same `StatusTimelineProvider`, which simply loads the snapshot and hands back a single entry with a 15-minute reload. The running timer itself doesn't need frequent reloads because the view uses `Text(running.startDate, style: .timer)`, which ticks locally on the device without a WidgetKit timeline update.

### WidgetStartTimerIntent — optimistic update + pending action

The Home/Lock-screen buttons are wired up via `Button(intent:)`, which invokes an AppIntent **in the widget extension's process** (not the app). Because the widget can't touch SQLite safely, its intent does two things:

```bash
sed -n '215,243p' /home/user/chrono/ChronoWidget/ChronoStatusWidget.swift
```

```output
struct WidgetStartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Timer (Widget)"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Category ID") var categoryId: String

    init() { self.categoryId = "" }
    init(categoryId: String) { self.categoryId = categoryId }

    func perform() async throws -> some IntentResult {
        var snapshot = WidgetSnapshot.load()
        if let cat = snapshot.topCategories.first(where: { $0.id == categoryId }) {
            snapshot.running = .init(
                categoryId: cat.id,
                categoryName: cat.name,
                colorHex: cat.colorHex,
                startDate: Date()
            )
            snapshot.lastUsedCategoryId = cat.id
            snapshot.updatedAt = Date()
            snapshot.save()
        }
        // Record a pending action for the app to reconcile into SQLite on next
        // launch. The widget process can't safely write to the SQLite database
        // while the app might also be writing.
        PendingAction.enqueueStart(categoryId: categoryId, at: Date())
        return .result()
    }
}
```

1. **Optimistic local update.** Mutates the in-memory snapshot to look like the timer started *right now* and saves it back. This means the widget view redraws immediately with the new running state — no waiting for the app to launch.
2. **Enqueue a pending action.** When the app becomes active, `ChronoStore.replayPendingWidgetActions()` drains the queue and replays each action as a real DB write. Any conflict (e.g., the user also tapped in-app) is resolved by the replay logic stopping any currently-running entry first — same quick-switch rule.

## Live Activity

The Live Activity is the Dynamic Island / Lock Screen UI that appears while a timer is running. Two files make it work:

- **`ChronoActivityAttributes`** — the shared `ActivityAttributes` struct, compiled into both the app and the widget extension. Fixed attributes (category name, color, start date) are set at activity creation; the mutable `ContentState` is deliberately kept to a single `isRunning` boolean. The ticking duration is rendered entirely via `Text(timerInterval:)` in the widget, so no push updates or timeline refreshes are required for the clock to keep counting up.
- **`LiveActivityController`** — a MainActor enum (no instance state beyond a static `currentActivityID`) that starts, updates, or ends the activity in response to the running entry.

`RootView.onChange(of: store.runningEntry)` invokes `LiveActivityController.syncWith(...)` whenever the running entry changes, so the Lock Screen UI always matches app state.

```bash
sed -n '10,26p' /home/user/chrono/Chrono/LiveActivity/LiveActivityController.swift
```

```output
    static func syncWith(runningEntry: TimeEntry?, category: TimeCategory?) {
        // No-op on devices where Live Activities are unsupported or disabled.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let entry = runningEntry, let category {
            if let id = currentActivityID, let existing = Activity<ChronoActivityAttributes>.activities.first(where: { $0.id == id }) {
                // Already tracking — refresh the content state.
                Task {
                    await existing.update(using: .init(isRunning: true))
                }
            } else {
                startActivity(entry: entry, category: category)
            }
        } else {
            stopActivity()
        }
    }
```

The logic:

- If a timer is running and a matching activity exists: `update` the content state (cheap).
- If a timer is running and no activity exists: `Activity.request` a new one.
- If no timer is running: end all activities with `dismissalPolicy: .immediate`.

`ChronoLiveActivity.swift` in the widget target renders the actual UI — a compact leading/trailing layout in the Dynamic Island, plus a Lock Screen banner. It uses the shared `ChronoActivityAttributes` so it has access to the category color and name for free.

## Putting it together

1. The user opens the app. `ChronoApp.task` calls `store.bootstrap()` which loads categories, running entry, etc., and writes the first `WidgetSnapshot`.
2. User taps a category row. `ChronoStore.toggleOrSwitch(to:)` writes SQLite and refreshes the snapshot. `RootView`'s `onChange(of: store.runningEntry)` notices the change and starts a Live Activity.
3. User locks the phone. The Live Activity keeps ticking via `Text(timerInterval:)` with no further work.
4. User taps "Start Exercise" on a Home Screen quick-start widget. `WidgetStartTimerIntent` updates the snapshot (widget UI redraws) and enqueues a `PendingAction`.
5. User unlocks the phone. Scene phase goes `.active`. `ChronoApp` calls `store.replayPendingWidgetActions()`, which drains the queue and writes the real DB entries. The running banner, Live Activity, and widget all reconcile to the same state.

This keeps every surface consistent without ever having two processes hold the SQLite file open simultaneously.
