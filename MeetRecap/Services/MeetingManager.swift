import Foundation
import SwiftData
import Combine
import UserNotifications
import AVFoundation

@MainActor
final class MeetingManager: ObservableObject {
    @Published var isTranscriptionReady = false
    @Published var isProcessing = false
    @Published var processingStatus = ""

    let audioRecorder: AudioRecorder
    let systemAudioRecorder: SystemAudioRecorder
    let screenRecorder: ScreenRecorder
    let transcriptionService: TranscriptionService
    let summaryService: SummaryService
    let audioDeviceManager: AudioDeviceManager
    let audioPlayback: AudioPlaybackService
    let streamingTranscription: StreamingTranscriptionService
    let speakerProfileService: SpeakerProfileService

    /// True when the active recording is using the native system-audio path
    /// (vs microphone).  Decides which recorder `stopCurrentRecording` talks to.
    private var usingSystemAudio: Bool = false

    /// Is a recording currently in progress, regardless of source?
    var isAnyRecording: Bool {
        audioRecorder.isRecording || systemAudioRecorder.isRecording
    }

    /// Current duration, regardless of source.
    var currentRecordingDuration: TimeInterval {
        audioRecorder.isRecording ? audioRecorder.currentDuration : systemAudioRecorder.currentDuration
    }

    /// Speaker embeddings from the most recent transcription, keyed by raw speaker ID
    /// (e.g. "Speaker 1"). Used when the user opts to remember a voice.
    private var pendingSpeakerEmbeddings: [String: [Float]] = [:]

    /// Calendar event that was active when the current recording started, if any.
    /// Used to auto-title meetings on finishRecording.
    private var activeCalendarContext: CalendarIntegrationService.UpcomingEvent?

    /// Weak reference to the calendar service so `toggleRecording` can pull the
    /// most relevant upcoming event at start-time.
    weak var calendarServiceRef: CalendarIntegrationService?

    /// Consume and return the active calendar context — clears it from memory.
    func consumeActiveCalendarContext() -> CalendarIntegrationService.UpcomingEvent? {
        let context = activeCalendarContext
        activeCalendarContext = nil
        return context
    }

    // Expose transcription service state for UI
    var transcriptionState: TranscriptionState {
        transcriptionService.state
    }
    
    private var modelContext: ModelContext?
    private var appSettings: AppSettingsStore?
    
    init() {
        self.audioRecorder = AudioRecorder()
        self.systemAudioRecorder = SystemAudioRecorder()
        self.screenRecorder = ScreenRecorder()
        self.transcriptionService = TranscriptionService()
        self.summaryService = SummaryService()
        self.audioDeviceManager = AudioDeviceManager()
        self.audioPlayback = AudioPlaybackService()
        self.streamingTranscription = StreamingTranscriptionService()
        self.speakerProfileService = SpeakerProfileService()
    }
    
    func configure(modelContext: ModelContext, appSettings: AppSettingsStore) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.speakerProfileService.configure(modelContext: modelContext)
        self.speakerProfileService.matchThreshold = Float(appSettings.speakerMatchThreshold)

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

    // MARK: - Unified Recording Start/Stop

    /// Start recording using the source currently configured in settings.
    /// System-audio path is used when `useNativeSystemAudio` is true AND available;
    /// otherwise falls back to the microphone path.
    func startRecording() async throws {
        let wantsSystemAudio = appSettings?.useNativeSystemAudio ?? false
        if wantsSystemAudio && SystemAudioRecorder.isAvailable {
            usingSystemAudio = true
            try await systemAudioRecorder.startRecording()
        } else {
            usingSystemAudio = false
            try audioRecorder.startRecording(deviceID: audioDeviceManager.selectedDevice?.id)
        }
        await startLiveTranscription()
    }

    /// Stop whichever recorder is running and return the resulting audio URL + duration.
    func stopRecording() async -> (URL?, TimeInterval) {
        if usingSystemAudio && systemAudioRecorder.isRecording {
            let duration = systemAudioRecorder.currentDuration
            let url = await systemAudioRecorder.stopRecording()
            usingSystemAudio = false
            return (url, duration)
        } else if audioRecorder.isRecording {
            let duration = audioRecorder.currentDuration
            let url = audioRecorder.stopRecording()
            return (url, duration)
        }
        return (nil, 0)
    }

