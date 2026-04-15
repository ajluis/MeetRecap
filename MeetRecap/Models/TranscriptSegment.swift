import Foundation
import SwiftData

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speaker: String?
    var speakerProfileID: UUID?  // Links to a SpeakerProfile, if known
    var confidence: Float
    var orderIndex: Int  // Maintain ordering within a meeting
    @Attribute(.externalStorage) var embeddingData: Data?  // Float32 vector (1536-dim)

    var meeting: Meeting?

    init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String? = nil,
        confidence: Float = 1.0,
        orderIndex: Int = 0
    ) {
        self.id = UUID()
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.confidence = confidence
        self.orderIndex = orderIndex
    }

    var formattedTimestamp: String {
        let startMin = Int(startTime) / 60
        let startSec = Int(startTime) % 60
        let endMin = Int(endTime) / 60
        let endSec = Int(endTime) % 60
        return String(format: "%d:%02d - %d:%02d", startMin, startSec, endMin, endSec)
    }
}
