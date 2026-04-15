import Foundation
import Combine
import FluidAudio

enum TranscriptionState: Equatable {
    case idle
    case downloadingModel(progress: Double)
    case loadingModel
    case transcribing(progress: Double?)
    case diarizing
    case completed
    case failed(String)
    
    static func == (lhs: TranscriptionState, rhs: TranscriptionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loadingModel, .loadingModel), (.diarizing, .diarizing), (.completed, .completed):
            return true
        case (.downloadingModel(let a), .downloadingModel(let b)):
            return a == b
        case (.transcribing(let a), .transcribing(let b)):
            return a == b
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct TranscriptionResult {
    let segments: [TranscriptResultSegment]
    let fullText: String
    let duration: TimeInterval
    /// Speaker ID → L2-normalized 256-dim voice embedding. Only populated when
    /// diarization ran successfully.
    let speakerEmbeddings: [String: [Float]]?

    init(
        segments: [TranscriptResultSegment],
        fullText: String,
        duration: TimeInterval,
        speakerEmbeddings: [String: [Float]]? = nil
    ) {
        self.segments = segments
        self.fullText = fullText
        self.duration = duration
        self.speakerEmbeddings = speakerEmbeddings
    }
}

struct TranscriptResultSegment {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let confidence: Float
}

@MainActor
final class TranscriptionService: ObservableObject {
    @Published var state: TranscriptionState = .idle
    
    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private let audioConverter = MeetRecap.AudioConverter()
    
    private var parakeetVersion: ParakeetVersion = .v3

    /// Currently loaded ASR models, if any. Exposed so services such as
    /// `StreamingTranscriptionService` can reuse the already-downloaded models.
    var loadedModels: AsrModels? { asrModels }

    init() {}
    
    // MARK: - Model Management
    
    func loadModel(version: ParakeetVersion = .v3) async throws {
        self.parakeetVersion = version
        state = .loadingModel
        
        do {
            let modelVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
            let models = try await AsrModels.downloadAndLoad(version: modelVersion)
            
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            
            self.asrManager = manager
            self.asrModels = models
            state = .idle
        } catch {
            state = .failed("Failed to load model: \(error.localizedDescription)")
            throw error
        }
    }
    
    func isModelLoaded() -> Bool {
        return asrManager != nil
    }
    
    // MARK: - Transcription
    
    /// Transcribe an audio file and return segments with timestamps
    func transcribe(audioFileURL: URL) async throws -> TranscriptionResult {
        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }
        
        state = .transcribing(progress: nil)
        
        // Convert audio to 16kHz mono float samples
        let samples = try audioConverter.resampleAudioFile(audioFileURL)
        
        // Get duration
        let duration = AudioConverter.duration(of: audioFileURL) ?? 0
        
        // Run ASR
        let result = try await manager.transcribe(samples)
        
        // Convert token timings to sentence-like segments
        // Group tokens into ~10-second segments for readability
        var segments: [TranscriptResultSegment] = []
        
        if let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty {
            segments = groupTokensIntoSegments(
                tokens: tokenTimings,
                fullText: result.text
            )
        } else {
            // Fallback: single segment with full text
            segments = [TranscriptResultSegment(
                text: result.text,
                startTime: 0,
                endTime: duration,
                speaker: nil,
                confidence: result.confidence
            )]
        }
        
        state = .completed
        
        return TranscriptionResult(
            segments: segments,
            fullText: result.text,
            duration: duration
        )
    }
    
    /// Transcribe with speaker diarization
    func transcribeWithDiarization(audioFileURL: URL) async throws -> TranscriptionResult {
        // First transcribe
        var result = try await transcribe(audioFileURL: audioFileURL)
        
        state = .diarizing
        
        // Then diarize
        do {
            let diarizer = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await diarizer.prepareModels()
            
            let samples = try audioConverter.resampleAudioFile(audioFileURL)
            let diarizationResult = try await diarizer.process(audio: samples)
            
            // Map speakers to transcript segments
            var diarizedSegments: [TranscriptResultSegment] = []

            for segment in result.segments {
                // Find matching speaker from diarization
                let speaker = findSpeaker(
                    for: segment.startTime,
                    endTime: segment.endTime,
                    in: diarizationResult.segments
                )

                diarizedSegments.append(TranscriptResultSegment(
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    speaker: speaker,
                    confidence: segment.confidence
                ))
            }

            result = TranscriptionResult(
                segments: diarizedSegments,
                fullText: result.fullText,
                duration: result.duration,
                speakerEmbeddings: diarizationResult.speakerDatabase
            )
        } catch {
            // Diarization failed, return transcription without speakers
            print("Diarization failed: \(error). Returning transcript without speakers.")
        }
        
        state = .completed
        return result
    }
    
