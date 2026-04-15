import Foundation
import SwiftData
import Accelerate

/// A single hit returned by semantic search across meetings.
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

/// Cross-meeting semantic search over transcript segment embeddings.
///
/// All segments are embedded at transcription time with OpenAI's 1536-dim
/// `text-embedding-3-small`. We embed the query with the same model and return
/// the top-K segments by cosine similarity.
@MainActor
final class SemanticSearchService: ObservableObject {
    @Published var isSearching: Bool = false

    private var modelContext: ModelContext?

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Run a semantic search across every meeting's indexed segments.
    func search(query: String, topK: Int = 12, apiKey: String) async throws -> [SemanticSearchResult] {
        guard let context = modelContext else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        isSearching = true
        defer { isSearching = false }

        let queryVector = try await EmbeddingService.shared.embed(trimmed, apiKey: apiKey)
        guard !queryVector.isEmpty else { return [] }

        // Fetch segments with embeddings.
        let descriptor = FetchDescriptor<TranscriptSegment>(
            predicate: #Predicate { $0.embeddingData != nil }
        )
        let segments = (try? context.fetch(descriptor)) ?? []

        // Score each segment.
        var scored: [(SemanticSearchResult, Float)] = []
        scored.reserveCapacity(segments.count)

        for segment in segments {
            guard let data = segment.embeddingData else { continue }
            let vector = EmbeddingCoding.decode(data)
            guard vector.count == queryVector.count else { continue }
            let score = cosine(queryVector, vector)
            guard let meeting = segment.meeting else { continue }
            let result = SemanticSearchResult(
                segmentID: segment.id,
                meetingID: meeting.id,
                meetingTitle: meeting.title,
                meetingDate: meeting.date,
                speaker: segment.speaker,
                text: segment.text,
                startTime: segment.startTime,
                score: score
            )
            scored.append((result, score))
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { $0.0 }
    }

    /// Fetch the top-K most relevant segments within a single meeting for chat retrieval.
    func topSegments(inMeeting meetingID: UUID, query: String, topK: Int, apiKey: String) async throws -> [SemanticSearchResult] {
        let results = try await search(query: query, topK: 200, apiKey: apiKey)
        return Array(results.filter { $0.meetingID == meetingID }.prefix(topK))
    }

    // MARK: - Similarity

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var normA: Float = 0
        var normB: Float = 0
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
