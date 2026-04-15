import Foundation
import Combine

struct MeetingSummary: Codable {
    let summary: String
    let actionItems: [String]
    let keyTopics: [String]
    let participants: [String]
}

enum SummaryState: Equatable {
    case idle
    case generating
    case completed
    case failed(String)

    static func == (lhs: SummaryState, rhs: SummaryState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.generating, .generating), (.completed, .completed):
            return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

/// Turns a transcript into a structured `MeetingSummary` by calling OpenRouter.
///
/// OpenRouter exposes an OpenAI-compatible Chat Completions endpoint and supports a
/// `reasoning.effort` field that's passed through to reasoning-capable models like GLM-4.6.
/// We keep `effort = .low` by default so the summary stays snappy.
@MainActor
final class SummaryService: ObservableObject {
    @Published var state: SummaryState = .idle

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let urlSession: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Generate a meeting summary. Throws if the OpenRouter key is missing or the API errors out.
    func generateSummary(
        transcript: String,
        apiKey: String,
        model: String,
        reasoningEffort: ReasoningEffort
    ) async throws -> MeetingSummary {
        guard !apiKey.isEmpty else {
            throw SummaryError.missingAPIKey("OpenRouter API key not configured")
        }
        state = .generating
        do {
            let summary = try await call(
                transcript: transcript,
                apiKey: apiKey,
                model: model,
                reasoningEffort: reasoningEffort
            )
            state = .completed
            return summary
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: - OpenRouter Call

    private func call(
        transcript: String,
        apiKey: String,
        model: String,
        reasoningEffort: ReasoningEffort
    ) async throws -> MeetingSummary {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("https://meetrecap.app", forHTTPHeaderField: "HTTP-Referer")
        request.addValue("MeetRecap", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "reasoning": ["effort": reasoningEffort.rawValue],
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": Self.userPrompt(for: transcript)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SummaryError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SummaryError.apiError("OpenRouter error (\(http.statusCode)): \(msg)")
        }
        return try parse(data: data)
    }

    private func parse(data: Data) throws -> MeetingSummary {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryError.parseError("Unexpected OpenRouter response shape")
        }
        return try decodeSummaryJSON(content)
    }

    private func decodeSummaryJSON(_ text: String) throws -> MeetingSummary {
        let cleaned = stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = cleaned.data(using: .utf8) else {
            throw SummaryError.parseError("Empty response")
        }
        do {
            return try JSONDecoder().decode(MeetingSummary.self, from: jsonData)
        } catch {
            throw SummaryError.parseError("Failed to parse summary JSON: \(error.localizedDescription)")
        }
    }

    /// Some models wrap JSON in ```json … ``` fences despite being told not to.
    /// Strip them defensively.
    private func stripCodeFences(_ text: String) -> String {
        var out = text
        if let start = out.range(of: "```json") {
            out.removeSubrange(out.startIndex..<start.upperBound)
        } else if let start = out.range(of: "```") {
            out.removeSubrange(out.startIndex..<start.upperBound)
        }
        if let end = out.range(of: "```", options: .backwards) {
            out.removeSubrange(end.lowerBound..<out.endIndex)
        }
        return out
    }
}

// MARK: - Prompts

extension SummaryService {
    /// Tight, opinionated system prompt tuned for a meeting-recap app.
    /// Designed to force structured JSON and punchy, actionable content.
    static let systemPrompt: String = """
    You are MeetRecap's meeting summarizer. You read a single meeting transcript and \
    return a structured JSON object describing what actually happened.

    Output requirements (NON-NEGOTIABLE):
    - Return ONE valid JSON object. No markdown fences, no prose before or after.
    - Schema:
      {
        "summary": string,               // 3-5 sentences, focus on decisions and outcomes, not topics discussed
        "keyTopics": [string],           // 3-7 short noun phrases (2-5 words each). Topics, not sentences.
        "actionItems": [string],         // Specific commitments. Format: "<Owner>: <verb-phrase> [by <deadline>]". Omit if no owner is clear.
        "participants": [string]         // Names of people who spoke. Use "Speaker 1" etc. only if names aren't identifiable.
      }

    Rules:
    - Prefer "what was decided" over "what was discussed".
    - Skip filler, smalltalk, scheduling chatter, and re-stating of prior points.
    - An action item WITHOUT an owner is almost always noise — omit it.
    - Do not invent names, dates, or commitments that aren't in the transcript.
    - Write in past-tense third person. Do not address the user.
    - If the transcript is empty or nonsensical, return all four fields as empty arrays / strings.
    """

    static func userPrompt(for transcript: String) -> String {
        """
        Transcript:
        ---
        \(transcript)
        ---

        Return the JSON object now.
        """
    }
}

// MARK: - Errors

enum SummaryError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse
    case apiError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        case .invalidResponse: return "Invalid API response"
        case .apiError(let msg): return msg
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