    /// Start a live-streaming transcription session that runs alongside the
    /// normal file-based recording. Call after the audio tap is installed.
    func startLiveTranscription() async {
        // Snapshot any upcoming calendar event so the meeting gets auto-titled on stop.
        activeCalendarContext = calendarServiceRef?.upcomingEvents
            .min(by: { $0.startDate < $1.startDate })

        guard let models = transcriptionService.loadedModels else { return }

        // Forward tap buffers into the sliding-window manager from whichever recorder is active.
        let streaming = streamingTranscription
        let forward: (AVAudioPCMBuffer) -> Void = { buffer in
            streaming.appendBuffer(buffer)
        }
        if usingSystemAudio {
            systemAudioRecorder.onAudioBuffer = forward
        } else {
            audioRecorder.onAudioBuffer = forward
        }

        await streaming.start(models: models)
    }

    /// Called when recording stops. Triggers post-processing pipeline.
    /// - Parameter calendarContext: Optional calendar event that was active when the recording started.
    ///   Used to auto-title the meeting and link it back to the calendar event.
    func finishRecording(
        audioURL: URL?,
        screenRecordingURL: URL?,
        duration: TimeInterval,
        calendarContext: CalendarIntegrationService.UpcomingEvent? = nil
    ) async {
        // Tear down live streaming — full-file transcription replaces it below.
        audioRecorder.onAudioBuffer = nil
        streamingTranscription.stop()

        guard let audioURL = audioURL else { return }

        // Prefer the active calendar event's title over a timestamp-based fallback.
        let title = calendarContext?.title ?? "Meeting \(formattedDate())"

        let meeting = Meeting(
            title: title,
            date: Date(),
            duration: duration
        )
        meeting.calendarEventIdentifier = calendarContext?.id
        
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

            // Speaker profile matching — auto-label known voices.
            if let embeddings = result.speakerEmbeddings, !embeddings.isEmpty {
                pendingSpeakerEmbeddings = embeddings
                let matches = speakerProfileService.matchSpeakers(meetingEmbeddings: embeddings)
                if !matches.isEmpty {
                    speakerProfileService.applyMatches(matches, to: meeting)
                }
            } else {
                pendingSpeakerEmbeddings = [:]
            }

            // Text embeddings — best-effort, won't block the pipeline if key is missing.
            await embedSegmentsIfPossible(meeting: meeting)
            
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

    // MARK: - Embeddings

    /// Embed each transcript segment so it can be used for semantic search and chat.
    /// Silently skips if no OpenAI API key is configured — the feature is optional.
    private func embedSegmentsIfPossible(meeting: Meeting) async {
        guard let key = KeychainHelper.load(key: "meetrecap_openai_key"), !key.isEmpty else {
            return
        }

        let sorted = meeting.segments.sorted { $0.orderIndex < $1.orderIndex }
        let needsEmbedding = sorted.filter { $0.embeddingData == nil && !$0.text.isEmpty }
        guard !needsEmbedding.isEmpty else { return }

        do {
            processingStatus = "Building semantic index…"
            let texts = needsEmbedding.map { $0.text }
            let vectors = try await EmbeddingService.shared.embed(texts, apiKey: key)
            guard vectors.count == needsEmbedding.count else { return }
            for (segment, vector) in zip(needsEmbedding, vectors) {
                segment.embeddingData = EmbeddingCoding.encode(vector)
            }
            try? modelContext?.save()
        } catch {
            print("[MeetingManager] Segment embedding failed: \(error)")
        }
    }

    // MARK: - Speaker Profiles

    /// Create or update a SpeakerProfile for the given speaker label on a meeting.
    /// Uses the last-stored embeddings from the most recent transcription.
    @discardableResult
    func rememberSpeaker(rawLabel: String, as name: String, on meeting: Meeting) -> SpeakerProfile? {
        // Prefer freshly-computed embeddings from this run.
        if let embedding = pendingSpeakerEmbeddings[rawLabel] {
            let profile = speakerProfileService.createOrUpdateProfile(name: name, embedding: embedding)
            if let profile = profile {
                for segment in meeting.segments where segment.speaker == rawLabel {
                    segment.speaker = name
                    segment.speakerProfileID = profile.id
                }
                try? modelContext?.save()
            }
            return profile
        }

        // Fallback: if we don't have fresh embeddings, still rename on this meeting.
        for segment in meeting.segments where segment.speaker == rawLabel {
            segment.speaker = name
        }
        try? modelContext?.save()
        return nil
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
        Task {
            if isAnyRecording {
                let (audioURL, duration) = await stopRecording()
                let context = consumeActiveCalendarContext()
                await finishRecording(
                    audioURL: audioURL,
                    screenRecordingURL: nil,
                    duration: duration,
                    calendarContext: context
                )
            } else {
                if !isTranscriptionReady {
                    await loadTranscriptionModel()
                }
                do {
                    try await startRecording()
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
