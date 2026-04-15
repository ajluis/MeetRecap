import Foundation

struct ChatMessage: Identifiable {
    enum Role: String { case user, assistant, system }
    let id = UUID()
    let role: Role
    let text: String
    let citations: [SemanticSearchResult]
    let createdAt: Date = Date()

    init(role: Role, text: String, citations: [SemanticSearchResult] = []) {
        self.role = role
        self.text = text
        self.citations = citations
    }
}

/// Chat-with-the-meeting: RAG over a single meeting's transcript.
///
/// Flow per user message:
///  1. Semantically retrieve the top-K most relevant segments from the meeting.
///  2. Build a context block citing those segments (with timestamps + speakers).
///  3. Ask the configured LLM (OpenAI / Claude) to answer strictly from the context.
///  4. Surface the answer alongside the citations used.
@MainActor
final class MeetingChatService: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming: Bool = false
    @Published var errorMessage: String?

    private let semanticSearch: SemanticSearchService
    private let summaryService: SummaryService

    init(semanticSearch: SemanticSearchService, summaryService: SummaryService) {
        self.semanticSearch = semanticSearch
        self.summaryService = summaryService
    }

    func reset() {
        messages = []
        errorMessage = nil
    }

    /// Send a user message for the given meeting and await the assistant reply.
    func send(
        question: String,
        meeting: Meeting,
        provider: SummaryProvider,
        openAIKey: String?,
        claudeKey: String?
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        isStreaming = true
        errorMessage = nil

        defer { isStreaming = false }

        // Retrieval step needs the OpenAI embeddings key regardless of the chat provider.
        guard let openAIKey = openAIKey, !openAIKey.isEmpty else {
            errorMessage = "Chat requires an OpenAI API key (used for retrieval). Add one in Settings."
            return
        }

        let citations: [SemanticSearchResult]
        do {
            citations = try await semanticSearch.topSegments(
                inMeeting: meeting.id,
                query: trimmed,
                topK: 8,
                apiKey: openAIKey
            )
        } catch {
            errorMessage = "Retrieval failed: \(error.localizedDescription)"
            return
        }

        // If no citations came back (e.g. meeting wasn't embedded), fall back to the full transcript.
        let contextBlock = citations.isEmpty
            ? Self.fullTranscript(of: meeting)
            : Self.contextBlock(from: citations)

        let answer: String
        do {
            answer = try await ask(
                question: trimmed,
                context: contextBlock,
                history: messages.dropLast(),  // exclude the user message we just appended
                provider: provider,
                openAIKey: openAIKey,
                claudeKey: claudeKey
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        messages.append(ChatMessage(role: .assistant, text: answer, citations: citations))
    }

    // MARK: - LLM Call

    private func ask(
        question: String,
        context: String,
        history: some Sequence<ChatMessage>,
        provider: SummaryProvider,
        openAIKey: String,
        claudeKey: String?
    ) async throws -> String {
        let systemPrompt = """
        You are a helpful assistant that answers questions about a single meeting transcript.
        Only answer from the provided context. If the context doesn't contain the answer, say so plainly.
        Keep answers concise (2–4 sentences) unless the user asks for more detail.
        When you cite specific moments, reference them by their [HH:MM] timestamp so the user can jump to them.

        --- MEETING CONTEXT ---
        \(context)
        --- END CONTEXT ---
        """

        switch provider {
        case .openai:
            return try await callOpenAI(
                system: systemPrompt,
                history: Array(history),
                userMessage: question,
                apiKey: openAIKey
            )
        case .claude:
            guard let claudeKey = claudeKey, !claudeKey.isEmpty else {
                // Gracefully fall back to OpenAI if Claude key isn't configured.
                return try await callOpenAI(
                    system: systemPrompt,
                    history: Array(history),
                    userMessage: question,
                    apiKey: openAIKey
                )
            }
            return try await callClaude(
                system: systemPrompt,
                history: Array(history),
                userMessage: question,
                apiKey: claudeKey
            )
        }
    }

    private func callOpenAI(system: String, history: [ChatMessage], userMessage: String, apiKey: String) async throws -> String {
        var url = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        url.httpMethod = "POST"
        url.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        url.addValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for message in history where message.role != .system {
            messages.append(["role": message.role.rawValue, "content": message.text])
        }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages,
            "temperature": 0.2
        ]
        url.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw NSError(domain: "MeetingChatService.openai", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "MeetingChatService.openai", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad response"])
        }
        return content
    }

    private func callClaude(system: String, history: [ChatMessage], userMessage: String, apiKey: String) async throws -> String {
        var url = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        url.httpMethod = "POST"
        url.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        url.addValue("application/json", forHTTPHeaderField: "content-type")
        url.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: Any]] = []
        for message in history where message.role != .system {
            messages.append(["role": message.role.rawValue, "content": message.text])
        }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "system": system,
            "messages": messages
        ]
        url.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw NSError(domain: "MeetingChatService.claude", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw NSError(domain: "MeetingChatService.claude", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad response"])
        }
        return text
    }

    // MARK: - Context Building

    private static func contextBlock(from results: [SemanticSearchResult]) -> String {
        results.map { result in
            let ts = formatTimestamp(result.startTime)
            let speaker = result.speaker ?? "Unknown"
            return "[\(ts)] \(speaker): \(result.text)"
        }
        .joined(separator: "\n\n")
    }

    private static func fullTranscript(of meeting: Meeting) -> String {
        meeting.segments
            .sorted { $0.orderIndex < $1.orderIndex }
            .prefix(200)  // guardrail against very long transcripts
            .map { segment in
                let ts = formatTimestamp(segment.startTime)
                if let speaker = segment.speaker {
                    return "[\(ts)] \(speaker): \(segment.text)"
                }
                return "[\(ts)] \(segment.text)"
            }
            .joined(separator: "\n")
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
