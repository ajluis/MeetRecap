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
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
final class SummaryService: ObservableObject {
    @Published var state: SummaryState = .idle
    
    private let urlSession: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.urlSession = URLSession(configuration: config)
    }
    
    // MARK: - Summary Generation
    
    func generateSummary(
        transcript: String,
        provider: SummaryProvider,
        openAIAPIKey: String? = nil,
        claudeAPIKey: String? = nil
    ) async throws -> MeetingSummary {
        state = .generating
        
        do {
            let summary: MeetingSummary
            switch provider {
            case .openai:
                guard let apiKey = openAIAPIKey, !apiKey.isEmpty else {
                    throw SummaryError.missingAPIKey("OpenAI API key not configured")
                }
                summary = try await callOpenAI(transcript: transcript, apiKey: apiKey)
            case .claude:
                guard let apiKey = claudeAPIKey, !apiKey.isEmpty else {
                    throw SummaryError.missingAPIKey("Claude API key not configured")
                }
                summary = try await callClaude(transcript: transcript, apiKey: apiKey)
            }
            
            state = .completed
            return summary
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - OpenAI API
    
    private func callOpenAI(transcript: String, apiKey: String) async throws -> MeetingSummary {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                [
                    "role": "system",
                    "content": summarySystemPrompt
                ],
                [
                    "role": "user",
                    "content": "Please analyze this meeting transcript:\n\n\(transcript)"
                ]
            ],
            "temperature": 0.3,
            "response_format": ["type": "json_object"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummaryError.apiError("OpenAI API error (\(httpResponse.statusCode)): \(errorMessage)")
        }
        
        return try parseOpenAIResponse(data)
    }
    
    private func parseOpenAIResponse(_ data: Data) throws -> MeetingSummary {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SummaryError.parseError("Invalid OpenAI response format")
        }
        
        return try parseSummaryJSON(content)
    }
    
    // MARK: - Claude API
    
    private func callClaude(transcript: String, apiKey: String) async throws -> MeetingSummary {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let body: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 2048,
            "system": summarySystemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": "Please analyze this meeting transcript:\n\n\(transcript)"
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummaryError.apiError("Claude API error (\(httpResponse.statusCode)): \(errorMessage)")
        }
        
        return try parseClaudeResponse(data)
    }
    
    private func parseClaudeResponse(_ data: Data) throws -> MeetingSummary {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw SummaryError.parseError("Invalid Claude response format")
        }
        
        return try parseSummaryJSON(text)
    }
    
    // MARK: - JSON Parsing
    
    private func parseSummaryJSON(_ jsonString: String) throws -> MeetingSummary {
        guard let data = jsonString.data(using: .utf8) else {
            throw SummaryError.parseError("Failed to convert string to data")
        }
        
        do {
            let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)
            return summary
        } catch {
            // Try to extract JSON from markdown code blocks
            if let range = jsonString.range(of: "```json") {
                let afterJson = jsonString[range.upperBound...]
                if let endRange = afterJson.range(of: "```") {
                    let jsonContent = String(afterJson[afterJson.startIndex..<endRange.lowerBound])
                    if let jsonData = jsonContent.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) {
                        return try JSONDecoder().decode(MeetingSummary.self, from: jsonData)
                    }
                }
            }
            throw SummaryError.parseError("Failed to parse summary JSON: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Prompts
    
    private var summarySystemPrompt: String {
        """
        You are an AI assistant that analyzes meeting transcripts. 
        Return a JSON object with exactly these fields:
        {
            "summary": "A concise 2-3 paragraph summary of the meeting",
            "actionItems": ["List of specific action items mentioned", "..."],
            "keyTopics": ["Main topics discussed", "..."],
            "participants": ["Names of participants if identifiable", "..."]
        }
        
        Be specific and actionable. Focus on decisions made, action items assigned, and key discussion points.
        If participant names aren't clear, use "Speaker 1", "Speaker 2", etc.
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
