import Foundation

extension Date {
    /// ISO 8601 with fractional seconds for storage.
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var iso8601: String {
        Self.iso8601Formatter.string(from: self)
    }

    static func fromISO8601(_ string: String) -> Date? {
        if let d = iso8601Formatter.date(from: string) { return d }
        // Fallback without fractional seconds.
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    func startOfDay(calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: self)
    }

    func endOfDay(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay(calendar: calendar)) ?? self
    }

    func startOfWeek(calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return calendar.date(from: components) ?? self
    }

    func startOfMonth(calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: self)
        return calendar.date(from: components) ?? self
    }

    func adding(days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: self) ?? self
    }
}

enum DurationFormatter {
    /// Formats seconds as "1h 23m" or "45m" or "12s".
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            if m > 0 { return "\(h)h \(m)m" }
            return "\(h)h"
        }
        if m > 0 {
            return "\(m)m"
        }
        return "\(s)s"
    }

    /// Formats seconds as H:MM:SS or MM:SS for the running timer.
    static func timer(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Formats an hour count like "7.5h".
    static func hours(_ seconds: TimeInterval) -> String {
        let h = seconds / 3600.0
        if h >= 10 {
            return String(format: "%.0fh", h)
        }
        return String(format: "%.1fh", h)
    }
}
