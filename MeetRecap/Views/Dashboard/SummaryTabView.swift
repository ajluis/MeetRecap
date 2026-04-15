import SwiftUI

struct SummaryTabView: View {
    let meeting: Meeting
    @ObservedObject var meetingManager: MeetingManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if meeting.isSummarized, let summary = meeting.summary {
                    // Summary section
                    summarySection(summary)
                    
                    // Action items
                    if !meeting.actionItems.isEmpty {
                        actionItemsSection(meeting.actionItems)
                    }
                    
                    // Key topics — use the LLM-provided list (not a heuristic).
                    if !meeting.keyTopics.isEmpty {
                        keyTopicsSection(meeting.keyTopics)
                    }
                    
                } else if meetingManager.isProcessing {
                    loadingView
                } else if !meeting.isTranscribed {
                    notTranscribedView
                } else {
                    noSummaryView
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    // MARK: - Summary Section
    
    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Summary", systemImage: "text.alignleft")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            
            Text(summary)
                .font(.body)
                .textSelection(.enabled)
        }
    }
    
    // MARK: - Action Items
    
    private func actionItemsSection(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Action Items", systemImage: "checkmark.circle")
                .font(.headline)
                .foregroundStyle(.orange)
            
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ActionItemRow(text: item, index: index + 1)
                }
            }
        }
    }
    
    // MARK: - Key Topics
    
    private func keyTopicsSection(_ topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Key Topics", systemImage: "tag")
                .font(.headline)
                .foregroundStyle(.blue)
            
            FlowLayout(spacing: 8) {
                ForEach(topics, id: \.self) { topic in
                    Text(topic)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    // MARK: - States
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(meetingManager.processingStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
    
    private var notTranscribedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Transcription Pending")
                .font(.headline)
            Text("This meeting hasn't been transcribed yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button("Transcribe Now") {
                Task {
                    await meetingManager.transcribeMeeting(meeting)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
    
    private var noSummaryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No Summary Yet")
                .font(.headline)
            Text("Generate an AI summary from the transcript.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button("Generate Summary") {
                Task {
                    await meetingManager.summarizeMeeting(meeting)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
    
}

// MARK: - Action Item Row

struct ActionItemRow: View {
    let text: String
    let index: Int
    @State private var isChecked = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                isChecked.toggle()
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            
            Text(text)
                .font(.body)
                .strikethrough(isChecked)
                .foregroundStyle(isChecked ? .secondary : .primary)
                .textSelection(.enabled)
            
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat
    
    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }
    
    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            sizes.append(size)
            
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        
        return (positions, sizes, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
