import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Status widget

struct ChronoStatusWidget: Widget {
    let kind = "ChronoStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusTimelineProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Current Timer")
        .description("Shows the running timer and today's total.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct StatusTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: .init(
            topCategories: [.init(id: "1", name: "Deep Work", colorHex: "#3B82F6")],
            todaySecondsTracked: 2 * 3600 + 30 * 60
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let now = Date()
        // Refresh every 15 minutes. The running-timer duration updates visually
        // via `Text(timerInterval:)` without requiring a new timeline entry.
        let nextReload = now.addingTimeInterval(15 * 60)
        let timeline = Timeline(
            entries: [StatusEntry(date: now, snapshot: snapshot)],
            policy: .after(nextReload)
        )
        completion(timeline)
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: StatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    @ViewBuilder
    private var smallView: some View {
        if let running = entry.snapshot.running {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: running.colorHex)).frame(width: 8, height: 8)
                    Text(running.categoryName)
                        .font(.caption).bold()
                        .lineLimit(1)
                }
                Text(running.startDate, style: .timer)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: running.colorHex))
                Spacer()
                Text("Today: \(DurationFormatter.short(TimeInterval(entry.snapshot.todaySecondsTracked)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No timer").font(.caption).foregroundStyle(.secondary)
                Text(DurationFormatter.short(TimeInterval(entry.snapshot.todaySecondsTracked)))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text("tracked today").font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var mediumView: some View {
        HStack(alignment: .top, spacing: 12) {
            smallView
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick start").font(.caption).foregroundStyle(.secondary)
                ForEach(entry.snapshot.topCategories.prefix(3), id: \.id) { cat in
                    Button(intent: WidgetStartTimerIntent(categoryId: cat.id)) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: cat.colorHex)).frame(width: 8, height: 8)
                            Text(cat.name).font(.caption).lineLimit(1)
                            Spacer()
                            Image(systemName: "play.fill").font(.caption2).foregroundStyle(Color(hex: cat.colorHex))
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color(hex: cat.colorHex).opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let running = entry.snapshot.running {
                Text(running.categoryName).font(.caption).bold().lineLimit(1)
                Text(running.startDate, style: .timer).font(.body).monospacedDigit()
            } else {
                Text("Chrono").font(.caption).bold()
                Text("Today: \(DurationFormatter.short(TimeInterval(entry.snapshot.todaySecondsTracked)))")
                    .font(.caption)
            }
        }
    }

    private var circular: some View {
        ZStack {
            if entry.snapshot.running != nil {
                Image(systemName: "timer").font(.title2)
            } else {
                Image(systemName: "clock").font(.title2)
            }
        }
    }
}

// MARK: - Quick-start widget (Lock Screen)

struct ChronoQuickStartWidget: Widget {
    let kind = "ChronoQuickStartWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatusTimelineProvider()) { entry in
            QuickStartView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Quick Start")
        .description("Starts your favourite timer with one tap.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

struct QuickStartView: View {
    @Environment(\.widgetFamily) var family
    let entry: StatusEntry

    private var favourite: WidgetSnapshot.CategorySummary? {
        if let lastId = entry.snapshot.lastUsedCategoryId,
           let match = entry.snapshot.topCategories.first(where: { $0.id == lastId }) {
            return match
        }
        return entry.snapshot.topCategories.first
    }

    var body: some View {
        if let cat = favourite {
            switch family {
            case .accessoryCircular:
                Button(intent: WidgetStartTimerIntent(categoryId: cat.id)) {
                    ZStack {
                        Circle().fill(Color(hex: cat.colorHex).opacity(0.3))
                        Image(systemName: "play.fill").foregroundStyle(Color(hex: cat.colorHex))
                    }
                }
                .buttonStyle(.plain)
            default:
                Button(intent: WidgetStartTimerIntent(categoryId: cat.id)) {
                    VStack(spacing: 6) {
                        Circle().fill(Color(hex: cat.colorHex)).frame(width: 30, height: 30)
                            .overlay(Image(systemName: "play.fill").foregroundStyle(.white))
                        Text(cat.name).font(.caption).lineLimit(1)
                    }
                    .padding()
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("Add a category first").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget intents (separate from app intents so they're in-bundle)

struct WidgetStartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Timer (Widget)"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Category ID") var categoryId: String

    init() { self.categoryId = "" }
    init(categoryId: String) { self.categoryId = categoryId }

    func perform() async throws -> some IntentResult {
        var snapshot = WidgetSnapshot.load()
        if let cat = snapshot.topCategories.first(where: { $0.id == categoryId }) {
            snapshot.running = .init(
                categoryId: cat.id,
                categoryName: cat.name,
                colorHex: cat.colorHex,
                startDate: Date()
            )
            snapshot.lastUsedCategoryId = cat.id
            snapshot.updatedAt = Date()
            snapshot.save()
        }
        // Record a pending action for the app to reconcile into SQLite on next
        // launch. The widget process can't safely write to the SQLite database
        // while the app might also be writing.
        PendingAction.enqueueStart(categoryId: categoryId, at: Date())
        return .result()
    }
}

// PendingAction lives in Chrono/Shared/WidgetShared/PendingAction.swift so both
// the app target (for replay) and the widget target (for enqueue) can use it.
