import Foundation
import ActivityKit

/// Shared attributes used by the Live Activity widget.
struct ChronoActivityAttributes: ActivityAttributes {
    /// Fixed for the activity's lifetime — category name + color.
    let categoryName: String
    let colorHex: String
    let startDate: Date

    public struct ContentState: Codable, Hashable {
        /// Kept small so push updates are frequent-friendly. We only ship the
        /// start date and re-derive elapsed time in the widget via
        /// `Text(timerInterval:)`.
        public var isRunning: Bool
    }
}
