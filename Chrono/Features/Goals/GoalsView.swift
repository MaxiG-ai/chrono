import SwiftUI

/// Set and review daily / weekly / monthly time targets per category.
struct GoalsView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false
    @State private var progressByGoal: [GoalID: TimeInterval] = [:]

    var body: some View {
        List {
            if store.goals.isEmpty {
                ContentUnavailableView(
                    "No goals yet",
                    systemImage: "target",
                    description: Text("Set a daily, weekly, or monthly time target for a category.")
                )
            }
            ForEach(store.goals) { goal in
                if let cat = store.category(goal.categoryId) {
                    GoalRow(
                        goal: goal,
                        category: cat,
                        progressSeconds: progressByGoal[goal.id] ?? 0,
                        onDelete: { Task { await store.deleteGoal(goal.id) } }
                    )
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                GoalEditView()
            }
        }
        .task(id: store.entriesRevision) { await loadProgress() }
        .task { await loadProgress() }
    }

    private func loadProgress() async {
        var result: [GoalID: TimeInterval] = [:]
        for goal in store.goals {
            let (start, end) = range(for: goal.period)
            let totals = await store.totalsByCategory(from: start, to: end)
            result[goal.id] = totals[goal.categoryId] ?? 0
        }
        progressByGoal = result
    }

    private func range(for period: GoalPeriod) -> (Date, Date) {
        let now = Date()
        switch period {
        case .daily:
            let start = now.startOfDay()
            return (start, start.adding(days: 1))
        case .weekly:
            let start = now.startOfWeek()
            return (start, start.adding(days: 7))
        case .monthly:
            let start = now.startOfMonth()
            let next = Calendar.current.date(byAdding: .month, value: 1, to: start) ?? start
            return (start, next)
        }
    }
}

private struct GoalRow: View {
    let goal: Goal
    let category: TimeCategory
    let progressSeconds: TimeInterval
    let onDelete: () -> Void

    private var fraction: Double {
        guard goal.targetSeconds > 0 else { return 0 }
        return min(1.0, progressSeconds / goal.targetSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(category.color).frame(width: 10, height: 10)
                Text(category.name).font(.headline)
                Spacer()
                Text(goal.period.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: fraction)
                .tint(category.color)

            HStack {
                Text("\(DurationFormatter.short(progressSeconds)) / \(formatMinutes(goal.targetMinutes))")
                    .font(.footnote)
                    .monospacedDigit()
                Spacer()
                if fraction >= 1 {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Text(String(format: "%.0f%%", fraction * 100))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = Double(minutes) / 60
            return String(format: "%.1fh", h)
        }
        return "\(minutes)m"
    }
}

struct GoalEditView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var categoryId: CategoryID?
    @State private var period: GoalPeriod = .daily
    @State private var hours: Double = 1.0

    var body: some View {
        Form {
            Section("Category") {
                Picker("Category", selection: $categoryId) {
                    Text("Choose…").tag(CategoryID?.none)
                    ForEach(store.topLevelCategories()) { cat in
                        HStack {
                            Circle().fill(cat.color).frame(width: 10, height: 10)
                            Text(cat.name)
                        }
                        .tag(Optional(cat.id))
                    }
                }
            }

            Section("Period") {
                Picker("Period", selection: $period) {
                    ForEach(GoalPeriod.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Target") {
                Stepper(value: $hours, in: 0.25...24 * 7, step: 0.25) {
                    Text(String(format: "%.2f hours", hours))
                        .monospacedDigit()
                }
            }
        }
        .navigationTitle("New Goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    guard let id = categoryId else { return }
                    Task {
                        let mins = Int((hours * 60).rounded())
                        await store.addGoal(categoryId: id, period: period, targetMinutes: mins)
                        dismiss()
                    }
                }
                .disabled(categoryId == nil)
                .bold()
            }
        }
        .onAppear {
            if categoryId == nil { categoryId = store.topLevelCategories().first?.id }
        }
    }
}
