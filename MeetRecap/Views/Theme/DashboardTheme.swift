import SwiftUI

/// Shared design tokens for the Dashboard window.
enum DashboardTheme {
    // Sidebar background: dark, slightly translucent so macOS vibrancy shows through.
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.08, alpha: 1.0)
            : NSColor(white: 0.11, alpha: 1.0)
    })

    static let sidebarSurface = Color.white.opacity(0.05)
    static let sidebarSurfaceActive = Color.white.opacity(0.10)
    static let sidebarHover = Color.white.opacity(0.03)
    static let sidebarBorder = Color.white.opacity(0.08)

    static let detailBackground = Color(nsColor: .windowBackgroundColor)

    // Typography
    static let sectionHeaderFont = Font.system(size: 10, weight: .semibold).smallCaps()

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.7)

    // Status colors
    static let completeColor = Color.green
    static let pendingColor = Color.orange
    static let processingColor = Color.blue
}

// MARK: - Sort + Filter Enums

enum MeetingSortOrder: String, CaseIterable, Identifiable {
    case dateDescending = "Newest first"
    case dateAscending = "Oldest first"
    case durationDescending = "Longest first"
    case durationAscending = "Shortest first"
    case titleAscending = "Title A → Z"

    var id: String { rawValue }
}

enum MeetingDateRange: String, CaseIterable, Identifiable {
    case all = "All time"
    case today = "Today"
    case thisWeek = "This week"
    case thisMonth = "This month"
    case thisYear = "This year"

    var id: String { rawValue }

    /// Returns the `[start, end)` range for this filter, or nil for "all time".
    var dateRange: (start: Date, end: Date)? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .all:
            return nil
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return (start, end)
        case .thisWeek:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let start = calendar.date(from: components)!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return (start, end)
        case .thisMonth:
            let components = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: components)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        case .thisYear:
            let components = calendar.dateComponents([.year], from: now)
            let start = calendar.date(from: components)!
            let end = calendar.date(byAdding: .year, value: 1, to: start)!
            return (start, end)
        }
    }
}

/// Date bucket used to group the meeting list.
enum MeetingSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case earlier = "Earlier"

    var id: String { rawValue }

    static func bucket(for date: Date, now: Date = Date()) -> MeetingSection {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .thisMonth }
        return .earlier
    }
}