    /// Transcribe from raw float samples (for streaming use)
    func transcribeSamples(_ samples: [Float]) async throws -> TranscriptionResult {
        guard let manager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }
        
        state = .transcribing(progress: nil)
        
        let result = try await manager.transcribe(samples)
        
        let duration = Double(samples.count) / 16000.0
        
        var segments: [TranscriptResultSegment] = []
        if let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty {
            segments = groupTokensIntoSegments(tokens: tokenTimings, fullText: result.text)
        } else {
            segments = [TranscriptResultSegment(
                text: result.text,
                startTime: 0,
                endTime: duration,
                speaker: nil,
                confidence: result.confidence
            )]
        }
        
        state = .completed
        
        return TranscriptionResult(
            segments: segments,
            fullText: result.text,
            duration: duration
        )
    }
    
    // MARK: - Helpers
    
    /// Group token timings into readable sentence-like segments
    private func groupTokensIntoSegments(
        tokens: [TokenTiming],
        fullText: String
    ) -> [TranscriptResultSegment] {
        var segments: [TranscriptResultSegment] = []
        var currentTokens: [TokenTiming] = []
        var segmentStart: TimeInterval = tokens.first?.startTime ?? 0
        
        let maxSegmentDuration: TimeInterval = 15.0 // Group into ~15 second segments
        
        for token in tokens {
            currentTokens.append(token)
            
            let segmentDuration = token.endTime - segmentStart
            
            // Split on sentence-ending punctuation or after max duration
            if segmentDuration >= maxSegmentDuration ||
               token.token.contains(".") || token.token.contains("!") || token.token.contains("?") {
                let text = currentTokens
                    .map { $0.token }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } // Remove empty tokens
                    .joined(separator: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "  +", with: " ", options: .regularExpression) // Fix double spaces
                let avgConfidence = currentTokens.reduce(0.0) { $0 + $1.confidence } / Float(currentTokens.count)
                
                if !text.isEmpty {
                    segments.append(TranscriptResultSegment(
                        text: text,
                        startTime: segmentStart,
                        endTime: token.endTime,
                        speaker: nil,
                        confidence: avgConfidence
                    ))
                }
                
                currentTokens = []
                segmentStart = token.endTime
            }
        }
        
        // Remaining tokens
        if !currentTokens.isEmpty {
            let text = currentTokens
                .map { $0.token }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } // Remove empty tokens
                .joined(separator: "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression) // Fix double spaces
            let avgConfidence = currentTokens.reduce(0.0) { $0 + $1.confidence } / Float(currentTokens.count)
            
            if !text.isEmpty {
                segments.append(TranscriptResultSegment(
                    text: text,
                    startTime: segmentStart,
                    endTime: currentTokens.last?.endTime ?? segmentStart,
                    speaker: nil,
                    confidence: avgConfidence
                ))
            }
        }
        
        return segments
    }
    
    private func findSpeaker(
        for startTime: TimeInterval,
        endTime: TimeInterval,
        in diarizationSegments: [TimedSpeakerSegment]
    ) -> String? {
        let midpoint = (startTime + endTime) / 2.0
        
        // Find the diarization segment that contains the midpoint
        for seg in diarizationSegments {
            if Float(midpoint) >= seg.startTimeSeconds && Float(midpoint) <= seg.endTimeSeconds {
                return seg.speakerId
            }
        }
        
        // Find nearest segment
        var nearest: TimedSpeakerSegment?
        var nearestDistance: Double = .greatestFiniteMagnitude
        
        for seg in diarizationSegments {
            let segMid = Double(seg.startTimeSeconds + seg.endTimeSeconds) / 2.0
            let distance = abs(midpoint - segMid)
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = seg
            }
        }
        
        return nearest?.speakerId
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)
    case invalidAudio
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Transcription model is not loaded"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .invalidAudio:
            return "Invalid audio data"
        }
    }
}
