import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity presentation. Lives on the Lock Screen and Dynamic Island
/// whenever a timer is running. `Text(timerInterval:)` ticks the duration
/// locally — we don't need frequent content-state pushes.
struct ChronoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChronoActivityAttributes.self) { context in
            // Lock Screen / Notification Center presentation.
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(Color(hex: context.attributes.colorHex).opacity(0.08))
                .activitySystemActionForegroundColor(Color(hex: context.attributes.colorHex))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: context.attributes.colorHex)).frame(width: 10, height: 10)
                        Text(context.attributes.categoryName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startDate, style: .timer)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: context.attributes.colorHex))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Tap the app to stop or switch timers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Circle().fill(Color(hex: context.attributes.colorHex)).frame(width: 8, height: 8)
            } compactTrailing: {
                Text(context.attributes.startDate, style: .timer)
                    .font(.caption)
                    .monospacedDigit()
                    .frame(maxWidth: 42)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(Color(hex: context.attributes.colorHex))
            }
            .widgetURL(URL(string: "chrono://track"))
            .keylineTint(Color(hex: context.attributes.colorHex))
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<ChronoActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: context.attributes.colorHex))
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.attributes.categoryName)
                    .font(.headline)
                    .lineLimit(1)
                Text("Tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(context.attributes.startDate, style: .timer)
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color(hex: context.attributes.colorHex))
        }
        .padding()
    }
}
