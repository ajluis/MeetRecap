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

/// Chat-with-this-meeting over OpenRouter.
///
/// Flow per user message:
///  1. Semantic-retrieve the 8 most relevant segments from the meeting.
///  2. Build a timestamped context block.
///  3. Ask GLM via OpenRouter to answer strictly from the context.
///  4. Surface citations as clickable timestamps in the UI.
@MainActor
final class MeetingChatService: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming: Bool = false
    @Published var errorMessage: String?

    private let semanticSearch: SemanticSearchService
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let urlSession: URLSession

    init(semanticSearch: SemanticSearchService) {
        self.semanticSearch = semanticSearch
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.urlSession = URLSession(configuration: config)
    }

    func reset() {
        messages = []
        errorMessage = nil
    }

    // MARK: - Send

    /// Send a user message for the given meeting and await the assistant reply.
    ///
    /// Retrieval strategy:
    ///   1. Run a quick keyword search to pull the 8 most topically-relevant segments.
    ///   2. Always include the full transcript too — GLM-4.6 / GLM-5.1 have 200K windows,
    ///      so even long meetings fit comfortably. Retrieval just helps the model focus
    ///      and gives us citations the UI can linkify.
    func send(
        question: String,
        meeting: Meeting,
        openRouterKey: String?,
        model: String,
        reasoningEffort: ReasoningEffort
    ) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        isStreaming = true
        errorMessage = nil
        defer { isStreaming = false }

        guard let openRouterKey = openRouterKey, !openRouterKey.isEmpty else {
            errorMessage = "Add an OpenRouter API key in Settings to enable chat."
            return
        }

        // Keyword retrieval for citation hints. No API call, no key required.
        let citations = semanticSearch.topSegments(
            inMeeting: meeting.id,
            query: trimmed,
            topK: 8
        )

        // Build context: full transcript (primary) + a highlight block if keyword hits exist.
        let context = Self.contextBlock(fullTranscriptOf: meeting, highlights: citations)

        let answer: String
        do {
            answer = try await askOpenRouter(
                question: trimmed,
                context: context,
                history: Array(messages.dropLast()),
                apiKey: openRouterKey,
                model: model,
                reasoningEffort: reasoningEffort
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        messages.append(ChatMessage(role: .assistant, text: answer, citations: citations))
    }

    // MARK: - OpenRouter

    private func askOpenRouter(
        question: String,
        context: String,
        history: [ChatMessage],
        apiKey: String,
        model: String,
        reasoningEffort: ReasoningEffort
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("https://meetrecap.app", forHTTPHeaderField: "HTTP-Referer")
        request.addValue("MeetRecap", forHTTPHeaderField: "X-Title")

        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt(context: context)]
        ]
        for message in history where message.role != .system {
            messages.append(["role": message.role.rawValue, "content": message.text])
        }
        messages.append(["role": "user", "content": question])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "reasoning": ["effort": reasoningEffort.rawValue]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw NSError(
                domain: "MeetingChatService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "OpenRouter error: \(msg)"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(
                domain: "MeetingChatService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected OpenRouter response shape"]
            )
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt

    static func systemPrompt(context: String) -> String {
        """
        You are MeetRecap's meeting assistant. You answer questions about ONE meeting transcript \
        using ONLY the context block below.

        Rules (follow all of them):
        1. Answer strictly from the context. If the context doesn't contain the answer, reply \
           exactly: "The transcript doesn't cover that." — do not guess, do not speculate.
        2. Cite specific moments inline using `[HH:MM]` or `[H:MM:SS]` timestamps so the user can jump to them.
        3. Be concise. Default to 2-4 short sentences. Expand only if the user explicitly asks for detail.
        4. Identify people by their labeled speaker name; fall back to "Speaker 1", "Speaker 2" etc.
        5. Never restate the question. Start with the answer.
        6. Do not add closers like "Let me know if you need more." Do not hedge unnecessarily.
        7. When asked "what was decided" or "action items", list them as tight bullet points, each \
           with owner + commitment + timestamp.
        8. Output plain text. No markdown headers, no code fences.

        --- MEETING CONTEXT ---
        \(context)
        --- END CONTEXT ---
        """
    }

    // MARK: - Context Building

    private static func contextBlock(
        fullTranscriptOf meeting: Meeting,
        highlights: [SemanticSearchResult]
    ) -> String {
        let transcript = meeting.segments
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { segment in
                let ts = formatTimestamp(segment.startTime)
                if let speaker = segment.speaker {
                    return "[\(ts)] \(speaker): \(segment.text)"
                }
                return "[\(ts)] \(segment.text)"
            }
            .joined(separator: "\n")

        if highlights.isEmpty {
            return "## Full Transcript\n\n\(transcript)"
        }

        let highlightsBlock = highlights.map { result in
            let ts = formatTimestamp(result.startTime)
            let speaker = result.speaker ?? "Unknown"
            return "[\(ts)] \(speaker): \(result.text)"
        }
        .joined(separator: "\n")

        return """
        ## Most Relevant Segments (keyword-matched)

        \(highlightsBlock)

        ## Full Transcript

        \(transcript)
        """
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
