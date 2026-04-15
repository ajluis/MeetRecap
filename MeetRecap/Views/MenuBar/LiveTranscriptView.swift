import SwiftUI

/// Compact live-transcription strip shown in the menu-bar popover while recording.
///
/// Confirmed text renders in the primary color; volatile (tentative) text is
/// rendered in the secondary color to signal it may still change.
struct LiveTranscriptView: View {
    @ObservedObject var service: StreamingTranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "waveform.badge.mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, isActive: service.isRunning)
                Text("Live transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if service.confirmedTranscript.isEmpty && service.volatileTranscript.isEmpty {
                            Text("Listening…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .id("top")
                        } else {
                            transcriptText
                                .id("bottom")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 60)
                .onChange(of: service.confirmedTranscript) { _, _ in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: service.volatileTranscript) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var transcriptText: some View {
        let confirmed = service.confirmedTranscript
        let volatile = service.volatileTranscript

        let confirmedText = Text(confirmed)
            .font(.caption)
            .foregroundStyle(.primary)

        let separator = confirmed.isEmpty || volatile.isEmpty ? Text("") : Text(" ")

        let volatileText = Text(volatile)
            .font(.caption)
            .foregroundStyle(.secondary)
            .italic()

        return (confirmedText + separator + volatileText)
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
    }
}
