# Chrono — Architecture Overview

*2026-04-15T08:07:10Z by Showboat 0.6.1*
<!-- showboat-id: 6af09388-531d-458b-916c-9b587e29f800 -->

Chrono is a minimal, local-first iOS time tracker. The entire implementation lives in two Xcode targets generated from `project.yml` via XcodeGen:

- **`Chrono`** — the iOS app, built with SwiftUI targeting iOS 17+
- **`ChronoWidget`** — the widget extension (status widget, quick-start widget, and Live Activity)

There are no external Swift packages. The app talks to the system `libsqlite3` through a hand-written ~250-line wrapper.

## Component layers

```
 ┌────────────────────────────────────────────────────────────────┐
 │ SwiftUI views (Track, Timeline, Stats, edit sheets, Settings) │
 └─────────────────────────┬──────────────────────────────────────┘
                           │  @Observable
                           ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ ChronoStore  ·  in-memory observable state, drives all UI      │
 └─────────────────────────┬──────────────────────────────────────┘
                           │  async read/write
                           ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ Repositories (CategoryRepository, EntryRepository, …)          │
 └─────────────────────────┬──────────────────────────────────────┘
                           │  parametrised SQL
                           ▼
 ┌────────────────────────────────────────────────────────────────┐
 │ Database  ·  serial queue + SQLiteConnection (WAL mode)        │
 └────────────────────────────────────────────────────────────────┘
```

Widgets read a tiny snapshot written by the app instead of touching SQLite directly — see `docs/06-component-interactions.md`.

## Top-level layout

```bash
ls -1 /home/user/chrono
```

```output
Chrono
ChronoWidget
README.md
SPEC.md
docs
project.yml
```

## Source tree

Every Swift file in the project, grouped by feature. The `Chrono/` target is the app; `ChronoWidget/` is the extension; `Chrono/Shared/WidgetShared/` is shared source compiled into both targets.

```bash
find Chrono ChronoWidget -type f -name '*.swift' | sort
```

```output
Chrono/App/ChronoApp.swift
Chrono/App/RootView.swift
Chrono/Database/CategoryRepository.swift
Chrono/Database/ChronoStore.swift
Chrono/Database/Database.swift
Chrono/Database/EntryRepository.swift
Chrono/Database/GoalRepository.swift
Chrono/Database/Migrations.swift
Chrono/Database/SQLite.swift
Chrono/Features/Calendar/CalendarImportView.swift
Chrono/Features/Categories/CategoryEditView.swift
Chrono/Features/Categories/CategoryListView.swift
Chrono/Features/Entry/EntryEditView.swift
Chrono/Features/Goals/GoalsView.swift
Chrono/Features/Settings/BackupManager.swift
Chrono/Features/Settings/ExportManager.swift
Chrono/Features/Settings/SettingsView.swift
Chrono/Features/Stats/StatsView.swift
Chrono/Features/Timeline/TimelineView.swift
Chrono/Features/Track/TrackView.swift
Chrono/Intents/ChronoIntents.swift
Chrono/LiveActivity/ChronoActivityAttributes.swift
Chrono/LiveActivity/LiveActivityController.swift
Chrono/Models/Models.swift
Chrono/Shared/Color+Hex.swift
Chrono/Shared/Date+Extensions.swift
Chrono/Shared/Haptics.swift
Chrono/Shared/LiveClock.swift
Chrono/Shared/WidgetShared/PendingAction.swift
Chrono/Shared/WidgetShared/WidgetSnapshot.swift
ChronoWidget/ChronoLiveActivity.swift
ChronoWidget/ChronoStatusWidget.swift
ChronoWidget/ChronoWidgetBundle.swift
```

## Tabs and navigation

Three tabs, no more. Settings is a sheet — the spec is explicit: *"If it can be a sheet or a contextual action, it doesn't get a tab."*

```bash
sed -n '8,26p' Chrono/App/RootView.swift
```

```output
    enum Tab: Hashable { case track, timeline, stats }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TrackView(onOpenSettings: { showingSettings = true })
            }
            .tabItem { Label("Track", systemImage: "timer") }
            .tag(Tab.track)

            NavigationStack {
                TimelineView()
            }
            .tabItem { Label("Timeline", systemImage: "chart.bar.doc.horizontal") }
            .tag(Tab.timeline)

            NavigationStack {
                StatsView()
            }
```

## Where each doc goes

| File                                | Covers                                               |
|-------------------------------------|------------------------------------------------------|
| `00-overview.md` (this doc)       | Big picture, tech stack, file tree                   |
| `01-data-layer.md`                | SQLite wrapper → Migrations → Database               |
| `02-models-and-repositories.md`   | Value types and their repositories                   |
| `03-store-and-views.md`           | `ChronoStore` and the three tab views              |
| `04-editing-flows.md`             | Category, entry, goal, and calendar-import sheets    |
| `05-settings-and-backup.md`       | Export formats, backup strategy, restore flow        |
| `06-widgets-and-intents.md`       | Widgets, Live Activity, App Intents                  |
| `07-component-interactions.md`    | Data flow diagrams across the stack                  |
