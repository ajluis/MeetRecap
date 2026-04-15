import Foundation

/// Per-speaker statistics derived from a meeting's transcript segments.
struct SpeakerStats: Identifiable, Hashable {
    var id: String { speaker }
    let speaker: String
    let talkTime: TimeInterval
    let segmentCount: Int
    let wordCount: Int
    let averageSegmentDuration: TimeInterval
    let interruptionsInitiated: Int
    let topWords: [(word: String, count: Int)]

    func hash(into hasher: inout Hasher) { hasher.combine(speaker) }
    static func == (lhs: SpeakerStats, rhs: SpeakerStats) -> Bool { lhs.speaker == rhs.speaker }
}

/// Pure functions for computing per-speaker analytics over a set of transcript segments.
enum SpeakerAnalytics {
    /// Words shorter than three letters or in this list are filtered out of the "top words" list.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was",
        "one", "our", "out", "day", "get", "has", "him", "his", "how", "man", "new", "now", "old",
        "see", "two", "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use",
        "that", "with", "have", "this", "will", "your", "from", "they", "know", "want", "been",
        "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long",
        "make", "many", "over", "such", "take", "than", "them", "well", "were", "what", "yeah",
        "like", "okay", "right", "think", "gonna", "going", "really", "actually", "basically",
        "also", "could", "would", "should", "because", "which", "about", "there"
    ]

    /// Compute per-speaker stats for a meeting.
    /// Segments without a speaker are ignored.
    static func compute(from segments: [TranscriptSegment]) -> [SpeakerStats] {
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        var grouped: [String: [TranscriptSegment]] = [:]
        for seg in sorted {
            guard let speaker = seg.speaker, !speaker.isEmpty else { continue }
            grouped[speaker, default: []].append(seg)
        }

        let interruptions = interruptionCounts(in: sorted)

        return grouped.map { speaker, segs in
            let talkTime = segs.reduce(0.0) { $0 + max(0, $1.endTime - $1.startTime) }
            let words = segs.reduce(0) { $0 + Self.wordCount(of: $1.text) }
            let avg = segs.isEmpty ? 0 : talkTime / Double(segs.count)
            return SpeakerStats(
                speaker: speaker,
                talkTime: talkTime,
                segmentCount: segs.count,
                wordCount: words,
                averageSegmentDuration: avg,
                interruptionsInitiated: interruptions[speaker] ?? 0,
                topWords: topWords(in: segs, limit: 5)
            )
        }
        .sorted { $0.talkTime > $1.talkTime }
    }

    /// Count times a speaker starts talking while another speaker is still in-segment.
    private static func interruptionCounts(in sorted: [TranscriptSegment]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (idx, seg) in sorted.enumerated() where idx > 0 {
            let prev = sorted[idx - 1]
            guard let speaker = seg.speaker,
                  let prevSpeaker = prev.speaker,
                  speaker != prevSpeaker else { continue }
            // "Interruption" = new speaker starts before the previous speaker's segment ends.
            if seg.startTime < prev.endTime {
                counts[speaker, default: 0] += 1
            }
        }
        return counts
    }

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    private static func topWords(in segments: [TranscriptSegment], limit: Int) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for seg in segments {
            let words = seg.text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for word in words where word.count >= 4 && !stopWords.contains(word) {
                counts[word, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (word: $0.key, count: $0.value) }
    }
}
