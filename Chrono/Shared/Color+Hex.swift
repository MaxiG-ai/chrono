import SwiftUI

extension Color {
    /// Initialize from a hex string such as "#3B82F6" or "3B82F6".
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexString = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        var int: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&int)
        let r, g, b, a: Double
        switch hexString.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        case 8:
            a = Double((int >> 24) & 0xFF) / 255.0
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0.5; g = 0.5; b = 0.5; a = 1.0
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// Curated palette for quick category color assignment.
enum CategoryPalette {
    static let colors: [String] = [
        "#EF4444", // red
        "#F97316", // orange
        "#F59E0B", // amber
        "#EAB308", // yellow
        "#84CC16", // lime
        "#22C55E", // green
        "#14B8A6", // teal
        "#06B6D4", // cyan
        "#3B82F6", // blue
        "#6366F1", // indigo
        "#8B5CF6", // violet
        "#EC4899", // pink
        "#78716C", // stone
        "#525252"  // neutral
    ]
}
