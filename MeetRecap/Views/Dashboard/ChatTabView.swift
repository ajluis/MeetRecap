import SwiftUI

/// Chat-with-this-meeting: ask questions about the transcript, get cited answers.
struct ChatTabView: View {
    let meeting: Meeting
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var appSettings: AppSettingsStore

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    private var chat: MeetingChatService { meetingManager.chatService }
    private var hasOpenAIKey: Bool {
        (KeychainHelper.load(key: "meetrecap_openai_key") ?? "").isEmpty == false
    }

    var body: some View {
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                introView
            } else {
                messageList
            }

            Divider()
            composer
        }
        .onAppear {
            inputFocused = true
            // Reset chat state when switching meetings.
            if chat.messages.last?.citations.first?.meetingID != meeting.id {
                chat.reset()
            }
        }
    }

    // MARK: - Intro

    private var introView: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("Ask about this meeting")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Ask questions in plain English. Answers cite specific moments in the transcript.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 6) {
                suggestion("What were the main decisions?")
                suggestion("What action items were assigned?")
                suggestion("Summarize what \(meeting.participants.first ?? "the team") said")
            }
            .padding(.top, 6)

            if !hasOpenAIKey {
                Label("Chat requires an OpenAI API key (Settings → API Keys)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }

            Spacer()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestion(_ prompt: String) -> some View {
        Button {
            input = prompt
            inputFocused = true
        } label: {
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        ChatMessageRow(
                            message: message,
                            onCitationTap: { result in
                                meetingManager.audioPlayback.seekAndPlay(to: result.startTime)
                            }
                        )
                        .id(message.id)
                    }

                    if chat.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 12)
                    }
                }
                .padding(16)
            }
            .onChange(of: chat.messages.count) { _, _ in
                if let last = chat.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 4) {
            if let error = chat.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                TextField("Ask about this meeting…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                    )
                    .focused($inputFocused)
                    .onSubmit(send)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || chat.isStreaming || !hasOpenAIKey)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Actions

    private func send() {
        let question = input
        input = ""
        Task {
            let openAI = KeychainHelper.load(key: "meetrecap_openai_key")
            let claude = KeychainHelper.load(key: "meetrecap_claude_key")
            await chat.send(
                question: question,
                meeting: meeting,
                provider: appSettings.selectedSummaryProvider,
                openAIKey: openAI,
                claudeKey: claude
            )
        }
    }
}

// MARK: - Message Row

struct ChatMessageRow: View {
    let message: ChatMessage
    let onCitationTap: (SemanticSearchResult) -> Void

    var body: some View {
        if message.role == .user {
            userBubble
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.text)
                .font(.body)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .textSelection(.enabled)
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 3)
                Text(message.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cited moments")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(message.citations.prefix(5)) { citation in
                        Button {
                            onCitationTap(citation)
                        } label: {
                            HStack(spacing: 6) {
                                Text(formatTime(citation.startTime))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                if let speaker = citation.speaker {
                                    Text(speaker)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                }
                                Text(citation.text)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
