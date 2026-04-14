import SwiftUI

/// The "one-tap" main screen. The top third is the running-timer banner
/// (always visible, even when nothing is running). The list below is the
/// category grid — a tap toggles or switches the timer in a single gesture.
struct TrackView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(LiveClock.self) private var clock
    let onOpenSettings: () -> Void

    @State private var showingAddCategory = false
    @State private var expandedCategory: CategoryID? = nil
    @State private var editingEntry: TimeEntry? = nil
    @State private var showingManualEntry = false
    @State private var showingCalendarImport = false
    @State private var showingGoals = false
    @State private var showingCategoryManager = false

    var body: some View {
        VStack(spacing: 0) {
            RunningBanner(entry: store.runningEntry,
                          category: store.category(store.runningEntry?.categoryId),
                          now: clock.now,
                          onStop: { Task { await store.stopTimer() } },
                          onEdit: { entry in editingEntry = entry })

            categoryList
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Chrono")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { showingCategoryManager = true } label: {
                        Label("Edit Categories", systemImage: "square.grid.2x2")
                    }
                    Button { showingGoals = true } label: {
                        Label("Goals", systemImage: "target")
                    }
                    Button { showingManualEntry = true } label: {
                        Label("Add Past Entry", systemImage: "plus.square.on.square")
                    }
                    Button { showingCalendarImport = true } label: {
                        Label("Import from Calendar", systemImage: "calendar.badge.plus")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingAddCategory) {
            NavigationStack {
                CategoryEditView(mode: .create(parent: nil))
            }
        }
        .sheet(isPresented: $showingManualEntry) {
            NavigationStack {
                EntryEditView(mode: .create)
            }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                EntryEditView(mode: .edit(entry))
            }
        }
        .sheet(isPresented: $showingCalendarImport) {
            NavigationStack {
                CalendarImportView()
            }
        }
        .sheet(isPresented: $showingGoals) {
            NavigationStack {
                GoalsView()
            }
        }
        .sheet(isPresented: $showingCategoryManager) {
            NavigationStack {
                CategoryListView()
            }
        }
    }

    private var categoryList: some View {
        List {
            Section {
                ForEach(store.topLevelCategories()) { cat in
                    CategoryRow(
                        category: cat,
                        subcategories: store.subcategories(of: cat.id),
                        runningEntry: store.runningEntry,
                        now: clock.now,
                        isExpanded: expandedCategory == cat.id,
                        onTap: { Task { await store.toggleOrSwitch(to: cat.id) } },
                        onTapSub: { subId in Task { await store.toggleOrSwitch(to: subId) } },
                        onToggleExpand: {
                            withAnimation(.snappy(duration: 0.2)) {
                                expandedCategory = expandedCategory == cat.id ? nil : cat.id
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text("Categories")
                    Spacer()
                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("New", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Running banner

private struct RunningBanner: View {
    let entry: TimeEntry?
    let category: TimeCategory?
    let now: Date
    let onStop: () -> Void
    let onEdit: (TimeEntry) -> Void

    var body: some View {
        Group {
            if let entry, let category {
                activeBanner(entry: entry, category: category)
            } else {
                idleBanner
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func activeBanner(entry: TimeEntry, category: TimeCategory) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(category.color)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().stroke(category.color.opacity(0.35), lineWidth: 6)
                        .scaleEffect(1.5)
                        .opacity(0.8)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(DurationFormatter.timer(entry.duration(reference: now)))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(category.color)
            }
            Spacer()
            Button {
                onEdit(entry)
            } label: {
                Image(systemName: "pencil")
                    .font(.title3)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
            }
            Button {
                onStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.red, in: Circle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(category.color.opacity(0.12))
        )
    }

    private var idleBanner: some View {
        HStack {
            Image(systemName: "timer")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No timer running — tap a category to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Category row

private struct CategoryRow: View {
    let category: TimeCategory
    let subcategories: [TimeCategory]
    let runningEntry: TimeEntry?
    let now: Date
    let isExpanded: Bool
    let onTap: () -> Void
    let onTapSub: (CategoryID) -> Void
    let onToggleExpand: () -> Void

    private var isRunning: Bool { runningEntry?.categoryId == category.id }
    private var runningSubId: CategoryID? {
        guard let running = runningEntry else { return nil }
        return subcategories.first(where: { $0.id == running.categoryId })?.id
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(category.color)
                        .frame(width: 10, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if isRunning, let running = runningEntry {
                            Text(DurationFormatter.timer(running.duration(reference: now)))
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(category.color)
                        } else if let subId = runningSubId, let running = runningEntry,
                                  let sub = subcategories.first(where: { $0.id == subId }) {
                            Text("\(sub.name) · \(DurationFormatter.timer(running.duration(reference: now)))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(category.color)
                        } else {
                            Text("Tap to start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !subcategories.isEmpty {
                        Button(action: onToggleExpand) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .foregroundStyle(isRunning ? Color.red : category.color)
                        .font(.title3)
                        .padding(8)
                        .background(
                            Circle().fill(isRunning ? Color.red.opacity(0.12) : category.color.opacity(0.14))
                        )
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isRunning ? category.color.opacity(0.7) : Color.clear, lineWidth: 2)
                )
            }
            .buttonStyle(.plain)

            if isExpanded && !subcategories.isEmpty {
                VStack(spacing: 6) {
                    ForEach(subcategories) { sub in
                        SubcategoryRow(
                            sub: sub,
                            parentColor: category.color,
                            isRunning: runningEntry?.categoryId == sub.id,
                            runningDuration: runningEntry?.categoryId == sub.id
                                ? runningEntry?.duration(reference: now) ?? 0
                                : 0,
                            onTap: { onTapSub(sub.id) }
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}

private struct SubcategoryRow: View {
    let sub: TimeCategory
    let parentColor: Color
    let isRunning: Bool
    let runningDuration: TimeInterval
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(sub.color)
                    .frame(width: 4, height: 28)
                Text(sub.name).font(.subheadline)
                Spacer()
                if isRunning {
                    Text(DurationFormatter.timer(runningDuration))
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(sub.color)
                }
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .foregroundStyle(isRunning ? Color.red : sub.color)
                    .font(.footnote)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isRunning ? sub.color.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
