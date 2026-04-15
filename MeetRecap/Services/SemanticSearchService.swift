import Foundation
import SwiftData

/// A single hit returned by cross-meeting search.
struct SemanticSearchResult: Identifiable {
    let id = UUID()
    let segmentID: UUID
    let meetingID: UUID
    let meetingTitle: String
    let meetingDate: Date
    let speaker: String?
    let text: String
    let startTime: TimeInterval
    let score: Float
}

/// Cross-meeting keyword search over transcript segments.
///
/// Implementation: a light BM25-ish scorer — terms in the query are weighted by inverse
/// document frequency across meetings, then each segment is scored on term overlap plus
/// a bonus for segments whose surrounding meeting matches the query (title / summary / tag).
///
/// No embeddings, no external API — runs entirely against the local SwiftData store.
@MainActor
final class SemanticSearchService: ObservableObject {
    @Published var isSearching: Bool = false

    private var modelContext: ModelContext?

    // BM25 tuning knobs (standard defaults).
    private let k1: Float = 1.2
    private let b: Float = 0.75

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    /// Search every meeting for the best-matching segments. Returns top-K hits by score.
    func search(query: String, topK: Int = 20) -> [SemanticSearchResult] {
        guard let context = modelContext else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        isSearching = true
        defer { isSearching = false }

        let queryTokens = tokenize(trimmed)
        guard !queryTokens.isEmpty else { return [] }

        let descriptor = FetchDescriptor<TranscriptSegment>()
        let segments = (try? context.fetch(descriptor)) ?? []
        guard !segments.isEmpty else { return [] }

        // Document length stats for BM25.
        var segmentTokens: [UUID: [String]] = [:]
        var totalLen = 0
        for segment in segments {
            let tokens = tokenize(segment.text)
            segmentTokens[segment.id] = tokens
            totalLen += tokens.count
        }
        let avgLen = Float(totalLen) / Float(max(segments.count, 1))

        // Inverse document frequency per query term.
        var idfByTerm: [String: Float] = [:]
        let N = Float(segments.count)
        for term in Set(queryTokens) {
            let df = segmentTokens.values.reduce(into: 0) { count, tokens in
                if tokens.contains(term) { count += 1 }
            }
            // Standard BM25 IDF, floored at 0.
            let idf = log((N - Float(df) + 0.5) / (Float(df) + 0.5) + 1)
            idfByTerm[term] = max(idf, 0)
        }

        // Score each segment.
        var scored: [(SemanticSearchResult, Float)] = []
        scored.reserveCapacity(segments.count)

        for segment in segments {
            guard let tokens = segmentTokens[segment.id], !tokens.isEmpty else { continue }
            let len = Float(tokens.count)
            var termCounts: [String: Int] = [:]
            for token in tokens { termCounts[token, default: 0] += 1 }

            var score: Float = 0
            for term in queryTokens {
                guard let idf = idfByTerm[term], idf > 0 else { continue }
                let tf = Float(termCounts[term] ?? 0)
                guard tf > 0 else { continue }
                let numerator = tf * (k1 + 1)
                let denominator = tf + k1 * (1 - b + b * len / avgLen)
                score += idf * numerator / denominator
            }

            if score <= 0 { continue }

            guard let meeting = segment.meeting else { continue }

            // Small boost if the meeting title, summary, or tags also match the query string.
            let boost = meetingBoost(meeting: meeting, query: trimmed)
            let finalScore = score + boost

            let result = SemanticSearchResult(
                segmentID: segment.id,
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                meetingDate: meeting.date,
                speaker: segment.speaker,
                text: segment.text,
                startTime: segment.startTime,
                score: finalScore
            )
            scored.append((result, finalScore))
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    /// Top-K segments within a single meeting. Used for chat retrieval.
    func topSegments(inMeeting meetingID: UUID, query: String, topK: Int) -> [SemanticSearchResult] {
        let results = search(query: query, topK: 200)
        return Array(results.filter { $0.meetingID == meetingID }.prefix(topK))
    }

    // MARK: - Tokenization

    private let stopwords: Set<String> = [
        "a", "an", "and", "the", "of", "in", "on", "at", "to", "for", "with",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "do", "does", "did", "will", "would", "should", "could", "may", "might",
        "can", "this", "that", "these", "those", "i", "you", "he", "she", "it",
        "we", "they", "what", "which", "who", "when", "where", "why", "how",
        "so", "but", "or", "if", "then", "than", "as", "just", "like", "about"
    ]

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
    }

    private func meetingBoost(meeting: Meeting, query: String) -> Float {
        var boost: Float = 0
        if meeting.title.localizedCaseInsensitiveContains(query) {
            boost += 1.5
        }
        if meeting.summary?.localizedCaseInsensitiveContains(query) == true {
            boost += 0.75
        }
        for tag in meeting.tags where tag.name.localizedCaseInsensitiveContains(query) {
            boost += 0.5
        }
        return boost
    }
}
