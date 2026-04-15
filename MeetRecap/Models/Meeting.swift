import Foundation
import SwiftData

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var audioFileBookmark: Data?  // Security-scoped bookmark for audio file
    var screenRecordingBookmark: Data?  // Security-scoped bookmark for video file
    var audioStoragePath: String?  // Plain path fallback for bookmark staleness
    var summary: String?
    @Attribute(.externalStorage) var actionItemsData: Data?  // JSON encoded [String]
    @Attribute(.externalStorage) var keyTopicsData: Data?    // JSON encoded [String]
    var participants: [String]
    var isTranscribed: Bool
    var isSummarized: Bool
    var createdAt: Date
    var updatedAt: Date
    var calendarEventIdentifier: String?  // Links to an EventKit calendar event, if any

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(inverse: \Tag.meetings)
    var tags: [Tag]

    init(
        title: String = "Untitled Meeting",
        date: Date = Date(),
        duration: TimeInterval = 0
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.duration = duration
        self.summary = nil
        self.actionItemsData = nil
        self.keyTopicsData = nil
        self.participants = []
        self.isTranscribed = false
        self.isSummarized = false
        self.createdAt = Date()
        self.updatedAt = Date()
        self.segments = []
        self.tags = []
    }

    var actionItems: [String] {
        get {
            guard let data = actionItemsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            actionItemsData = try? JSONEncoder().encode(newValue)
        }
    }

    var keyTopics: [String] {
        get {
            guard let data = keyTopicsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            keyTopicsData = try? JSONEncoder().encode(newValue)
        }
    }

    var audioFileURL: URL? {
        // Prefer bookmark resolution; fall back to plain path on staleness.
        if let bookmark = audioFileBookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let path = audioStoragePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    var screenRecordingURL: URL? {
        guard let bookmark = screenRecordingBookmark else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
