import SwiftUI
import SwiftData

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

struct MeetingFilterBar: View {
    @Binding var dateRange: MeetingDateRange
    @Binding var sortOrder: MeetingSortOrder
    @Binding var selectedTagIDs: Set<UUID>

    @Query(sort: \Tag.name) private var allTags: [Tag]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Date", selection: $dateRange) {
                    ForEach(MeetingDateRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Picker("Sort", selection: $sortOrder) {
                    ForEach(MeetingSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()

                if !selectedTagIDs.isEmpty {
                    Button("Clear tags") {
                        selectedTagIDs.removeAll()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allTags) { tag in
                            TagChip(
                                tag: tag,
                                isSelected: selectedTagIDs.contains(tag.id)
                            ) {
                                if selectedTagIDs.contains(tag.id) {
                                    selectedTagIDs.remove(tag.id)
                                } else {
                                    selectedTagIDs.insert(tag.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.3))
    }
}

struct TagChip: View {
    let tag: Tag
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tag.color)
                    .frame(width: 8, height: 8)
                Text(tag.name)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isSelected ? tag.color.opacity(0.25) : Color.secondary.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? tag.color : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
