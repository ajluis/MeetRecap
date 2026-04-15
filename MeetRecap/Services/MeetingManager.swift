import Foundation
import SwiftData
import Combine
import UserNotifications

@MainActor
final class MeetingManager: ObservableObject {
    @Published var isTranscriptionReady = false
    @Published var isProcessing = false
    @Published var processingStatus = ""

    let audioRecorder: AudioRecorder
    let screenRecorder: ScreenRecorder
    let transcriptionService: TranscriptionService
    let summaryService: SummaryService
    let audioDeviceManager: AudioDeviceManager
    let audioPlayback: AudioPlaybackService
    let streamingTranscription: StreamingTranscriptionService

    // Expose transcription service state for UI
    var transcriptionState: TranscriptionState {
        transcriptionService.state
    }
    
    private var modelContext: ModelContext?
    private var appSettings: AppSettingsStore?
    
    init() {
        self.audioRecorder = AudioRecorder()
        self.screenRecorder = ScreenRecorder()
        self.transcriptionService = TranscriptionService()
        self.summaryService = SummaryService()
        self.audioDeviceManager = AudioDeviceManager()
        self.audioPlayback = AudioPlaybackService()
        self.streamingTranscription = StreamingTranscriptionService()
    }
    
    func configure(modelContext: ModelContext, appSettings: AppSettingsStore) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        
        // Load transcription model
        Task {
            await loadTranscriptionModel()
        }
    }
    
    // MARK: - Model Loading

    public func loadTranscriptionModel() async {
        let version = appSettings?.selectedParakeetVersion ?? .v3
        
        do {
            try await transcriptionService.loadModel(version: version)
            isTranscriptionReady = true
        } catch {
            print("Failed to load transcription model: \(error)")
            isTranscriptionReady = false
        }
    }
    
    // MARK: - Recording Lifecycle

    /// Start a live-streaming transcription session that runs alongside the
    /// normal file-based recording. Call after the audio tap is installed.
    func startLiveTranscription() async {
        guard let models = transcriptionService.loadedModels else { return }

        // Forward tap buffers into the sliding-window manager
        let streaming = streamingTranscription
        audioRecorder.onAudioBuffer = { buffer in
            streaming.appendBuffer(buffer)
        }

        await streaming.start(models: models)
    }

    /// Called when recording stops. Triggers post-processing pipeline.
    func finishRecording(
        audioURL: URL?,
        screenRecordingURL: URL?,
        duration: TimeInterval
    ) async {
        // Tear down live streaming — full-file transcription replaces it below.
        audioRecorder.onAudioBuffer = nil
        streamingTranscription.stop()

        guard let audioURL = audioURL else { return }
        
        // Create meeting record
        let meeting = Meeting(
            title: "Meeting \(formattedDate())",
            date: Date(),
            duration: duration
        )
        
        // Store file bookmarks + plain path fallback
        meeting.audioFileBookmark = try? audioURL.bookmarkData()
        meeting.audioStoragePath = audioURL.path
        if let screenURL = screenRecordingURL {
            meeting.screenRecordingBookmark = try? screenURL.bookmarkData()
        }

        // Save to SwiftData
        modelContext?.insert(meeting)
        try? modelContext?.save()
        
        // Post-process
        if appSettings?.autoTranscribe ?? true {
            await transcribeMeeting(meeting, audioURL: audioURL)
        }
    }
    
    // MARK: - Transcription
    
    func transcribeMeeting(_ meeting: Meeting, audioURL: URL? = nil) async {
        isProcessing = true
        processingStatus = "Transcribing..."
        
        do {
            let url: URL
            if let audioURL = audioURL {
                url = audioURL
            } else if let bookmarkURL = meeting.audioFileURL {
                url = bookmarkURL
            } else {
                throw MeetingManagerError.noAudioFile
            }
            
            // Transcribe with optional diarization
            let result: TranscriptionResult
            if appSettings?.enableSpeakerDiarization ?? true {
                result = try await transcriptionService.transcribeWithDiarization(audioFileURL: url)
            } else {
                result = try await transcriptionService.transcribe(audioFileURL: url)
            }
            
            // Save segments
            for (index, segment) in result.segments.enumerated() {
                let transcriptSegment = TranscriptSegment(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    speaker: segment.speaker,
                    confidence: segment.confidence,
                    orderIndex: index
                )
                transcriptSegment.meeting = meeting
                modelContext?.insert(transcriptSegment)
            }
            
            meeting.isTranscribed = true
            meeting.updatedAt = Date()
            try? modelContext?.save()
            
            processingStatus = "Transcription complete"
            
            // Auto-summarize if enabled
            if appSettings?.autoSummarize ?? true {
                await summarizeMeeting(meeting)
            }
            
        } catch {
            processingStatus = "Transcription failed: \(error.localizedDescription)"
            print("Transcription failed: \(error)")
        }
        
        isProcessing = false
        
        if !isProcessing {
            sendCompletionNotification(title: meeting.title)
        }
    }
    
    // MARK: - Summarization
    
    func summarizeMeeting(_ meeting: Meeting) async {
        guard !meeting.segments.isEmpty else { return }
        
        isProcessing = true
        processingStatus = "Generating summary..."
        
        do {
            // Build transcript text
            let transcriptText = meeting.segments
                .sorted { $0.orderIndex < $1.orderIndex }
                .map { segment in
                    if let speaker = segment.speaker {
                        return "[\(segment.formattedTimestamp)] \(speaker): \(segment.text)"
                    }
                    return "[\(segment.formattedTimestamp)] \(segment.text)"
                }
                .joined(separator: "\n")
            
            let provider = appSettings?.selectedSummaryProvider ?? .openai
            let openAIKey = KeychainHelper.load(key: "meetrecap_openai_key")
            let claudeKey = KeychainHelper.load(key: "meetrecap_claude_key")
            
            let summaryResult = try await summaryService.generateSummary(
                transcript: transcriptText,
                provider: provider,
                openAIAPIKey: openAIKey,
                claudeAPIKey: claudeKey
            )
            
            // Update meeting
            meeting.summary = summaryResult.summary
            meeting.actionItems = summaryResult.actionItems
            meeting.keyTopics = summaryResult.keyTopics
            meeting.participants = summaryResult.participants
            meeting.isSummarized = true
            meeting.updatedAt = Date()
            try? modelContext?.save()
            
            processingStatus = "Summary complete"
            
        } catch {
            processingStatus = "Summary failed: \(error.localizedDescription)"
            print("Summary generation failed: \(error)")
        }
        
        isProcessing = false
    }
    
    // MARK: - Meeting Management

    func deleteMeeting(_ meeting: Meeting) {
        // Delete audio / screen recording files via the storage manager
        AudioStorageManager.shared.deleteFile(at: meeting.audioFileURL)
        if let path = meeting.audioStoragePath {
            AudioStorageManager.shared.deleteFile(at: URL(fileURLWithPath: path))
        }
        AudioStorageManager.shared.deleteFile(at: meeting.screenRecordingURL)

        modelContext?.delete(meeting)
        try? modelContext?.save()
    }

    func deleteMeetings(_ meetings: [Meeting]) {
        for meeting in meetings {
            deleteMeeting(meeting)
        }
    }

    func renameMeeting(_ meeting: Meeting, newTitle: String) {
        meeting.title = newTitle
        meeting.updatedAt = Date()
        try? modelContext?.save()
    }

    // MARK: - Tagging

    @discardableResult
    func createTag(name: String, colorHex: String = "#007AFF") -> Tag? {
        guard let context = modelContext else { return nil }
        let tag = Tag(name: name, colorHex: colorHex)
        context.insert(tag)
        try? context.save()
        return tag
    }

    func deleteTag(_ tag: Tag) {
        modelContext?.delete(tag)
        try? modelContext?.save()
    }

    func toggleTag(_ tag: Tag, on meeting: Meeting) {
        if let idx = meeting.tags.firstIndex(where: { $0.id == tag.id }) {
            meeting.tags.remove(at: idx)
        } else {
            meeting.tags.append(tag)
        }
        meeting.updatedAt = Date()
        try? modelContext?.save()
    }

    // MARK: - Quick Controls (for hotkeys & autoplay triggers)

    /// Start/stop recording with a single call. Used by global hotkeys.
    func toggleRecording() {
        if audioRecorder.isRecording {
            let audioURL = audioRecorder.stopRecording()
            Task {
                await finishRecording(
                    audioURL: audioURL,
                    screenRecordingURL: nil,
                    duration: audioRecorder.currentDuration
                )
            }
        } else {
            Task {
                if !isTranscriptionReady {
                    await loadTranscriptionModel()
                }
                do {
                    try audioRecorder.startRecording(
                        deviceID: audioDeviceManager.selectedDevice?.id
                    )
                    await startLiveTranscription()
                } catch {
                    print("Failed to start recording: \(error)")
                }
            }
        }
    }
    
    // MARK: - Export
    
    func exportMeeting(_ meeting: Meeting, format: ExportFormat) -> Data {
        let segments = meeting.segments
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { (text: $0.text, startTime: $0.startTime, endTime: $0.endTime, speaker: $0.speaker) }
        
        return ExportManager.exportMeeting(
            title: meeting.title,
            date: meeting.date,
            duration: meeting.duration,
            summary: meeting.summary,
            actionItems: meeting.actionItems,
            segments: segments,
            format: format
        )
    }
    
    // MARK: - Helpers
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: Date())
    }
    
    private func sendCompletionNotification(title: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            
            let content = UNMutableNotificationContent()
            content.title = "MeetRecap"
            content.body = "\(title) — processing complete"
            content.sound = .default
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil  // Deliver immediately
            )
            
            center.add(request)
        }
    }
}

// MARK: - Errors

enum MeetingManagerError: LocalizedError {
    case noAudioFile
    case transcriptionNotReady
    
    var errorDescription: String? {
        switch self {
        case .noAudioFile: return "No audio file available"
        case .transcriptionNotReady: return "Transcription model not loaded"
        }
    }
}
