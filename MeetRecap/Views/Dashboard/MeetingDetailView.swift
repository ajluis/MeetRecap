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

                TranscriptTabView(meeting: meeting, playback: meetingManager.audioPlayback)
                    .tabItem {
                        Label("Transcript", systemImage: "text.quote")
                    }
                    .tag(1)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isEditingTitle {
                    TextField("Meeting title", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
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
                        .font(.title2)
                        .fontWeight(.semibold)
                        .onTapGesture(count: 2) {
                            editedTitle = meeting.title
                            isEditingTitle = true
                        }
                }
                
                Spacer()
                
                statusBadge
            }
            
            HStack(spacing: 16) {
                Label(meeting.date.formatted(date: .long, time: .shortened), systemImage: "calendar")
                
                Label(meeting.formattedDuration, systemImage: "clock")
                
                if !meeting.participants.isEmpty {
                    Label(meeting.participants.joined(separator: ", "), systemImage: "person.2")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    private var statusBadge: some View {
        HStack(spacing: 4) {
            if !meeting.isTranscribed {
                if meetingManager.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text(meetingManager.processingStatus)
                        .font(.caption)
                } else {
                    Image(systemName: "clock")
                    Text("Pending transcription")
                        .font(.caption)
                }
            } else if !meeting.isSummarized {
                if meetingManager.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text(meetingManager.processingStatus)
                        .font(.caption)
                } else {
                    Image(systemName: "text.alignleft")
                    Text("Summary pending")
                        .font(.caption)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Complete")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary)
        .clipShape(Capsule())
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
