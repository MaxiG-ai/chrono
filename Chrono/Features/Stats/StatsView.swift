import SwiftUI
import Charts

/// Summary, trends, and "where did my time go?" ring chart for a selected range.
struct StatsView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(LiveClock.self) private var clock

    @State private var period: Period = .week
    @State private var totalsForPeriod: [(category: TimeCategory, seconds: TimeInterval)] = []
    @State private var seriesByDay: [DailyTotalsPoint] = []
    @State private var totalSeconds: TimeInterval = 0
    @State private var previousTotalSeconds: TimeInterval = 0

    enum Period: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: "Day"
            case .week: "Week"
            case .month: "Month"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Total") {
                HStack(alignment: .lastTextBaseline) {
                    Text(DurationFormatter.short(totalSeconds))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Spacer()
                    trendLabel
                }
            }

            if !totalsForPeriod.isEmpty {
                Section("Where did your time go?") {
                    RingChart(slices: totalsForPeriod, totalSeconds: totalSeconds)
                        .frame(height: 220)
                        .padding(.vertical, 8)

                    ForEach(totalsForPeriod, id: \.category.id) { row in
                        LegendRow(category: row.category,
                                  seconds: row.seconds,
                                  total: totalSeconds)
                    }
                }

                Section("By day") {
                    BarsByDay(points: seriesByDay, categories: store.categories)
                        .frame(height: 200)
                }
            } else {
                Section {
                    Text("No entries in this period yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) { await load() }
        .onChange(of: store.entriesRevision) { _, _ in Task { await load() } }
    }

    private var trendLabel: some View {
        Group {
            if previousTotalSeconds > 0 {
                let delta = totalSeconds - previousTotalSeconds
                let pct = delta / previousTotalSeconds * 100
                let up = delta >= 0
                Label(
                    String(format: "%@%.0f%%", up ? "+" : "", pct),
                    systemImage: up ? "arrow.up.right" : "arrow.down.right"
                )
                .font(.subheadline)
                .foregroundStyle(up ? Color.green : Color.red)
            } else if totalSeconds > 0 {
                Text("First period").font(.subheadline).foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        }
    }

    private func load() async {
        let (start, end) = range(for: period, anchor: Date())
        let (prevStart, prevEnd) = previousRange(for: period, anchor: Date())

        let totals = await store.totalsByCategory(from: start, to: end)
        let prevTotals = await store.totalsByCategory(from: prevStart, to: prevEnd)

        let lookup = Dictionary(uniqueKeysWithValues: store.categories.map { ($0.id, $0) })
        var rows: [(TimeCategory, TimeInterval)] = []
        for (id, seconds) in totals {
            if let cat = lookup[id] { rows.append((cat, seconds)) }
        }
        rows.sort { $0.1 > $1.1 }

        totalsForPeriod = rows
        totalSeconds = rows.reduce(0) { $0 + $1.1 }
        previousTotalSeconds = prevTotals.values.reduce(0, +)

        // Per-day breakdown for the bar chart.
        var byDay: [DailyTotalsPoint] = []
        let dayCount = calendar.dateComponents([.day], from: start, to: end).day ?? 1
        for d in 0..<max(1, dayCount) {
            let dayStart = start.adding(days: d)
            let dayEnd = dayStart.adding(days: 1)
            let t = await store.totalsByCategory(from: dayStart, to: dayEnd)
            for (id, secs) in t {
                guard let cat = lookup[id] else { continue }
                byDay.append(DailyTotalsPoint(day: dayStart, category: cat, seconds: secs))
            }
        }
        seriesByDay = byDay
    }

    private var calendar: Calendar { .current }

    private func range(for period: Period, anchor: Date) -> (Date, Date) {
        switch period {
        case .day:
            let start = anchor.startOfDay()
            return (start, start.adding(days: 1))
        case .week:
            let start = anchor.startOfWeek()
            return (start, start.adding(days: 7))
        case .month:
            let start = anchor.startOfMonth()
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (start, nextMonth)
        }
    }

    private func previousRange(for period: Period, anchor: Date) -> (Date, Date) {
        switch period {
        case .day:
            let start = anchor.startOfDay().adding(days: -1)
            return (start, start.adding(days: 1))
        case .week:
            let start = anchor.startOfWeek().adding(days: -7)
            return (start, start.adding(days: 7))
        case .month:
            let month = anchor.startOfMonth()
            let start = calendar.date(byAdding: .month, value: -1, to: month) ?? month
            return (start, month)
        }
    }
}

// MARK: - Chart types

private struct DailyTotalsPoint: Hashable {
    let day: Date
    let category: TimeCategory
    let seconds: TimeInterval
}

private struct BarsByDay: View {
    let points: [DailyTotalsPoint]
    let categories: [TimeCategory]

    var body: some View {
        Chart {
            ForEach(points, id: \.self) { p in
                BarMark(
                    x: .value("Day", p.day, unit: .day),
                    y: .value("Hours", p.seconds / 3600.0)
                )
                .foregroundStyle(by: .value("Category", p.category.name))
            }
        }
        .chartForegroundStyleScale(range: chartColors)
        .chartYAxis {
            AxisMarks(format: .number.precision(.fractionLength(0)))
        }
    }

    /// Map category names → their configured hex color for consistent bar fills.
    private var chartColors: [Color] {
        let names = Array(Set(points.map(\.category.name))).sorted()
        return names.compactMap { name in
            categories.first(where: { $0.name == name })?.color
        }
    }
}

private struct RingChart: View {
    let slices: [(category: TimeCategory, seconds: TimeInterval)]
    let totalSeconds: TimeInterval

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(drawSlices(), id: \.0.id) { (cat, start, end) in
                    RingSlice(startFraction: start, endFraction: end, thickness: 0.25)
                        .fill(cat.color)
                }
                VStack(spacing: 2) {
                    Text(DurationFormatter.short(totalSeconds))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text("tracked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
        }
    }

    private func drawSlices() -> [(TimeCategory, Double, Double)] {
        guard totalSeconds > 0 else { return [] }
        var start = 0.0
        var out: [(TimeCategory, Double, Double)] = []
        for slice in slices {
            let fraction = slice.seconds / totalSeconds
            out.append((slice.category, start, start + fraction))
            start += fraction
        }
        return out
    }
}

/// A single arc of the ring chart. Thickness is a fraction of the radius (0…1).
private struct RingSlice: Shape {
    let startFraction: Double
    let endFraction: Double
    let thickness: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * (1 - thickness)
        let startAngle = Angle(degrees: startFraction * 360 - 90)
        let endAngle = Angle(degrees: endFraction * 360 - 90)

        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct LegendRow: View {
    let category: TimeCategory
    let seconds: TimeInterval
    let total: TimeInterval

    var body: some View {
        HStack {
            Circle()
                .fill(category.color)
                .frame(width: 10, height: 10)
            Text(category.name)
            Spacer()
            Text(DurationFormatter.short(seconds))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if total > 0 {
                Text(String(format: "%.0f%%", seconds / total * 100))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}
