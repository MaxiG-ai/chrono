import UIKit

/// Lightweight haptic helper. We keep one generator alive and prepare before use
/// to minimize latency on the first tap after launch.
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        impact.prepare()
        light.prepare()
        selection.prepare()
        notification.prepare()
    }

    static func start() {
        impact.impactOccurred(intensity: 0.8)
        impact.prepare()
    }

    static func stop() {
        light.impactOccurred(intensity: 0.7)
        light.prepare()
    }

    static func select() {
        selection.selectionChanged()
        selection.prepare()
    }

    static func success() {
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    static func warning() {
        notification.notificationOccurred(.warning)
        notification.prepare()
    }
}
