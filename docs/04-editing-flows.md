# Editing Flows — Categories, Entries, Goals, Calendar Import

*2026-04-15T08:12:16Z by Showboat 0.6.1*
<!-- showboat-id: 7d48ee93-a399-4369-9e22-7d08e957d589 -->

Four edit surfaces, all presented as sheets on top of the main tabs. Each shares a consistent shape: a `Mode` enum (`.create` / `.edit(T)` / sometimes a specialised `.createFromX`) drives a single `Form`-based view.

| Sheet                 | File                                 | Source of truth after save   |
|-----------------------|--------------------------------------|------------------------------|
| Category edit/create  | `CategoryEditView.swift`           | `CategoryRepository`       |
| Entry edit/create     | `EntryEditView.swift`              | `EntryRepository`          |
| Goal create           | `GoalsView.swift` (`GoalEditView`)| `GoalRepository`           |
| Calendar import       | `CalendarImportView.swift`         | `EntryRepository` (via `EntryEditView` reuse) |

## `CategoryEditView`

The create and edit paths collapse into one view via `Mode`. The color picker is a `LazyVGrid` over a curated palette (14 hex values in `CategoryPalette`), not an arbitrary picker — keeps colors consistent across categories.

```bash
sed -n '4,10p' Chrono/Features/Categories/CategoryEditView.swift
```

```output
    enum Mode: Hashable {
        case create(parent: CategoryID?)
        case edit(TimeCategory)

        var isEdit: Bool { if case .edit = self { return true } else { return false } }
    }

```

## `EntryEditView`

The most reused view in the app. Its `Mode` includes a third case — `.createFromCalendar` — which is how calendar import builds on top of the same form.

```bash
sed -n '8,14p' Chrono/Features/Entry/EntryEditView.swift
```

```output
struct EntryEditView: View {
    enum Mode: Hashable {
        case create
        /// Prefilled state for calendar import, but not yet persisted.
        case createFromCalendar(prefilled: TimeEntry, calendarTitle: String?)
        case edit(TimeEntry)
    }
```

### Duplicate detection on calendar import

If you import the same event twice (exact same start + end), `EntryEditView` intercepts the save to show a one-shot confirmation alert. Under the hood it uses a tiny helper on `EntryRepository`:

```bash
sed -n '103,115p' Chrono/Database/EntryRepository.swift
```

```output
        return totals
    }

    /// Does an entry already exist with exact matching start and end?
    /// Used for calendar-import duplicate detection.
    static func exists(start: Date, end: Date, in db: SQLiteConnection) throws -> Bool {
        let sql = "SELECT 1 FROM entry WHERE start_time = ? AND end_time = ? LIMIT 1;"
        let rows = try db.query(sql, [.text(start.iso8601), .text(end.iso8601)]) { _ in 1 }
        return !rows.isEmpty
    }

    static func existsWithSourceId(_ sourceId: String, in db: SQLiteConnection) throws -> Bool {
        let sql = "SELECT 1 FROM entry WHERE source_id = ? LIMIT 1;"
```

## `CalendarImportView`

Uses EventKit read-only (`requestFullAccessToEvents` on iOS 17+). Flow:

1. Ask for calendar access on first presentation.
2. Query events in the selected range across **all** calendars (per spec: "Default to all").
3. For each event shown, check `existsWithSourceId(eventIdentifier)` to render a green "imported" badge if it's already been consumed.
4. Tapping an event builds a pre-filled `TimeEntry` and hands it to `EntryEditView(mode: .createFromCalendar(...))` where the user can tweak times and pick a category before confirming.

The app never writes to the calendar — `EKEventStore` is only ever queried.

```bash
sed -n '196,217p' Chrono/Features/Calendar/CalendarImportView.swift
```

```output
                        Text(event.title ?? "Untitled event")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if alreadyImported {
                            Label("Imported", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .font(.footnote)
                        }
                    }
                    Text(timeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(event.calendar.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
```

## `GoalsView` and `GoalEditView`

Goals are a tuple of (category, period, target minutes). Progress for each goal is computed by mapping period → date range and querying `store.totalsByCategory(from:to:)`. Progress is computed lazily on appear and re-computed on `entriesRevision` changes — same pattern as Stats and Timeline.
