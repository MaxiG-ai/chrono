# Chrono — Minimal iOS Time Tracker

> Spec Sheet v0.2 — Draft

---

## Vision

A dead-simple, blazing-fast time tracker for iOS. Inspired by [Timelines](https://timelines.app/) but stripped to the essentials: no cloud, no accounts, no subscription. Your data lives on-device in a local SQLite database, backed up to iCloud automatically.

---

## Design Principles

1. **Local-first** — All data stays on-device in a local SQLite database. iCloud backup only — no live sync, no network calls at runtime.
2. **Instant launch** — Cold start target: < 200 ms to interactive. No splash screen, no loading spinner.
3. **One-tap tracking** — Starting, stopping, and switching timers must never require more than a single tap from the main screen.
4. **Minimal UI** — Every screen earns its place. If it can be a sheet or a contextual action, it doesn't get a tab.
5. **Transparent data** — The user can always export, inspect, and migrate their raw data. No lock-in.

---

## Core Features

(See the spec document delivered with the project for the full feature matrix — timers, categories, timeline, stats, goals, widgets, calendar import, backups, export.)

---

## Open Questions — Resolved

| Question                      | Resolution             |
|-------------------------------|------------------------|
| Haptic feedback on timer events | Yes                  |
| Light/dark mode                 | Follow system        |
| Calendar import: all calendars? | Default to all       |
| Backup nudges                   | Trust iCloud         |
| Multi-device forward-compat     | Keep schema simple; each row has updated_at and a UUID primary key so a CRDT / LWW sync layer can be added later without a migration |
