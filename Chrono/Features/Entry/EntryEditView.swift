import SwiftUI

/// Create or edit a single time entry. Used for:
/// - Retroactive manual entries (spec #1, Retroactive entries)
/// - Editing the currently-running entry (via the running banner's pencil button)
/// - Editing a historical entry tapped from the timeline
/// - Confirming a calendar-import before saving (via a prefilled mode)
struct EntryEditView: View {
    enum Mode: Hashable {
        case create
        /// Prefilled state for calendar import, but not yet persisted.
        case createFromCalendar(prefilled: TimeEntry, calendarTitle: String?)
        case edit(TimeEntry)
    }

    let mode: Mode

    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: CategoryID?
    @State private var startTime: Date = Date()
    @State private var endTime: Date = Date()
    @State private var hasEnd: Bool = true
    @State private var note: String = ""
    @State private var source: EntrySource = .manual
    @State private var sourceId: String?

    @State private var duplicateWarning: Bool = false

    var body: some View {
        Form {
            Section("Category") {
                Picker("Category", selection: $categoryId) {
                    Text("Choose…").tag(CategoryID?.none)
                    ForEach(store.topLevelCategories()) { cat in
                        categoryPickerRow(cat)
                        ForEach(store.subcategories(of: cat.id)) { sub in
                            Text("   ↳ \(sub.name)").tag(Optional(sub.id))
                        }
                    }
                }
                .pickerStyle(.navigationLink)
            }

            Section("Time") {
                DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                Toggle("Has end time", isOn: $hasEnd)
                if hasEnd {
                    DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text(DurationFormatter.short(endTime.timeIntervalSince(startTime)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Entry is running — will stop when you start another category.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Note") {
                TextField("Optional", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            }

            if case .createFromCalendar(_, let title) = mode, let title {
                Section("Imported from") {
                    Label(title, systemImage: "calendar")
                        .foregroundStyle(.secondary)
                }
            }

            if case .edit(let entry) = mode {
                Section {
                    Button(role: .destructive) {
                        Task {
                            await store.deleteEntry(entry.id)
                            dismiss()
                        }
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(titleForMode)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await saveTapped() } }
                    .disabled(categoryId == nil || (hasEnd && endTime <= startTime))
                    .bold()
            }
        }
        .alert("Duplicate entry?", isPresented: $duplicateWarning) {
            Button("Import Anyway", role: .destructive) {
                Task { await performSave() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An entry with the exact same start and end already exists. Import anyway?")
        }
        .onAppear(perform: configureForMode)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func categoryPickerRow(_ cat: TimeCategory) -> some View {
        HStack {
            Circle().fill(cat.color).frame(width: 10, height: 10)
            Text(cat.name)
        }
        .tag(Optional(cat.id))
    }

    private var titleForMode: String {
        switch mode {
        case .create: "New Entry"
        case .createFromCalendar: "Import Event"
        case .edit: "Edit Entry"
        }
    }

    private func configureForMode() {
        switch mode {
        case .create:
            // Default to the last hour so typical back-logging is one tweak away.
            endTime = Date()
            startTime = Date().addingTimeInterval(-3600)
            hasEnd = true
            categoryId = store.topLevelCategories().first?.id
        case .createFromCalendar(let prefilled, _):
            categoryId = prefilled.categoryId
            startTime = prefilled.startTime
            endTime = prefilled.endTime ?? prefilled.startTime.addingTimeInterval(3600)
            hasEnd = prefilled.endTime != nil
            note = prefilled.note ?? ""
            source = prefilled.source
            sourceId = prefilled.sourceId
        case .edit(let entry):
            categoryId = entry.categoryId
            startTime = entry.startTime
            if let end = entry.endTime {
                endTime = end
                hasEnd = true
            } else {
                endTime = Date()
                hasEnd = false
            }
            note = entry.note ?? ""
            source = entry.source
            sourceId = entry.sourceId
        }
    }

    private func saveTapped() async {
        guard let categoryId else { return }
        let finalEnd: Date? = hasEnd ? endTime : nil

        // Duplicate detection: only makes sense for fully-bounded entries with an end time.
        if case .createFromCalendar = mode, let finalEnd {
            if let existingConflict = try? await checkDuplicate(start: startTime, end: finalEnd), existingConflict {
                duplicateWarning = true
                return
            }
        }
        _ = categoryId  // silence warning if unused in this path
        await performSave()
    }

    private func checkDuplicate(start: Date, end: Date) async throws -> Bool {
        try await Database.shared.readAsync { db in
            try EntryRepository.exists(start: start, end: end, in: db)
        }
    }

    private func performSave() async {
        guard let categoryId else { return }
        let finalEnd: Date? = hasEnd ? endTime : nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = trimmedNote.isEmpty ? nil : trimmedNote

        switch mode {
        case .create, .createFromCalendar:
            let entry = TimeEntry(
                id: EntryID(),
                categoryId: categoryId,
                startTime: startTime,
                endTime: finalEnd,
                note: finalNote,
                source: source,
                sourceId: sourceId,
                createdAt: Date(),
                updatedAt: Date()
            )
            await store.addEntry(entry)
        case .edit(var entry):
            entry.categoryId = categoryId
            entry.startTime = startTime
            entry.endTime = finalEnd
            entry.note = finalNote
            await store.updateEntry(entry)
        }
        Haptics.success()
        dismiss()
    }
}
