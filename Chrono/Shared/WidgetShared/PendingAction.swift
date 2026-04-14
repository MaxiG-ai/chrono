import Foundation

/// Cross-process mailbox between the widget extension and the main app.
///
/// The widget process should not write to the SQLite database — the app may
/// be writing at the same time and cross-process SQLite locking is brittle.
/// Instead, widget intents enqueue a record here, and the app drains and
/// replays these records the next time it becomes active.
public enum PendingAction {
    private static let suiteName = WidgetSnapshot.appGroupIdentifier
    private static let key = "widget.pendingActions.v1"

    public struct Record: Codable {
        public let kind: String   // "start" or "stop"
        public let categoryId: String?
        public let at: Date

        public init(kind: String, categoryId: String?, at: Date) {
            self.kind = kind
            self.categoryId = categoryId
            self.at = at
        }
    }

    public static func enqueueStart(categoryId: String, at: Date) {
        append(Record(kind: "start", categoryId: categoryId, at: at))
    }

    public static func enqueueStop(at: Date) {
        append(Record(kind: "stop", categoryId: nil, at: at))
    }

    public static func drainAll() -> [Record] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        defaults.removeObject(forKey: key)
        return records
    }

    private static func append(_ record: Record) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        var current: [Record] = []
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            current = decoded
        }
        current.append(record)
        if let encoded = try? JSONEncoder().encode(current) {
            defaults.set(encoded, forKey: key)
        }
    }
}
