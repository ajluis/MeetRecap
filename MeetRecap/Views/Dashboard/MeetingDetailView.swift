import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Redesigned unified detail view.
///
/// Layout:
///   [ Hero header — title, date, duration, status ]
///   [ Summary card (always visible at top) ]
///   [ Split: Transcript ←→ Chat (equal columns) ]
///   [ Audio player bar (if audio available) ]
///
/// Analytics are tucked into a trailing inspector panel that toggles in.
struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var appSettings: AppSettingsStore

    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var showAnalytics = false
    @State private var showChatOnMobile = false  // kept for split responsiveness

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard

                    HSplit(showsTrailing: showAnalytics) {
                        transcriptPanel
                            .frame(maxWidth: .infinity, minHeight: 420, alignment: .top)

                        chatPanel
                            .frame(maxWidth: .infinity, minHeight: 420, alignment: .top)
                    } trailing: {
                        analyticsPanel
                            .frame(width: 300, alignment: .top)
                    }
                }
                .padding(22)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.04),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            if meeting.audioFileURL != nil {
                Divider().opacity(0.4)
                AudioPlayerBarView(playback: meetingManager.audioPlayback)
            }
        }
        .onAppear { loadAudioIfAvailable() }
        .onChange(of: meeting.id) { _, _ in loadAudioIfAvailable() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if meeting.isTranscribed {
                    Button {
                        Task { await meetingManager.summarizeMeeting(meeting) }
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .help("Regenerate AI summary")
                }

                Toggle(isOn: $showAnalytics) {
                    Label("Analytics", systemImage: "chart.bar.xaxis")
                }
                .toggleStyle(.button)

                Menu {
                    Button("Export as Markdown") { exportMeeting(format: .markdown) }
                    Button("Export as Plain Text") { exportMeeting(format: .plainText) }
                    Button("Export as PDF") { exportMeeting(format: .pdf) }
                    Divider()
                    Button("Copy Transcript") { copyTranscript() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if isEditingTitle {
                    TextField("Meeting title", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .onSubmit {
                            meeting.title = editedTitle
                            meeting.updatedAt = Date()
                            isEditingTitle = false
                        }
                        .onExitCommand { isEditingTitle = false }
                } else {
                    Text(meeting.title)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .onTapGesture(count: 2) {
                            editedTitle = meeting.title
                            isEditingTitle = true
                        }
                        .help("Double-click to rename")
                }

                Spacer()
                statusBadge
            }

            HStack(spacing: 18) {
                metadataItem(icon: "calendar", text: meeting.date.formatted(date: .abbreviated, time: .shortened))
                metadataItem(icon: "clock", text: meeting.formattedDuration)
                if !meeting.participants.isEmpty {
                    metadataItem(icon: "person.2", text: meeting.participants.joined(separator: ", "))
                }
                if !meeting.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(meeting.tags.prefix(4)) { tag in
                            HStack(spacing: 3) {
                                Circle().fill(tag.color).frame(width: 6, height: 6)
                                Text(tag.name).font(.caption2)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(tag.color.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private func metadataItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.caption)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if meetingManager.isProcessing && (!meeting.isTranscribed || !meeting.isSummarized) {
                ProgressView().controlSize(.small)
                Text(meetingManager.processingStatus).font(.caption).foregroundStyle(.secondary)
            } else if meeting.isSummarized {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Complete").font(.caption).foregroundStyle(.secondary)
            } else if meeting.isTranscribed {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("Summary pending").font(.caption).foregroundStyle(.secondary)
            } else {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text("Transcription pending").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassChip(cornerRadius: 10)
        .glassStroke(cornerRadius: 10)
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(icon: "sparkles", title: "Summary")

            if let summary = meeting.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if meetingManager.isProcessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating summary…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                Text("No summary yet. Transcription and summary run automatically after a recording.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            if !meeting.actionItems.isEmpty {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(icon: "checklist", title: "Action items")
                    ForEach(meeting.actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                            Text(item)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if !meeting.keyTopics.isEmpty {
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(icon: "tag", title: "Key topics")
                    FlowChips(items: meeting.keyTopics)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .glassStroke()
    }

    // MARK: - Transcript panel

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(icon: "text.alignleft", title: "Transcript")

            TranscriptTabView(
                meeting: meeting,
                playback: meetingManager.audioPlayback,
                meetingManager: meetingManager
            )
            .frame(minHeight: 360)
        }
        .padding(14)
        .glassCard()
        .glassStroke()
    }

    // MARK: - Chat panel

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(icon: "bubble.left.and.text.bubble.right", title: "Chat with this meeting")

            ChatTabView(
                meeting: meeting,
                meetingManager: meetingManager,
                appSettings: appSettings
            )
            .frame(minHeight: 360)
        }
        .padding(14)
        .glassCard()
        .glassStroke()
    }

    // MARK: - Analytics panel

    private var analyticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(icon: "chart.bar.xaxis", title: "Analytics")

            AnalyticsTabView(meeting: meeting)
                .frame(minHeight: 360)
        }
        .padding(14)
        .glassCard()
        .glassStroke()
    }

    // MARK: - Export / clipboard

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
        let segments = meeting.segments.sorted { $0.orderIndex < $1.orderIndex }
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

    private func loadAudioIfAvailable() {
        if let url = meeting.audioFileURL {
            if meetingManager.audioPlayback.currentURL != url {
                meetingManager.audioPlayback.load(url: url)
            }
        } else {
            meetingManager.audioPlayback.stop()
        }
    }
}

// MARK: - Helpers

struct SectionLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title).font(GlassStyle.sectionTitle)
        }
        .foregroundStyle(.secondary)
    }
}

/// Very simple horizontal split: two equal primary columns with an optional
/// fixed-width trailing inspector that slides in when `showsTrailing` is true.
struct HSplit<Primary: View, Trailing: View>: View {
    let showsTrailing: Bool
    @ViewBuilder var primary: Primary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            primary
            if showsTrailing {
                trailing
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: showsTrailing)
    }
}

/// Flowing chip group for key topics.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90, maximum: 220), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.14))
                    )
                    .overlay(
                        Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
