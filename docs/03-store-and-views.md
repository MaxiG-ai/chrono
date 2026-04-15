# ChronoStore and the Three Tab Views

*2026-04-15T08:10:54Z by Showboat 0.6.1*
<!-- showboat-id: 428a5fd1-d187-4e41-a079-2709b32f6182 -->

## `ChronoStore`

`ChronoStore` is the single `@Observable`, `@MainActor` object that every SwiftUI view reads from. It holds a cached copy of the data the UI cares about:

- `categories` — full list including archived (views filter as needed)
- `runningEntry` — whatever timer is currently running (if any)
- `recentEntries` — last 50 by start time
- `goals` — all goals
- `entriesRevision` — a counter bumped on any entry change, used as a cheap `task(id:)` trigger for views that need to re-query after mutations

Why a single store? The data set is tiny and almost every mutation affects more than one view. One observable object with explicit methods is simpler than multiple publishers and easier to reason about.

```bash
sed -n '16,31p' Chrono/Database/ChronoStore.swift
```

```output
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
```

### Quick-switch semantics

The spec requires that tapping a different category stops the current timer and starts the new one *in a single gesture*. `toggleOrSwitch(to:)` does both atomically inside a single transaction — there's no window where two timers are running or none is:

```bash
sed -n '166,190p' Chrono/Database/ChronoStore.swift
```

```output
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

```

## `LiveClock`

Running timers tick every second. Instead of each view owning its own `Timer`, there's one `@Observable` `LiveClock` that publishes `now: Date` and all views that render a duration observe it. Starts at app launch; stops when the scene disappears in production flows (currently left running for simplicity — a v2 optimisation).

## `TrackView`

The main screen. A running banner sits at the top (always visible — shows "No timer running" when idle); below it is a list of top-level categories with an optional subcategory tray that expands on the chevron button.

The row's primary tap handler calls `store.toggleOrSwitch(to:)` — that's the entire one-tap contract.

```
┌──────────────────────────────┐
│  🔵 Deep Work  ·  00:23:14   │  ← running banner
│                [edit] [stop] │
├──────────────────────────────┤
│  ▮ Deep Work    ▶            │
│  ▮ Meetings     ▶            │
│  ▮ Exercise     ▶            │
└──────────────────────────────┘
```

```bash
grep -n 'toggleOrSwitch\|onTap:' Chrono/Features/Track/TrackView.swift | head -10
```

```output
101:                        onTap: { Task { await store.toggleOrSwitch(to: cat.id) } },
102:                        onTapSub: { subId in Task { await store.toggleOrSwitch(to: subId) } },
224:    let onTap: () -> Void
306:                            onTap: { onTapSub(sub.id) }
321:    let onTap: () -> Void
```

## `TimelineView`

A vertical day view. Each hour is 60 points tall by default; a pinch gesture scales between 20 and 240 points per hour. Entries that cross midnight are **clamped** to the visible day — that's what makes gaps render correctly.

The red "now" indicator only renders when the selected date is today (a small but important detail — no confusing red line on historical days).

```bash
sed -n '190,210p' Chrono/Features/Timeline/TimelineView.swift
```

```output
        return HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .padding(.leading, leftGutter - 10)
        .offset(y: offset - 4)
    }

    // MARK: Segment layout

    private struct TimelineSegment: Identifiable {
        let id: EntryID
        let entry: TimeEntry
        let offset: CGFloat
        let height: CGFloat
    }

    private func visibleSegments() -> [TimelineSegment] {
        let dayStart = date.startOfDay()
        let dayEnd = dayStart.adding(days: 1)
        var segments: [TimelineSegment] = []
```

```bash
sed -n '210,224p' Chrono/Features/Timeline/TimelineView.swift
```

```output
        var segments: [TimelineSegment] = []
        for entry in entries {
            let clampedStart = max(entry.startTime, dayStart)
            let clampedEnd = min(entry.endTime ?? now, dayEnd)
            guard clampedEnd > clampedStart else { continue }
            let offset = CGFloat(clampedStart.timeIntervalSince(dayStart) / 3600) * pointsPerHour
            let height = CGFloat(clampedEnd.timeIntervalSince(clampedStart) / 3600) * pointsPerHour
            segments.append(TimelineSegment(id: entry.id, entry: entry, offset: offset, height: max(3, height)))
        }
        return segments
    }

    @ViewBuilder
    private func segmentView(_ seg: TimelineSegment) -> some View {
        let category = categoryLookup(seg.entry.categoryId)
```

## `StatsView`

Period picker (Day / Week / Month) drives a single ring chart ("where did your time go?"), a per-day stacked bar chart, and a trend label vs the previous period. The ring chart is a custom `Shape` — each slice is a single arc path so colour matches the category's configured hex exactly.

Data is loaded by computing two range boundaries for the current vs previous period and summing via `store.totalsByCategory(from:to:)`, which itself is just a thin wrapper over `EntryRepository.totalsByCategory`.
