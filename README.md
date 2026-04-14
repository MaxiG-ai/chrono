# Chrono

A minimal, local-first iOS time tracker. Built to the spec in [SPEC.md](./SPEC.md) (v0.2 draft).

## Highlights

- **One-tap tracking.** Tap a category to start, tap again to stop, tap another to switch.
- **Local-first.** Data lives on-device in a single SQLite file. No accounts, no cloud sync, no network at runtime.
- **Three screens.** Track, Timeline, Stats. Settings is a sheet, not a tab.
- **Widgets + Live Activity + Shortcuts.** Start/stop from the Lock Screen, Home Screen, or Dynamic Island.
- **Calendar import.** Read-only EventKit. Turn calendar events into time entries with a tap.
- **Backup strategy.** Relies on iCloud device backup (zero code) plus a manual export/import escape hatch.

## Project layout

```
chrono/
├── project.yml                 # XcodeGen spec (generates Chrono.xcodeproj)
├── Chrono/                     # iOS app target
│   ├── App/                    # ChronoApp, RootView, Info.plist, entitlements
│   ├── Database/               # Thin SQLite wrapper, migrations, repositories, ChronoStore
│   ├── Models/                 # Value types: TimeCategory, TimeEntry, Goal
│   ├── Features/
│   │   ├── Track/              # Main tracking screen (one-tap start/stop)
│   │   ├── Timeline/           # Visual day timeline with pinch-to-zoom
│   │   ├── Stats/              # Ring + bar charts, period summaries, trends
│   │   ├── Categories/         # Category CRUD, reorder, archive
│   │   ├── Entry/              # Retroactive entry + import confirmation sheet
│   │   ├── Goals/              # Daily / weekly / monthly targets + progress
│   │   ├── Calendar/           # EventKit import flow
│   │   └── Settings/           # Export (CSV/JSON/ICS/.db) + restore
│   ├── Intents/                # App Intents (Siri / Shortcuts)
│   ├── LiveActivity/           # Shared attributes + controller
│   ├── Shared/                 # Colour, date, haptics, LiveClock, WidgetShared/
│   └── Assets.xcassets/        # App icon + accent colour
└── ChronoWidget/               # Widget extension (status, quick-start, Live Activity)
```

## Building

Chrono uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to produce the Xcode project from `project.yml`. This means you don't check in a brittle `.pbxproj` and every build starts from a clean, reviewable spec.

```bash
brew install xcodegen     # once
xcodegen generate         # produces Chrono.xcodeproj
open Chrono.xcodeproj
```

Then in Xcode:
1. Select the **Chrono** scheme.
2. Set the team for both the `Chrono` app target and the `ChronoWidget` extension (needed for App Groups + Live Activities).
3. Run on an iOS 17+ device or simulator.

The project has **zero external dependencies** — it uses the system `libsqlite3` that already ships with iOS, so there are no packages to resolve.

## Architecture notes

### Data layer

SQLite directly, via a ~200-line Swift wrapper (`Chrono/Database/SQLite.swift`). The spec recommends GRDB; we went one step lower to honour the "no ORM, minimal overhead" principle. The API surface is small: `run(sql, params)`, `query(sql, params, row:)`, `transaction { ... }`. Each entity has a repository enum (`CategoryRepository`, `EntryRepository`, `GoalRepository`) with pure static functions — no record wrapper types, no bindings magic.

All access is serialised through a single dispatch queue in `Database`. SQLite WAL mode handles concurrent reads natively, but serialising makes concurrency bugs impossible and the query volume is trivial for user-driven workloads.

### Observable state

One `@Observable` store (`ChronoStore`) is the single source of truth for the UI. Views read from it via `@Environment(ChronoStore.self)` and mutate through its methods. A small `LiveClock` (`@Observable`, ticks once per second) drives running-timer labels so each view doesn't own its own `Timer`.

### Database location

`Library/Application Support/Chrono/chrono.db`. This is the Apple-recommended location for app databases — it's captured by iCloud device backup and iTunes/Finder backups but not exposed in the user-visible Files app. Crucially we do **not** place the live database in iCloud Drive: SQLite's WAL consists of multiple files and iCloud Drive syncs them independently, which can and does corrupt databases.

### Widgets and the app

The widget extension never opens SQLite. Instead, the app writes a tiny `WidgetSnapshot` (categories, running entry, today's total) into an App Group `UserDefaults` after every mutation. Widgets read that snapshot and call `WidgetCenter.shared.reloadAllTimelines()` when it changes.

Lock Screen / Home Screen widget buttons invoke `WidgetStartTimerIntent`. The intent updates the snapshot immediately (so the UI reflects the state change) and appends a `PendingAction` record. When the app next becomes active, it drains pending actions and reconciles them into SQLite. This keeps cross-process SQLite writes out of the picture entirely.

### Live Activity

`ChronoActivityAttributes` is shared between the app and the widget extension. The app starts / ends the activity in response to timer events (see `RootView.onChange(of: store.runningEntry)`). The widget renders with `Text(timerInterval:)` so the duration ticks on the Lock Screen without requiring push updates.

## Open questions — resolved per spec

| Question                      | Answer              | How it's wired                         |
|-------------------------------|---------------------|----------------------------------------|
| Haptics on timer events       | Yes                 | `Haptics.start()`, `.stop()` on tap    |
| Appearance                    | Follow system       | `preferredColorScheme(nil)`            |
| Calendar import sources       | All                 | `eventStore.calendars(for: .event)`    |
| Backup nudge                  | No — trust iCloud   | No periodic prompts                    |
| Future multi-device           | Design kept simple  | Every row has `updated_at`; entries are append-friendly and UUID-keyed so a future CRDT/last-write-wins sync layer can be bolted on without schema changes |

## Performance notes

Budgets from the spec are reflected in the design:

- **Cold start < 200 ms.** No splash screen. SQLite opens synchronously on first-use; migrations run inside a single transaction. The tab shell is a `TabView` with plain `NavigationStack`s — no storyboards, no lazy-load waterfalls.
- **Timer start/stop latency < 16 ms.** Haptic generators are pre-warmed in `ChronoApp.init`. A start writes two rows in a single transaction. The UI state update is a MainActor mutation on `@Observable` state; SwiftUI diffs just the banner and the tapped row.
- **Daily summary < 10 ms.** The `entry(start_time)` index + a partial index on running entries keeps the typical daily-summary query at a single index scan.
- **Binary size < 15 MB.** Zero external dependencies helps considerably.

## Running tests / verifying

There are no unit tests checked in yet — tests for the SQLite wrapper, repositories, and export formats would be the highest-value additions. The project structure is test-friendly (repositories are pure functions over a `SQLiteConnection`).

## License

TBD. Until a license is added, treat this as all-rights-reserved.
