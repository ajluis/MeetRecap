import Foundation
import SwiftData
import SwiftUI

/// A remembered voice profile used to auto-label recurring speakers across meetings.
///
/// Voice embeddings come from FluidAudio's diarization pipeline (`DiarizationResult.speakerDatabase`).
/// They are 256-dimensional L2-normalized float vectors; matching is done via cosine similarity
/// (which, for L2-normalized vectors, equals dot product).
@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    @Attribute(.externalStorage) var voiceEmbeddingData: Data  // Float array stored as Data
    var meetingCount: Int
    var totalDuration: TimeInterval
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        embedding: [Float],
        colorHex: String = "#007AFF"
    ) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.voiceEmbeddingData = Self.encode(embedding)
        self.meetingCount = 0
        self.totalDuration = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var voiceEmbedding: [Float] {
        Self.decode(voiceEmbeddingData)
    }

    func setEmbedding(_ newEmbedding: [Float]) {
        voiceEmbeddingData = Self.encode(newEmbedding)
        updatedAt = Date()
    }

    var color: Color {
        Color(hex: colorHex) ?? .accentColor
    }

    // MARK: - Encoding

    private static func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    private static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer.prefix(count))
        }
    }
}
