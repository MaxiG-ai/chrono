# Component Interactions

*2026-04-15T08:19:55Z by Showboat 0.6.1*
<!-- showboat-id: cde26fe2-2e6e-4ebd-abe2-ac5529917884 -->

This final document draws the wires between components. Individual files are described in docs 01-06; here we focus on **who talks to whom**, which direction the data flows, and the invariants each boundary enforces.

## Top-level map

```
                        ┌─────────────────────────────────────┐
                        │               User taps             │
                        └─────────────────────────────────────┘
                                  │           │          │
            ┌─────────────────────┘           │          └────────────────────┐
            │                                 │                               │
            ▼                                 ▼                               ▼
     ┌─────────────┐              ┌──────────────────────┐            ┌───────────────┐
     │  SwiftUI    │              │  Widget / Intent     │            │  Shortcuts /  │
     │  View       │              │  (separate process)  │            │  Siri         │
     └──────┬──────┘              └──────────┬───────────┘            └───────┬───────┘
            │ calls                          │ enqueues                       │ calls
            ▼                                ▼                                ▼
     ┌─────────────┐              ┌──────────────────────┐            ┌───────────────┐
     │ ChronoStore │              │   PendingAction      │            │  Database     │
     │ (@Observable)│             │   (App Group)        │            │  (shared)     │
     └──────┬──────┘              └──────────┬───────────┘            └───────┬───────┘
            │ reads/writes                   │ drained by                     │
            ▼                                ▼  ChronoStore.replay…           ▼
     ┌────────────────────────────────────────────────────────────────────────────┐
     │                      Database.shared (serial dispatch queue)               │
     │                      ↳ SQLiteConnection → chrono.db (WAL)                   │
     └────────────────────────────────────────────────────────────────────────────┘
```

Only the main app process ever holds a live SQLite connection. Widgets read a pre-computed snapshot and write to a mailbox; the app drains the mailbox when it becomes active.

## Flow 1 — Tap a category to start a timer (in-app)

```
TrackView  →  ChronoStore.toggleOrSwitch(to:)
              │
              ├─→ Database.writeAsync { db in
              │     stop running entry (if any) at "now"
              │     insert new entry, startTime = "now", endTime = nil
              │   }
              │
              ├─→ reloadRunningEntry()        ← re-reads SQLite
              ├─→ reloadRecentEntries()       ← re-reads SQLite
              ├─→ entriesRevision &+= 1        ← bumps change token
              ├─→ refreshWidgetSnapshot()      ← writes App Group UserDefaults + WidgetCenter.reload
              └─→ Haptics.start()
                          │
                          ▼
              RootView.onChange(of: store.runningEntry)
                          │
                          └─→ LiveActivityController.syncWith(...)
                                  │
                                  └─→ Activity.request(...) or .update(...)
```

Invariants:

- The DB write is a single transaction — there is never a moment where two entries have `endTime == nil`.
- The widget snapshot is refreshed **after** the DB write succeeds, so it never shows state that the DB hasn't yet committed.
- The Live Activity sync happens on the SwiftUI side via `.onChange` so it naturally runs after the `@Observable` diff has propagated.

## Flow 2 — Tap a widget button to start a timer (other process)

```
Lock Screen widget button
         │
         ▼
WidgetStartTimerIntent.perform()
         │ (in widget extension process)
         ├─→ snapshot = WidgetSnapshot.load()
         ├─→ snapshot.running = ...(new)        ← optimistic local state
         ├─→ snapshot.save()                    ← writes App Group UserDefaults
         └─→ PendingAction.enqueueStart(...)    ← writes App Group UserDefaults

  ░░ app is suspended; WidgetKit redraws widget using new snapshot ░░
  ░░ user later unlocks and opens the app                           ░░

scenePhase → .active
         │
         ▼
ChronoApp.onChange(of: scenePhase)
         │
         ├─→ store.replayPendingWidgetActions()
         │         │
         │         ├─→ for record in PendingAction.drainAll():
         │         │     switch record.kind {
         │         │       case "start": startTimer(categoryId:, at:)
         │         │       case "stop":  stopTimer(at:)
         │         │     }
         │         │
         │         └─→ each call writes SQLite + refreshes snapshot + haptics
         │
         └─→ store.reloadAll()
```

Invariants:

