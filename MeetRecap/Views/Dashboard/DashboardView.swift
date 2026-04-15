import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct DashboardView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var meetingManager: MeetingManager

    @State private var selectedMeeting: Meeting?
    @State private var multiSelection: Set<UUID> = []
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var pendingDelete: [Meeting] = []
    @State private var showExportPicker = false
    @State private var meetingToExport: Meeting?
    @State private var tagMenuMeeting: Meeting?

    @State private var dateRange: MeetingDateRange = .all
    @State private var sortOrder: MeetingSortOrder = .dateDescending
    @State private var selectedTagIDs: Set<UUID> = []

    private var filteredMeetings: [Meeting] {
        meetings.filter { meeting in
            // Date range
            if let range = dateRange.dateRange {
                guard meeting.date >= range.start && meeting.date < range.end else { return false }
            }

            // Tags (must contain ALL selected tags)
            if !selectedTagIDs.isEmpty {
                let meetingTagIDs = Set(meeting.tags.map(\.id))
                guard selectedTagIDs.isSubset(of: meetingTagIDs) else { return false }
            }

            // Search
            if !searchText.isEmpty {
                let matchesTitle = meeting.title.localizedCaseInsensitiveContains(searchText)
                let matchesSummary = meeting.summary?.localizedCaseInsensitiveContains(searchText) ?? false
                let matchesSegments = meeting.segments.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
                if !(matchesTitle || matchesSummary || matchesSegments) { return false }
            }

            return true
        }
        .sorted(by: sorter)
    }

    private var sorter: (Meeting, Meeting) -> Bool {
        switch sortOrder {
        case .dateDescending: return { $0.date > $1.date }
        case .dateAscending: return { $0.date < $1.date }
        case .durationDescending: return { $0.duration > $1.duration }
        case .durationAscending: return { $0.duration < $1.duration }
        case .titleAscending: return { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationSplitView {
            meetingListSidebar
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(meeting: meeting, meetingManager: meetingManager)
            } else {
                emptyStateView
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .confirmationDialog("Delete meeting?", isPresented: $showDeleteConfirmation) {
            Button("Delete \(pendingDelete.count) meeting\(pendingDelete.count == 1 ? "" : "s")", role: .destructive) {
                meetingManager.deleteMeetings(pendingDelete)
                if let selected = selectedMeeting, pendingDelete.contains(where: { $0.id == selected.id }) {
                    selectedMeeting = nil
                }
                multiSelection.removeAll()
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = []
            }
        } message: {
            Text("This will permanently delete the selected meeting\(pendingDelete.count == 1 ? "" : "s") and their recordings.")
        }
    }

    // MARK: - Sidebar

    private var meetingListSidebar: some View {
        VStack(spacing: 0) {
            MeetingStatsView(meetings: meetings)

            MeetingFilterBar(
                dateRange: $dateRange,
                sortOrder: $sortOrder,
                selectedTagIDs: $selectedTagIDs
            )

            meetingList
        }
        .searchable(text: $searchText, prompt: "Search meetings...")
        .navigationTitle("Meetings")
        .toolbar {
            if !multiSelection.isEmpty {
                ToolbarItemGroup {
                    Button {
                        let selected = meetings.filter { multiSelection.contains($0.id) }
                        pendingDelete = selected
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete selected meetings")

                    Text("\(multiSelection.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ToolbarItem {
                    Text("\(filteredMeetings.count) of \(meetings.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileExporter(
            isPresented: $showExportPicker,
            document: meetingToExport.map { MeetingDocument(meeting: $0) } ?? MeetingDocument(meeting: nil),
            contentType: .plainText,
            defaultFilename: meetingToExport?.title ?? "meeting"
        ) { _ in
            meetingToExport = nil
        }
    }

    private var meetingList: some View {
        List(selection: $selectedMeeting) {
            if filteredMeetings.isEmpty {
                Section {
                    Text(meetings.isEmpty ? "No meetings yet" : "No matches")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(filteredMeetings) { meeting in
                    meetingRow(for: meeting)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func meetingRow(for meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                toggleSelection(meeting)
            } label: {
                Image(systemName: multiSelection.contains(meeting.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(multiSelection.contains(meeting.id) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)

            MeetingRowView(meeting: meeting)
        }
        .tag(meeting)
        .contextMenu {
            Button {
                selectedMeeting = meeting
            } label: {
                Label("View Details", systemImage: "doc.text")
            }

            Button {
                tagMenuMeeting = meeting
            } label: {
                Label("Manage Tags...", systemImage: "tag")
            }

            Button {
                meetingToExport = meeting
                showExportPicker = true
            } label: {
                Label("Export...", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                pendingDelete = [meeting]
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .popover(
            isPresented: Binding(
                get: { tagMenuMeeting?.id == meeting.id },
                set: { if !$0 { tagMenuMeeting = nil } }
            )
        ) {
            TagManagementView(meeting: meeting, meetingManager: meetingManager)
        }
    }

    private func toggleSelection(_ meeting: Meeting) {
        if multiSelection.contains(meeting.id) {
            multiSelection.remove(meeting.id)
        } else {
            multiSelection.insert(meeting.id)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Meetings Yet")
                .font(.title2)
                .fontWeight(.medium)

            Text("Click the MeetRecap icon in the menu bar\nand start a recording to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Meeting Row View

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if !meeting.isTranscribed {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                        .help("Transcription pending")
                } else if !meeting.isSummarized {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.blue)
                        .help("Summary pending")
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Complete")
                }
            }

            HStack(spacing: 8) {
                Text(meeting.date, style: .date)
                Text("·")
                Text(meeting.formattedDuration)

                if meeting.segments.count > 0 {
                    Text("·")
                    Text("\(meeting.segments.count) segments")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !meeting.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(meeting.tags.prefix(4)) { tag in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 6, height: 6)
                            Text(tag.name)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tag.color.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    if meeting.tags.count > 4 {
                        Text("+\(meeting.tags.count - 4)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let summary = meeting.summary {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - File Document for Export

struct MeetingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText, .pdf, UTType("net.daringfireball.markdown")!] }

    let textContent: String

    init(meeting: Meeting?) {
        if let meeting = meeting {
            let segments = meeting.segments.sorted { $0.orderIndex < $1.orderIndex }
            var text = "\(meeting.title)\n"
            text += "\(meeting.date.formatted(date: .long, time: .shortened))\n"
            text += "\(meeting.formattedDuration)\n\n"

            if let summary = meeting.summary {
                text += "SUMMARY\n\(summary)\n\n"
            }

            if !meeting.actionItems.isEmpty {
                text += "ACTION ITEMS\n"
                for item in meeting.actionItems {
                    text += "- \(item)\n"
                }
                text += "\n"
            }

            text += "TRANSCRIPT\n"
            for segment in segments {
                let mins = Int(segment.startTime) / 60
                let secs = Int(segment.startTime) % 60
                let ts = String(format: "%d:%02d", mins, secs)
                if let speaker = segment.speaker {
                    text += "[\(ts)] \(speaker): \(segment.text)\n"
                } else {
                    text += "[\(ts)] \(segment.text)\n"
                }
            }
            self.textContent = text
        } else {
            self.textContent = ""
        }
    }

    init(configuration: ReadConfiguration) throws {
        self.textContent = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: textContent.data(using: .utf8) ?? Data())
    }
}
