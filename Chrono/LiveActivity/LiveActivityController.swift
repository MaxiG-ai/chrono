import Foundation
import ActivityKit

/// Thin wrapper around ActivityKit to keep the Live Activity in sync with the
/// running timer. Starts/updates/ends activities in response to timer events.
@MainActor
enum LiveActivityController {
    private static var currentActivityID: String?

    static func syncWith(runningEntry: TimeEntry?, category: TimeCategory?) {
        // No-op on devices where Live Activities are unsupported or disabled.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let entry = runningEntry, let category {
            if let id = currentActivityID, let existing = Activity<ChronoActivityAttributes>.activities.first(where: { $0.id == id }) {
                // Already tracking — refresh the content state.
                Task {
                    await existing.update(using: .init(isRunning: true))
                }
            } else {
                startActivity(entry: entry, category: category)
            }
        } else {
            stopActivity()
        }
    }

    private static func startActivity(entry: TimeEntry, category: TimeCategory) {
        let attributes = ChronoActivityAttributes(
            categoryName: category.name,
            colorHex: category.colorHex,
            startDate: entry.startTime
        )
        let content = ActivityContent(state: ChronoActivityAttributes.ContentState(isRunning: true), staleDate: nil)
        do {
            let activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            currentActivityID = activity.id
        } catch {
            // Live Activity failure is non-fatal; the running banner in-app is authoritative.
        }
    }

    private static func stopActivity() {
        Task {
            for activity in Activity<ChronoActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            currentActivityID = nil
        }
    }
}
