import SwiftUI

/// Vertical day timeline with pinch-to-zoom. Each category block is drawn as a
/// coloured bar proportional to its duration; gaps are left as empty space so
/// untracked time is visually obvious (spec requirement).
struct TimelineView: View {
    @Environment(ChronoStore.self) private var store
    @Environment(LiveClock.self) private var clock

    @State private var selectedDate: Date = Date().startOfDay()
    @State private var entries: [TimeEntry] = []
    @State private var selectedEntry: TimeEntry?

    // Points per hour. Pinch to zoom adjusts this.
    @State private var pointsPerHour: CGFloat = 60
    @GestureState private var pinchScale: CGFloat = 1.0

    private let minPointsPerHour: CGFloat = 20
    private let maxPointsPerHour: CGFloat = 240

    private var effectivePointsPerHour: CGFloat {
        max(minPointsPerHour, min(maxPointsPerHour, pointsPerHour * pinchScale))
    }

    var body: some View {
        VStack(spacing: 0) {
            DateNavigator(selected: $selectedDate, onChange: load)

            ScrollView {
                TimelineCanvas(
                    date: selectedDate,
                    entries: entries,
                    now: clock.now,
                    pointsPerHour: effectivePointsPerHour,
                    categoryLookup: { store.category($0) },
                    onSelect: { selectedEntry = $0 }
                )
                .padding(.vertical, 16)
            }
            .gesture(pinchGesture)
        }
        .navigationTitle("Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedDate) { await load() }
        .onChange(of: store.entriesRevision) { _, _ in Task { await load() } }
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                EntryEditView(mode: .edit(entry))
            }
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in state = value }
            .onEnded { value in
                pointsPerHour = max(minPointsPerHour, min(maxPointsPerHour, pointsPerHour * value))
            }
    }

    private func load() async {
        let start = selectedDate.startOfDay()
        let end = start.adding(days: 1)
        entries = await store.entries(from: start, to: end)
    }
}

// MARK: - Date navigator

private struct DateNavigator: View {
    @Binding var selected: Date
    let onChange: () async -> Void

    var body: some View {
        HStack {
            Button {
                selected = selected.adding(days: -1)
                Task { await onChange() }
            } label: {
                Image(systemName: "chevron.left")
            }

            Spacer()

            VStack(spacing: 2) {
                Text(formattedDate)
                    .font(.headline)
                Text(relativeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selected = Date().startOfDay()
                Task { await onChange() }
            }

            Spacer()

            Button {
                let next = selected.adding(days: 1)
                if next <= Date().startOfDay() {
                    selected = next
                    Task { await onChange() }
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(Calendar.current.isDateInToday(selected))
            .opacity(Calendar.current.isDateInToday(selected) ? 0.3 : 1)
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .full
        return f.string(from: selected)
    }

    private var relativeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(selected) { return "Today · tap to refresh" }
        if cal.isDateInYesterday(selected) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: selected, to: Date()).day ?? 0
        return "\(days) days ago"
    }
}

// MARK: - Canvas

private struct TimelineCanvas: View {
    let date: Date
    let entries: [TimeEntry]
    let now: Date
    let pointsPerHour: CGFloat
    let categoryLookup: (CategoryID) -> TimeCategory?
    let onSelect: (TimeEntry) -> Void

    private let leftGutter: CGFloat = 52

    var body: some View {
        let total = pointsPerHour * 24
        ZStack(alignment: .topLeading) {
            hourGrid(height: total)

            ForEach(visibleSegments()) { seg in
                segmentView(seg)
            }

            if Calendar.current.isDateInToday(date) {
                nowIndicator(height: total)
            }
        }
        .frame(height: total)
        .padding(.horizontal)
    }

    private func hourGrid(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: leftGutter - 8, alignment: .trailing)
                    Rectangle()
                        .fill(Color(.separator).opacity(0.3))
                        .frame(height: 0.5)
                }
                .frame(height: pointsPerHour, alignment: .top)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let comps = DateComponents(hour: hour)
        let d = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f.string(from: d)
    }

    private func nowIndicator(height: CGFloat) -> some View {
        let start = date.startOfDay()
        let offset = max(0, min(height, CGFloat(now.timeIntervalSince(start) / 3600) * pointsPerHour))
        return HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1.5)
        }
        .padding(.leading, leftGutter - 10)
        .offset(y: offset - 4)
    }

    // MARK: Segment layout

    private struct TimelineSegment: Identifiable {
        let id: EntryID
        let entry: TimeEntry
        let offset: CGFloat
        let height: CGFloat
    }

    private func visibleSegments() -> [TimelineSegment] {
        let dayStart = date.startOfDay()
        let dayEnd = dayStart.adding(days: 1)
        var segments: [TimelineSegment] = []
        for entry in entries {
            let clampedStart = max(entry.startTime, dayStart)
            let clampedEnd = min(entry.endTime ?? now, dayEnd)
            guard clampedEnd > clampedStart else { continue }
            let offset = CGFloat(clampedStart.timeIntervalSince(dayStart) / 3600) * pointsPerHour
            let height = CGFloat(clampedEnd.timeIntervalSince(clampedStart) / 3600) * pointsPerHour
            segments.append(TimelineSegment(id: entry.id, entry: entry, offset: offset, height: max(3, height)))
        }
        return segments
    }

    @ViewBuilder
    private func segmentView(_ seg: TimelineSegment) -> some View {
        let category = categoryLookup(seg.entry.categoryId)
        let color = category?.color ?? Color.gray
        Button {
            onSelect(seg.entry)
        } label: {
            HStack(spacing: 6) {
                if seg.height > 22 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category?.name ?? "Unknown")
                            .font(.caption).bold()
                            .lineLimit(1)
                        if seg.height > 40 {
                            Text(timeRange(seg.entry))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: seg.height)
            .background(
                LinearGradient(
                    colors: [color, color.opacity(0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(seg.entry.isRunning ? Color.white.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.leading, leftGutter)
        .offset(y: seg.offset)
    }

    private func timeRange(_ entry: TimeEntry) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let end = entry.endTime ?? now
        return "\(f.string(from: entry.startTime))–\(f.string(from: end))"
    }
}
