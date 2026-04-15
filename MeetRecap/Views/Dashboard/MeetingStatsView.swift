import SwiftUI

/// Compact stats strip shown above the meeting list.
struct MeetingStatsView: View {
    let meetings: [Meeting]

    var body: some View {
        HStack(spacing: 0) {
            statCell(title: "Total", value: "\(meetings.count)")
            Divider().frame(height: 28)
            statCell(title: "Duration", value: formatTotalDuration())
            Divider().frame(height: 28)
            statCell(title: "This week", value: "\(countThisWeek())")
            Divider().frame(height: 28)
            statCell(title: "This month", value: "\(countThisMonth())")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25))
    }

    private func statCell(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func formatTotalDuration() -> String {
        let total = meetings.reduce(0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func countThisWeek() -> Int {
        let range = MeetingDateRange.thisWeek.dateRange
        return meetings.count(where: { inRange($0, range: range) })
    }

    private func countThisMonth() -> Int {
        let range = MeetingDateRange.thisMonth.dateRange
        return meetings.count(where: { inRange($0, range: range) })
    }

    private func inRange(_ meeting: Meeting, range: (start: Date, end: Date)?) -> Bool {
        guard let range = range else { return true }
        return meeting.date >= range.start && meeting.date < range.end
    }
}
