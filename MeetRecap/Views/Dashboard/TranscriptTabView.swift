import SwiftUI

struct TranscriptTabView: View {
    let meeting: Meeting
    @ObservedObject var playback: AudioPlaybackService
    @ObservedObject var meetingManager: MeetingManager

    @State private var searchText = ""
    @State private var manualHighlightID: UUID?
    @State private var isEditingSpeaker: UUID?
    @State private var rememberVoice: Bool = true

    @Environment(\.modelContext) private var modelContext

    private var sortedSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.orderIndex < $1.orderIndex }
    }

    private var filteredSegments: [TranscriptSegment] {
        if searchText.isEmpty {
            return sortedSegments
        }
        return sortedSegments.filter { segment in
            segment.text.localizedCaseInsensitiveContains(searchText) ||
            (segment.speaker?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// The segment that should be highlighted based on playback position.
    private var activeSegmentID: UUID? {
        let time = playback.currentTime
        guard playback.duration > 0, playback.currentURL != nil else { return nil }
        return sortedSegments.first(where: { time >= $0.startTime && time < $0.endTime })?.id
    }

    private var highlightedSegmentID: UUID? {
        manualHighlightID ?? activeSegmentID
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if sortedSegments.isEmpty {
                emptyView
            } else {
                transcriptList
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search transcript...", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            if !searchText.isEmpty {
                Text("\(filteredSegments.count) results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(isOn: $rememberVoice) {
                Label("Remember voice", systemImage: "person.wave.2")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(rememberVoice
                  ? "Renaming a speaker will save a voice profile for future auto-labeling"
                  : "Renaming a speaker will only affect this meeting")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredSegments) { segment in
                    segmentRow(for: segment)
                        .id(segment.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            manualHighlightID = segment.id
                            playback.seekAndPlay(to: segment.startTime)
                        }
                }
            }
            .listStyle(.plain)
            .onChange(of: activeSegmentID) { _, newID in
                if let newID = newID, manualHighlightID != newID {
                    manualHighlightID = nil
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentRow(for segment: TranscriptSegment) -> some View {
        TranscriptSegmentRow(
            segment: segment,
            searchText: searchText,
            isHighlighted: highlightedSegmentID == segment.id,
            isEditingSpeaker: isEditingSpeaker == segment.id,
            onSpeakerEditBegin: { isEditingSpeaker = segment.id },
            onSpeakerEditEnd: { newName in
                renameSpeaker(oldName: segment.speaker, newName: newName)
                isEditingSpeaker = nil
            }
        )
    }

    // MARK: - Speaker Renaming

    private func renameSpeaker(oldName: String?, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, oldName != trimmed, let oldName = oldName else { return }

        if rememberVoice {
            // Save a voice profile so this speaker is auto-labeled in future meetings.
            meetingManager.rememberSpeaker(rawLabel: oldName, as: trimmed, on: meeting)
        } else {
            // Just rename in this meeting.
            for segment in meeting.segments where segment.speaker == oldName {
                segment.speaker = trimmed
            }
            meeting.updatedAt = Date()
            try? modelContext.save()
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 12) {
            if !searchText.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No matches found")
                    .font(.headline)
                Text("Try a different search term")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "text.quote")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No Transcript")
                    .font(.headline)
                Text("Transcription hasn't been generated yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transcript Segment Row

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let searchText: String
    let isHighlighted: Bool
    let isEditingSpeaker: Bool
    let onSpeakerEditBegin: () -> Void
    let onSpeakerEditEnd: (String) -> Void

    @State private var editedSpeakerName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timestamp + speaker label
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatTimestamp(segment.startTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                speakerLabel
            }
            .frame(width: 82, alignment: .trailing)

            // Divider
            RoundedRectangle(cornerRadius: 1)
                .fill(isHighlighted ? Color.accentColor : Color.secondary.opacity(0.2))
                .frame(width: 2)

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                highlightedText(segment.text, search: searchText)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if segment.confidence < 0.8 {
                    Text("Low confidence")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Speaker Label (inline editable)

    @ViewBuilder
    private var speakerLabel: some View {
        if let speaker = segment.speaker {
            if isEditingSpeaker {
                TextField(speaker, text: $editedSpeakerName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)
                    .frame(maxWidth: 80)
                    .onAppear { editedSpeakerName = speaker }
                    .onSubmit { onSpeakerEditEnd(editedSpeakerName) }
                    .onExitCommand { onSpeakerEditEnd(speaker) }
            } else {
                Text(speaker)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(speakerColor(speaker))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        onSpeakerEditBegin()
                    }
                    .help("Double-click to rename")
            }
        }
    }

    // MARK: - Helpers

    private func formatTimestamp(_ timeInterval: TimeInterval) -> String {
        let hours = Int(timeInterval) / 3600
        let minutes = (Int(timeInterval) % 3600) / 60
        let seconds = Int(timeInterval) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func speakerColor(_ speaker: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        let hash = abs(speaker.hashValue)
        return colors[hash % colors.count]
    }

    @ViewBuilder
    private func highlightedText(_ text: String, search: String) -> some View {
        if search.isEmpty {
            Text(text)
        } else {
            if let range = text.range(of: search, options: .caseInsensitive) {
                let before = String(text[..<range.lowerBound])
                let match = String(text[range])
                let after = String(text[range.upperBound...])

                (
                    Text(before) +
                    Text(match).bold().foregroundStyle(.yellow) +
                    Text(after)
                )
            } else {
                Text(text)
            }
        }
    }
}
