import Foundation
import SwiftData

enum ParakeetVersion: String, Codable, CaseIterable {
    case v2 = "v2"  // English-only, higher recall
    case v3 = "v3"  // Multilingual, 25 European languages

    var displayName: String {
        switch self {
        case .v2: return "Parakeet v2 (English only)"
        case .v3: return "Parakeet v3 (25 languages)"
        }
    }

    var modelId: String {
        switch self {
        case .v2: return "FluidInference/parakeet-tdt-0.6b-v2-coreml"
        case .v3: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }
}

/// Selects where transcription runs. Cloud is the default — instant startup, no
/// model download, $0.04/hr via Groq Whisper v3 Turbo. Local keeps the offline
/// FluidAudio path for users who prefer on-device processing.
enum TranscriptionMode: String, Codable, CaseIterable, Identifiable {
    case cloud
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloud: return "Cloud (Groq Whisper)"
        case .local: return "On-device (Parakeet)"
        }
    }

    var tagline: String {
        switch self {
        case .cloud: return "Fast, no model download. Needs internet and a Groq API key."
        case .local: return "Runs entirely offline on Apple Neural Engine. First load downloads the model."
        }
    }
}

/// Supported reasoning efforts passed through OpenRouter's `reasoning.effort` field.
/// `low` is the default — it keeps latency + cost down while still giving GLM the benefit of
/// chain-of-thought on hard questions.
enum ReasoningEffort: String, Codable, CaseIterable {
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low (recommended)"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

@Model
final class AppSettings {
    @Attribute(.unique) var id: String
    var parakeetVersion: String  // ParakeetVersion rawValue
    var openRouterModel: String  // e.g. "z-ai/glm-5.1"
    var reasoningEffort: String  // ReasoningEffort rawValue
    var transcriptionMode: String  // TranscriptionMode rawValue
    var autoTranscribe: Bool
    var autoSummarize: Bool
    var launchAtLogin: Bool
    var enableSpeakerDiarization: Bool
    var enableGlobalShortcuts: Bool
    var enableCalendarIntegration: Bool
    var enableMeetingDetection: Bool
    var preRecordNotificationMinutes: Int
    var speakerMatchThreshold: Double
    var useNativeSystemAudio: Bool
    var hasCompletedOnboarding: Bool
    var createdAt: Date
    var updatedAt: Date

    init() {
        self.id = "app_settings"
        self.parakeetVersion = ParakeetVersion.v3.rawValue
        self.openRouterModel = "z-ai/glm-5.1"
        self.reasoningEffort = ReasoningEffort.low.rawValue
        self.transcriptionMode = TranscriptionMode.cloud.rawValue
        self.autoTranscribe = true
        self.autoSummarize = true
        self.launchAtLogin = false
        self.enableSpeakerDiarization = false
        self.enableGlobalShortcuts = true
        self.enableCalendarIntegration = false
        self.enableMeetingDetection = false
        self.preRecordNotificationMinutes = 2
        self.speakerMatchThreshold = 0.85
        self.useNativeSystemAudio = false
        self.hasCompletedOnboarding = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var selectedParakeetVersion: ParakeetVersion {
        get { ParakeetVersion(rawValue: parakeetVersion) ?? .v3 }
        set { parakeetVersion = newValue.rawValue }
    }

    var selectedReasoningEffort: ReasoningEffort {
        get { ReasoningEffort(rawValue: reasoningEffort) ?? .low }
        set { reasoningEffort = newValue.rawValue }
    }

    var selectedTranscriptionMode: TranscriptionMode {
        get { TranscriptionMode(rawValue: transcriptionMode) ?? .cloud }
        set { transcriptionMode = newValue.rawValue }
    }
}
