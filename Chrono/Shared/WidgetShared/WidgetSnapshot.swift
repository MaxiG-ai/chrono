import Foundation

/// Compact, widget-friendly snapshot of app state. The main app writes this
/// to the shared App Group container whenever state changes; the widget reads
/// it instead of opening SQLite directly. This keeps the widget binary tiny
/// and avoids cross-process SQLite coordination.
public struct WidgetSnapshot: Codable, Equatable {
    public struct CategorySummary: Codable, Equatable {
        public var id: String
        public var name: String
        public var colorHex: String
    }

    public struct RunningEntry: Codable, Equatable {
        public var categoryId: String
        public var categoryName: String
        public var colorHex: String
        public var startDate: Date
    }

    public var running: RunningEntry?
    public var topCategories: [CategorySummary]
    public var lastUsedCategoryId: String?
    public var todaySecondsTracked: Int
    public var updatedAt: Date

    public init(
        running: RunningEntry? = nil,
        topCategories: [CategorySummary] = [],
        lastUsedCategoryId: String? = nil,
        todaySecondsTracked: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.running = running
        self.topCategories = topCategories
        self.lastUsedCategoryId = lastUsedCategoryId
        self.todaySecondsTracked = todaySecondsTracked
        self.updatedAt = updatedAt
    }

    public static let appGroupIdentifier = "group.app.chrono.Chrono"
    public static let userDefaultsKey = "widget.snapshot.v1"

    public static func load() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: userDefaultsKey) else {
            return WidgetSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WidgetSnapshot.self, from: data)) ?? WidgetSnapshot()
    }

    public func save() {
        guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
