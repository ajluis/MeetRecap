import SwiftUI
import AVKit

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @ObservedObject var meetingManager: MeetingManager
    
    @State private var selectedTab = 0
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var showExportMenu = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            // Tab View
            TabView(selection: $selectedTab) {
                SummaryTabView(meeting: meeting, meetingManager: meetingManager)
                    .tabItem {
                        Label("Summary", systemImage: "text.alignleft")
                    }
                    .tag(0)

                TranscriptTabView(
                    meeting: meeting,
                    playback: meetingManager.audioPlayback,
                    meetingManager: meetingManager
                )
                    .tabItem {
                        Label("Transcript", systemImage: "text.quote")
                    }
                    .tag(1)

                AnalyticsTabView(meeting: meeting)
                    .tabItem {
                        Label("Analytics", systemImage: "chart.bar")
                    }
                    .tag(2)
            }
            .tabViewStyle(.automatic)

            // Persistent audio player bar at the bottom — only shown when the
            // meeting has a resolvable audio file.
            if meeting.audioFileURL != nil {
                Divider()
                AudioPlayerBarView(playback: meetingManager.audioPlayback)
            }
        }
        .onAppear {
            loadAudioIfAvailable()
        }
        .onChange(of: meeting.id) { _, _ in
            loadAudioIfAvailable()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Regenerate summary button
                if meeting.isTranscribed {
                    Button {
                        Task {
                            await meetingManager.summarizeMeeting(meeting)
                        }
                    } label: {
                        Label("Regenerate Summary", systemImage: "arrow.clockwise")
                    }
                    .help("Regenerate AI summary")
                }
                
                // Export button
                Menu {
                    Button("Export as Markdown") {
                        exportMeeting(format: .markdown)
                    }
                    Button("Export as Plain Text") {
                        exportMeeting(format: .plainText)
                    }
                    Button("Export as PDF") {
                        exportMeeting(format: .pdf)
                    }
                    Divider()
                    Button("Copy Transcript") {
                        copyTranscript()
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
    
    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if isEditingTitle {
                    TextField("Meeting title", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 22, weight: .semibold))
                        .onSubmit {
                            meeting.title = editedTitle
                            meeting.updatedAt = Date()
                            isEditingTitle = false
                        }
                        .onExitCommand {
                            isEditingTitle = false
                        }
                } else {
                    Text(meeting.title)
                        .font(.system(size: 22, weight: .semibold))
                        .onTapGesture(count: 2) {
                            editedTitle = meeting.title
                            isEditingTitle = true
                        }
                        .help("Double-click to rename")
                }

                Spacer()

                statusBadge
            }

            HStack(spacing: 14) {
                metadataItem(icon: "calendar", text: meeting.date.formatted(date: .abbreviated, time: .shortened))
                metadataItem(icon: "clock", text: meeting.formattedDuration)
                if !meeting.participants.isEmpty {
                    metadataItem(icon: "person.2", text: meeting.participants.joined(separator: ", "))
                }
                if !meeting.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(meeting.tags.prefix(4)) { tag in
                            HStack(spacing: 3) {
                                Circle().fill(tag.color).frame(width: 6, height: 6)
                                Text(tag.name).font(.caption2)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tag.color.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func metadataItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.caption)
        }
    }
    
    private var statusBadge: some View {
        HStack(spacing: 5) {
            if meetingManager.isProcessing && (!meeting.isTranscribed || !meeting.isSummarized) {
                ProgressView().controlSize(.small)
                Text(meetingManager.processingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if meeting.isSummarized {
                Circle().fill(DashboardTheme.completeColor).frame(width: 6, height: 6)
                Text("Complete").font(.caption).foregroundStyle(.secondary)
            } else if meeting.isTranscribed {
                Circle().fill(DashboardTheme.processingColor).frame(width: 6, height: 6)
                Text("Summary pending").font(.caption).foregroundStyle(.secondary)
            } else {
                Circle().fill(DashboardTheme.pendingColor).frame(width: 6, height: 6)
                Text("Transcription pending").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.secondary.opacity(0.12))
        )
    }
    
    // MARK: - Export
    
    private func exportMeeting(format: ExportFormat) {
        let data = meetingManager.exportMeeting(meeting, format: format)
        
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "\(meeting.title).\(format.fileExtension)"
        savePanel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? data.write(to: url)
            }
        }
    }
    
    private func copyTranscript() {
        let segments = meeting.segments
            .sorted { $0.orderIndex < $1.orderIndex }
        
        var text = ""
        for segment in segments {
            let timestamp = formatTimestamp(segment.startTime)
            if let speaker = segment.speaker {
                text += "[\(timestamp)] \(speaker): \(segment.text)\n"
            } else {
                text += "[\(timestamp)] \(segment.text)\n"
            }
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func formatTimestamp(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Playback Loading

    private func loadAudioIfAvailable() {
        if let url = meeting.audioFileURL {
            // Only reload if the URL actually changed — avoids restarting playback
            // when the detail view refreshes for unrelated reasons.
            if meetingManager.audioPlayback.currentURL != url {
                meetingManager.audioPlayback.load(url: url)
            }
        } else {
            meetingManager.audioPlayback.stop()
        }
    }
}
