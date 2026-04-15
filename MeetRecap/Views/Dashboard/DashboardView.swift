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
    @State private var showSemanticSearch = false
    @State private var pendingSeekSegmentID: UUID?
    @State private var pendingSeekTime: TimeInterval?

    private var filteredMeetings: [Meeting] {
        meetings.filter { meeting in
            if let range = dateRange.dateRange {
                guard meeting.date >= range.start && meeting.date < range.end else { return false }
            }
            if !selectedTagIDs.isEmpty {
                let meetingTagIDs = Set(meeting.tags.map(\.id))
                guard selectedTagIDs.isSubset(of: meetingTagIDs) else { return false }
            }
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
        HStack(spacing: 0) {
            MeetingsSidebar(
                meetings: filteredMeetings,
                selectedMeeting: $selectedMeeting,
                multiSelection: $multiSelection,
                searchText: $searchText,
                dateRange: $dateRange,
                sortOrder: $sortOrder,
                selectedTagIDs: $selectedTagIDs,
                onDelete: { meeting in
                    pendingDelete = [meeting]
                    showDeleteConfirmation = true
                },
                onTag: { meeting in
                    tagMenuMeeting = meeting
                },
                onExport: { meeting in
                    meetingToExport = meeting
                    showExportPicker = true
                },
                onSemanticSearch: {
                    showSemanticSearch = true
                }
            )
            .frame(width: 260)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(DashboardTheme.sidebarBorder)
                    .frame(width: 1)
            }

            Group {
                if let meeting = selectedMeeting {
                    MeetingDetailView(meeting: meeting, meetingManager: meetingManager)
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DashboardTheme.detailBackground)
        }
        .frame(minWidth: 860, minHeight: 540)
        .toolbar {
            if !multiSelection.isEmpty {
                ToolbarItem {
                    Button {
                        let selected = meetings.filter { multiSelection.contains($0.id) }
                        pendingDelete = selected
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete \(multiSelection.count)", systemImage: "trash")
                    }
                }
            }
        }
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
        .fileExporter(
            isPresented: $showExportPicker,
            document: meetingToExport.map { MeetingDocument(meeting: $0) } ?? MeetingDocument(meeting: nil),
            contentType: .plainText,
            defaultFilename: meetingToExport?.title ?? "meeting"
        ) { _ in
            meetingToExport = nil
        }
        .sheet(item: $tagMenuMeeting) { meeting in
            TagManagementView(meeting: meeting, meetingManager: meetingManager)
        }
        .sheet(isPresented: $showSemanticSearch) {
            SemanticSearchView(meetingManager: meetingManager) { result in
                if let match = meetings.first(where: { $0.id == result.meetingID }) {
                    selectedMeeting = match
                    pendingSeekSegmentID = result.segmentID
                    pendingSeekTime = result.startTime
                    // Seek playback to the matched segment if already loaded.
                    if meetingManager.audioPlayback.currentURL != nil {
                        meetingManager.audioPlayback.seekAndPlay(to: result.startTime)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)

            Text("Select a meeting")
                .font(.title3)
                .fontWeight(.medium)

            Text("Pick a meeting from the sidebar or start a new\nrecording from the menu bar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Meeting Row helper (kept around for exports/menus if needed)

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusIcon
            }
            HStack(spacing: 8) {
                Text(meeting.date, style: .date)
                Text("·")
                Text(meeting.formattedDuration)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: some View {
        Group {
            if meeting.isSummarized {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if meeting.isTranscribed {
                Image(systemName: "doc.text").foregroundStyle(.blue)
            } else {
                Image(systemName: "clock").foregroundStyle(.orange)
            }
        }
    }
}

// Make Meeting Identifiable by ID for sheet(item:) binding
extension Meeting: Identifiable {}

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
