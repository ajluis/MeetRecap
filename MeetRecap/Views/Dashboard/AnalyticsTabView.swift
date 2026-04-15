import SwiftUI

/// Per-speaker analytics pane: talk time, interruptions, top words.
struct AnalyticsTabView: View {
    let meeting: Meeting

    private var stats: [SpeakerStats] {
        SpeakerAnalytics.compute(from: meeting.segments)
    }

    private var totalTalkTime: TimeInterval {
        stats.reduce(0) { $0 + $1.talkTime }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if stats.isEmpty {
                    emptyView
                } else {
                    overviewSection
                    talkTimeSection
                    interruptionsSection
                    topWordsSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        HStack(spacing: 12) {
            statCard(
                title: "Speakers",
                value: "\(stats.count)",
                icon: "person.2"
            )
            statCard(
                title: "Total talk time",
                value: formatDuration(totalTalkTime),
                icon: "clock"
            )
            statCard(
                title: "Interruptions",
                value: "\(stats.reduce(0) { $0 + $1.interruptionsInitiated })",
                icon: "arrow.triangle.branch"
            )
        }
    }

    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Talk Time

    private var talkTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Talk time", systemImage: "waveform")
                .font(.headline)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                ForEach(stats) { stat in
                    talkTimeRow(stat)
                }
            }
        }
    }

    private func talkTimeRow(_ stat: SpeakerStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(speakerColor(stat.speaker)).frame(width: 8, height: 8)
                Text(stat.speaker)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(formatDuration(stat.talkTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(percentage(stat.talkTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(speakerColor(stat.speaker))
                        .frame(width: geo.size.width * barFraction(stat.talkTime))
                }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                Text("\(stat.segmentCount) segments")
                Text("\(stat.wordCount) words")
                Text("avg \(formatDuration(stat.averageSegmentDuration))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Interruptions

    private var interruptionsSection: some View {
        let ranked = stats.filter { $0.interruptionsInitiated > 0 }
        guard !ranked.isEmpty else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Label("Interruptions initiated", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Times each speaker started before the previous speaker finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    ForEach(ranked) { stat in
                        HStack {
                            Circle().fill(speakerColor(stat.speaker)).frame(width: 6, height: 6)
                            Text(stat.speaker).font(.subheadline)
                            Spacer()
                            Text("\(stat.interruptionsInitiated)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        )
    }

    // MARK: - Top Words

    private var topWordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Top words per speaker", systemImage: "text.word.spacing")
                .font(.headline)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(speakerColor(stat.speaker)).frame(width: 6, height: 6)
                            Text(stat.speaker).font(.subheadline).fontWeight(.medium)
                        }
                        if stat.topWords.isEmpty {
                            Text("—")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: 6) {
                                ForEach(stat.topWords, id: \.word) { entry in
                                    HStack(spacing: 3) {
                                        Text(entry.word)
                                            .font(.caption)
                                        Text("·\(entry.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(speakerColor(stat.speaker).opacity(0.15))
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No speaker data")
                .font(.headline)
            Text("Run transcription with speaker diarization enabled to see analytics.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        if mins > 0 { return String(format: "%d:%02d", mins, secs) }
        return "\(secs)s"
    }

    private func percentage(_ talkTime: TimeInterval) -> String {
        guard totalTalkTime > 0 else { return "—" }
        return String(format: "%.0f%%", talkTime / totalTalkTime * 100)
    }

    private func barFraction(_ talkTime: TimeInterval) -> CGFloat {
        guard let max = stats.map(\.talkTime).max(), max > 0 else { return 0 }
        return CGFloat(talkTime / max)
    }

    private func speakerColor(_ speaker: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        return colors[abs(speaker.hashValue) % colors.count]
    }
}
