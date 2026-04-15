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
    var openRouterModel: String  // e.g. "z-ai/glm-4.6"
    var reasoningEffort: String  // ReasoningEffort rawValue
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
    var createdAt: Date
    var updatedAt: Date

    init() {
        self.id = "app_settings"
        self.parakeetVersion = ParakeetVersion.v3.rawValue
        self.openRouterModel = "z-ai/glm-4.6"
        self.reasoningEffort = ReasoningEffort.low.rawValue
        self.autoTranscribe = true
        self.autoSummarize = true
        self.launchAtLogin = false
        self.enableSpeakerDiarization = true
        self.enableGlobalShortcuts = true
        self.enableCalendarIntegration = false
        self.enableMeetingDetection = false
        self.preRecordNotificationMinutes = 2
        self.speakerMatchThreshold = 0.85
        self.useNativeSystemAudio = false
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
}
