import SwiftUI
import SwiftData

/// Custom dark sidebar for the Dashboard.
///
/// Replaces the default `NavigationSplitView` sidebar styling with a compact,
/// date-grouped list inspired by modern IDE/chat UIs.
struct MeetingsSidebar: View {
    let meetings: [Meeting]
    @Binding var selectedMeeting: Meeting?
    @Binding var multiSelection: Set<UUID>
    @Binding var searchText: String
    @Binding var dateRange: MeetingDateRange
    @Binding var sortOrder: MeetingSortOrder
    @Binding var selectedTagIDs: Set<UUID>

    let onDelete: (Meeting) -> Void
    let onTag: (Meeting) -> Void
    let onExport: (Meeting) -> Void

    @Environment(\.openWindow) private var openWindow

    private var sections: [(MeetingSection, [Meeting])] {
        let now = Date()
        let grouped = Dictionary(grouping: meetings) { MeetingSection.bucket(for: $0.date, now: now) }
        return MeetingSection.allCases.compactMap { section -> (MeetingSection, [Meeting])? in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            return (section, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            quickActions
            Divider().opacity(0.2)
            meetingList
            Divider().opacity(0.2)
            footer
        }
        .background(DashboardTheme.sidebarBackground)
        .foregroundStyle(.white.opacity(0.9))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text("MeetRecap")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                openWindow(id: "settings")
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search meetings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.95))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DashboardTheme.sidebarSurface)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Quick Actions (filter / sort)

    private var quickActions: some View {
        VStack(spacing: 2) {
            Menu {
                ForEach(MeetingDateRange.allCases) { range in
                    Button {
                        dateRange = range
                    } label: {
                        if range == dateRange {
                            Label(range.rawValue, systemImage: "checkmark")
                        } else {
                            Text(range.rawValue)
                        }
                    }
                }
            } label: {
                sidebarRow(
                    icon: "calendar",
                    title: dateRange == .all ? "All time" : dateRange.rawValue,
                    trailing: "chevron.down"
                )
            }
            .menuStyle(.borderlessButton)

            Menu {
                ForEach(MeetingSortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        if order == sortOrder {
                            Label(order.rawValue, systemImage: "checkmark")
                        } else {
                            Text(order.rawValue)
                        }
                    }
                }
            } label: {
                sidebarRow(
                    icon: "arrow.up.arrow.down",
                    title: sortOrder.rawValue,
                    trailing: "chevron.down"
                )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func sidebarRow(icon: String, title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(.white.opacity(0.6))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            if let trailing = trailing {
                Image(systemName: trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Meeting List

    private var meetingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                if sections.isEmpty {
                    emptyState
                } else {
                    ForEach(sections, id: \.0) { (section, items) in
                        Section {
                            VStack(spacing: 2) {
                                ForEach(items) { meeting in
                                    SidebarMeetingRow(
                                        meeting: meeting,
                                        isSelected: selectedMeeting?.id == meeting.id,
                                        isMultiSelected: multiSelection.contains(meeting.id),
                                        onToggleMultiSelect: { toggleMultiSelection(meeting) }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedMeeting = meeting
                                    }
                                    .contextMenu {
                                        Button { selectedMeeting = meeting } label: {
                                            Label("View Details", systemImage: "doc.text")
                                        }
                                        Button { onTag(meeting) } label: {
                                            Label("Manage Tags…", systemImage: "tag")
                                        }
                                        Button { onExport(meeting) } label: {
                                            Label("Export…", systemImage: "square.and.arrow.up")
                                        }
                                        Divider()
                                        Button(role: .destructive) { onDelete(meeting) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 6)
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(_ section: MeetingSection) -> some View {
        Text(section.rawValue)
            .font(DashboardTheme.sectionHeaderFont)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashboardTheme.sidebarBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "mic.slash")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.3))
            Text("No meetings yet")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Footer (stats)

    private var footer: some View {
        HStack(spacing: 10) {
            footerStat(label: "Meetings", value: "\(meetings.count)")
            Divider().frame(height: 18).opacity(0.2)
            footerStat(label: "Time", value: formatTotalDuration())
            Spacer()
            if !multiSelection.isEmpty {
                Text("\(multiSelection.count) selected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.25))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func formatTotalDuration() -> String {
        let total = meetings.reduce(0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: - Selection

    private func toggleMultiSelection(_ meeting: Meeting) {
        if multiSelection.contains(meeting.id) {
            multiSelection.remove(meeting.id)
        } else {
            multiSelection.insert(meeting.id)
        }
    }
}

// MARK: - Sidebar Meeting Row

struct SidebarMeetingRow: View {
    let meeting: Meeting
    let isSelected: Bool
    let isMultiSelected: Bool
    let onToggleMultiSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 1.0 : 0.92))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(meeting.date, style: .time)
                    Text("·")
                    Text(meeting.formattedDuration)
                    if meeting.segments.count > 0 {
                        Text("·")
                        Text("\(meeting.segments.count) seg")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))

                if !meeting.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(meeting.tags.prefix(3)) { tag in
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 5, height: 5)
                                Text(tag.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        if meeting.tags.count > 3 {
                            Text("+\(meeting.tags.count - 3)")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            // Hover-revealed multi-select check
            if isHovered || isMultiSelected {
                Button(action: onToggleMultiSelect) {
                    Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isMultiSelected ? Color.accentColor : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                    ? DashboardTheme.sidebarSurfaceActive
                    : (isHovered ? DashboardTheme.sidebarHover : Color.clear)
                )
        )
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        if meeting.isSummarized { return DashboardTheme.completeColor }
        if meeting.isTranscribed { return DashboardTheme.processingColor }
        return DashboardTheme.pendingColor
    }
}