- The widget NEVER opens SQLite. `WidgetStartTimerIntent` only touches `UserDefaults`.
- `PendingAction.drainAll()` removes the key before returning; replay is best-effort — if a crash occurs mid-replay, lost actions are acceptable per spec (the optimistic UI already reflected the tap, and the user will re-initiate if it's missing).
- Replay reuses the same `ChronoStore.startTimer` / `stopTimer` the in-app taps use, so quick-switch semantics are enforced identically for widget-originated events.

## Flow 3 — Calendar import

```
SettingsView  →  CalendarImportView (sheet)
                         │
                         ├─→ EKEventStore.requestFullAccessToEvents
                         ├─→ fetch events for chosen date range
                         ├─→ cross-reference each event's iCalendar UID
                         │    against EntryRepository.existsWithSourceId
                         │    (marks duplicates with a badge)
                         │
                         ▼
            user taps an event → EntryEditView(mode: .createFromCalendar(...))
                         │
                         ▼
            user taps Save →  EntryEditView.saveTapped()
                         │
                         ├─→ checkDuplicate(start:, end:)  (exact match only)
                         │     └─→ if duplicate: show alert, wait for confirm
                         │
                         └─→ performSave()
                               └─→ store.addEntry(entry)  [source=.calendar, sourceId=UID]
                                     └─→ Database.writeAsync { EntryRepository.insert(...) }
```

The duplicate check is a two-layer belt-and-braces:

1. **In the list**, entries already imported (by UID) show an "Imported" badge and are not tappable as a new import.
2. **At save time**, an exact-match `start`+`end` duplicate triggers an "Import Anyway?" alert — handles the case where a user imports, then re-imports after moving the event.

## Flow 4 — Restore from a .db backup

```
SettingsView → .fileImporter (document picker)
                  │
                  ▼
           url (security-scoped) → BackupManager.importBackup(from:)
                  │
                  ├─→ startAccessingSecurityScopedResource
                  ├─→ open incoming .db with SQLiteConnection
                  │    and query sqlite_master for our four tables
                  │    (fails early if not a Chrono DB)
                  ├─→ move existing chrono.db → chrono.db.bak
                  ├─→ remove chrono.db-wal / chrono.db-shm
                  └─→ copyItem(from: incoming, to: chrono.db)

  ░░ Database.shared still has an open SQLite handle to the old file ░░
  ░░ SettingsView shows "Please relaunch the app" alert              ░░
```

Invariants:

- The live DB is never deleted outright — worst-case rollback is to rename `.bak` back to `.db`.
- Probing happens **before** any mutation to the destination filesystem.
- WAL/SHM siblings are removed so the new DB can re-create its own.

## Data-flow table

| From → To                           | Mechanism                                   | When                           |
|-------------------------------------|---------------------------------------------|--------------------------------|
| Views ↔ ChronoStore                 | `@Environment(ChronoStore.self)`            | Continuous (Observable diff)   |
| ChronoStore → Database              | `Database.writeAsync` / `readAsync`         | On every mutation / reload     |
| Database → SQLite file              | Serial dispatch queue + WAL                 | On write / read                |
| ChronoStore → WidgetSnapshot        | `refreshWidgetSnapshot()` + `WidgetCenter`  | After every mutation           |
| Widget extension ← WidgetSnapshot   | `UserDefaults(suiteName: appGroup)`         | On each timeline refresh       |
| Widget extension → PendingAction    | `UserDefaults(suiteName: appGroup)`         | On widget button tap           |
| ChronoStore ← PendingAction         | `replayPendingWidgetActions()`              | On `.task` and `.active`       |
| ChronoStore → LiveActivity          | `RootView.onChange(of: runningEntry)`        | Running entry changes          |
| AppIntents (in app) → Database      | `Database.shared.writeAsync`                | Siri / Shortcut invocation     |
| ChronoApp → LiveClock               | `clock.start()`                             | Once per cold launch           |
| Views → LiveClock                   | `@Environment(LiveClock.self)`              | Running-timer labels tick      |

## Invariants reference card

- **One running entry at most.** Enforced by `startTimer` stopping the current running entry inside the same transaction.
- **No cross-process SQLite access.** Enforced by making widget intents go through `PendingAction` + snapshot.
- **Widget shows latest committed state.** Enforced by `refreshWidgetSnapshot()` being called after every mutation, never before.
- **One level of subcategory nesting.** Enforced in `CategoryRepository.insert` — rejects parents that already have a parent.
- **Entry duration queries use half-open overlap.** `start_time < end AND (end_time IS NULL OR end_time > start)` — correct for running entries, no double-counting at boundaries.
- **The live DB is never in iCloud Drive.** Enforced by the DB path being `Library/Application Support`, which is outside the user's Files visibility.

## When things change

- **Adding a new screen.** Read from `ChronoStore`, never open `Database.shared` directly — the observation model depends on all state going through the store.
- **Adding a new widget.** Re-use `WidgetSnapshot`. If a new piece of data is needed, add a field to the snapshot and populate it in `ChronoStore.refreshWidgetSnapshot()`. Do not add a separate App Group key unless the use case is genuinely orthogonal.
- **Adding a new widget button.** Write a new intent in the widget target, make it update the snapshot optimistically and enqueue a `PendingAction`, then extend `ChronoStore.replayPendingWidgetActions()` to handle the new `kind`.
- **Adding a new export format.** Add a case to `ExportManager.Format` and a `make<X>` helper. The `SettingsView` wiring is per-button, so add an additional button + `runExport()` invocation.
- **Schema migration.** Append a new `Migration` in `Migrations.swift`. The `PRAGMA user_version` gate ensures it runs exactly once. Never edit past migrations.

---

That's the whole app. Three tabs, one store, one DB, one snapshot, one mailbox. If a change ever feels like it needs a new top-level concept, the spec's "Every screen earns its place" should be the first thing re-read.
