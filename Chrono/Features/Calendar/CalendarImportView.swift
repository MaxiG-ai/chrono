import SwiftUI
import EventKit

/// Read-only calendar import (spec: Feature 7).
///
/// Shows events in a date range and lets the user import one as a time entry.
/// We never write back to the calendar. Duplicate detection uses the SQLite
/// `source_id` index plus exact start/end matches.
struct CalendarImportView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var events: [EKEvent] = []
    @State private var rangeStart: Date = Date().adding(days: -7).startOfDay()
    @State private var rangeEnd: Date = Date().adding(days: 1).startOfDay()
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var importTarget: EKEvent?
    @State private var prefilledEntry: TimeEntry?
    @State private var showingImportSheet = false
    @State private var alreadyImportedIds: Set<String> = []

    private let eventStore = EKEventStore()

    var body: some View {
        Form {
            Section("Date range") {
                DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                    .onChange(of: rangeStart) { _, _ in Task { await loadEvents() } }
                DatePicker("To", selection: $rangeEnd, displayedComponents: .date)
                    .onChange(of: rangeEnd) { _, _ in Task { await loadEvents() } }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            switch authorizationStatus {
            case .notDetermined:
                Section {
                    Button("Allow Calendar Access") {
                        Task { await requestAccess() }
                    }
                }
            case .denied, .restricted:
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendar access is denied.").font(.headline)
                        Text("Open Settings → Privacy → Calendars and allow Chrono.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                Section("Events") {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading…").foregroundStyle(.secondary)
                        }
                    } else if events.isEmpty {
                        Text("No events in this range.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events, id: \.eventIdentifier) { event in
                            EventRow(
                                event: event,
                                alreadyImported: alreadyImportedIds.contains(event.eventIdentifier ?? ""),
                                onTap: { prefill(with: event) }
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Import from Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
        }
        .sheet(isPresented: $showingImportSheet, onDismiss: { Task { await refreshImported() } }) {
            if let prefilledEntry, let title = importTarget?.title {
                NavigationStack {
                    EntryEditView(mode: .createFromCalendar(prefilled: prefilledEntry, calendarTitle: title))
                }
            }
        }
        .task {
            await ensureAccessAndLoad()
        }
    }

    // MARK: - Permissions & loading

    private func ensureAccessAndLoad() async {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .notDetermined {
            await requestAccess()
        }
        if authorizationStatus == .fullAccess || authorizationStatus == .authorized {
            await loadEvents()
        }
    }

    private func requestAccess() async {
        do {
            // iOS 17+: requestFullAccessToEvents. Fall back for older SDKs at compile time.
            if #available(iOS 17.0, *) {
                let granted = try await eventStore.requestFullAccessToEvents()
                authorizationStatus = granted ? .fullAccess : .denied
            } else {
                let granted = try await eventStore.requestAccess(to: .event)
                authorizationStatus = granted ? .authorized : .denied
            }
            if authorizationStatus == .fullAccess || authorizationStatus == .authorized {
                await loadEvents()
            }
        } catch {
            errorMessage = "Couldn't request calendar access: \(error.localizedDescription)"
        }
    }

    private func loadEvents() async {
        guard authorizationStatus == .fullAccess || authorizationStatus == .authorized else { return }
        isLoading = true
        defer { isLoading = false }
        let calendars = eventStore.calendars(for: .event)
        // Events returned by this predicate include all calendars per spec default.
        let predicate = eventStore.predicateForEvents(
            withStart: rangeStart,
            end: rangeEnd.adding(days: 1),
            calendars: calendars
        )
        let found = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }  // all-day events have fuzzy start/end — skip
            .sorted { $0.startDate > $1.startDate }
        self.events = found
        await refreshImported()
    }

    private func refreshImported() async {
        var imported: Set<String> = []
        for event in events {
            guard let id = event.eventIdentifier else { continue }
            let exists = (try? await Database.shared.readAsync { db in
                try EntryRepository.existsWithSourceId(id, in: db)
            }) ?? false
            if exists { imported.insert(id) }
        }
        alreadyImportedIds = imported
    }

    // MARK: - Import flow

    private func prefill(with event: EKEvent) {
        let firstCategory = store.topLevelCategories().first
        guard let categoryId = firstCategory?.id else {
            errorMessage = "Create at least one category before importing."
            return
        }
        let prefilled = TimeEntry(
            id: EntryID(),
            categoryId: categoryId,
            startTime: event.startDate,
            endTime: event.endDate,
            note: event.title,
            source: .calendarImport,
            sourceId: event.eventIdentifier,
            createdAt: Date(),
            updatedAt: Date()
        )
        importTarget = event
        prefilledEntry = prefilled
        showingImportSheet = true
    }
}

private struct EventRow: View {
    let event: EKEvent
    let alreadyImported: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color(cgColor: event.calendar.cgColor))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "\(f.string(from: event.startDate)) – \(shortTime(event.endDate))"
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }
}
