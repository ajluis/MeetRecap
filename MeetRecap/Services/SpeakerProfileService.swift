import Foundation
import SwiftData
import Accelerate

/// Manages persistent speaker profiles and matches new voice embeddings to known profiles.
///
/// Embeddings from FluidAudio's diarization pipeline are L2-normalized 256-dim float
/// vectors, so cosine similarity reduces to a dot product. We use Accelerate's
/// `vDSP_dotpr` for SIMD-friendly scoring.
@MainActor
final class SpeakerProfileService: ObservableObject {
    private var modelContext: ModelContext?

    /// Cosine-similarity threshold above which an embedding is considered a match.
    /// Tunable via AppSettings.
    var matchThreshold: Float = 0.85

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CRUD

    func allProfiles() -> [SpeakerProfile] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func createOrUpdateProfile(name: String, embedding: [Float], colorHex: String = "#007AFF") -> SpeakerProfile? {
        guard let context = modelContext else { return nil }
        let all = allProfiles()
        if let existing = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            existing.setEmbedding(embedding)
            existing.colorHex = colorHex
            try? context.save()
            return existing
        } else {
            let profile = SpeakerProfile(name: name, embedding: embedding, colorHex: colorHex)
            context.insert(profile)
            try? context.save()
            return profile
        }
    }

    func deleteProfile(_ profile: SpeakerProfile) {
        modelContext?.delete(profile)
        try? modelContext?.save()
    }

    // MARK: - Matching

    /// Match an incoming meeting's speaker embeddings against known profiles.
    ///
    /// Returns a mapping from the raw speaker ID (e.g. "Speaker 1") to the best-matching
    /// profile name, plus the similarity score, for speakers that meet the threshold.
    func matchSpeakers(
        meetingEmbeddings: [String: [Float]]
    ) -> [String: (name: String, profileID: UUID, score: Float)] {
        let profiles = allProfiles()
        guard !profiles.isEmpty else { return [:] }

        var result: [String: (name: String, profileID: UUID, score: Float)] = [:]

        for (speakerID, embedding) in meetingEmbeddings {
            var bestScore: Float = -.infinity
            var bestProfile: SpeakerProfile?

            for profile in profiles {
                let score = cosineSimilarity(embedding, profile.voiceEmbedding)
                if score > bestScore {
                    bestScore = score
                    bestProfile = profile
                }
            }

            if let best = bestProfile, bestScore >= matchThreshold {
                result[speakerID] = (name: best.name, profileID: best.id, score: bestScore)
            }
        }

        return result
    }

    /// Apply matched names to a meeting's transcript segments in place.
    /// Also increments meetingCount/totalDuration on each matched profile.
    func applyMatches(
        _ matches: [String: (name: String, profileID: UUID, score: Float)],
        to meeting: Meeting
    ) {
        guard !matches.isEmpty, let context = modelContext else { return }

        let profiles = allProfiles()
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        for segment in meeting.segments {
            guard let raw = segment.speaker, let match = matches[raw] else { continue }
            segment.speaker = match.name
            segment.speakerProfileID = match.profileID
        }

        // Bump profile usage counters
        var countedForMeeting: Set<UUID> = []
        for (_, match) in matches {
            guard let profile = profileByID[match.profileID] else { continue }
            if !countedForMeeting.contains(profile.id) {
                profile.meetingCount += 1
                countedForMeeting.insert(profile.id)
            }
            profile.updatedAt = Date()
        }

        let totalDelta = meeting.duration / Double(max(matches.count, 1))
        for (_, match) in matches {
            profileByID[match.profileID]?.totalDuration += totalDelta
        }

        try? context.save()
    }

    // MARK: - Similarity

    /// Cosine similarity for two equal-length vectors. When inputs are L2-normalized
    /// (as FluidAudio's embeddings are), this equals the dot product.
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }

        var dot: Float = 0
        a.withUnsafeBufferPointer { aPtr in
            b.withUnsafeBufferPointer { bPtr in
                vDSP_dotpr(aPtr.baseAddress!, 1, bPtr.baseAddress!, 1, &dot, vDSP_Length(a.count))
            }
        }

        // Defensive norm — in case an embedding isn't normalized.
        var normA: Float = 0
        var normB: Float = 0
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
