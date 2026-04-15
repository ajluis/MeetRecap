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

enum SummaryProvider: String, Codable, CaseIterable {
    case openai = "openai"
    case claude = "claude"
    
    var displayName: String {
        switch self {
        case .openai: return "OpenAI (GPT-4o)"
        case .claude: return "Claude (Sonnet)"
        }
    }
}

@Model
final class AppSettings {
    @Attribute(.unique) var id: String
    var parakeetVersion: String  // ParakeetVersion rawValue
    var summaryProvider: String  // SummaryProvider rawValue
    var autoTranscribe: Bool
    var autoSummarize: Bool
    var launchAtLogin: Bool
    var enableSpeakerDiarization: Bool
    var createdAt: Date
    var updatedAt: Date
    
    init() {
        self.id = "app_settings"
        self.parakeetVersion = ParakeetVersion.v3.rawValue
        self.summaryProvider = SummaryProvider.openai.rawValue
        self.autoTranscribe = true
        self.autoSummarize = true
        self.launchAtLogin = false
        self.enableSpeakerDiarization = true
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    var selectedParakeetVersion: ParakeetVersion {
        get { ParakeetVersion(rawValue: parakeetVersion) ?? .v3 }
        set { parakeetVersion = newValue.rawValue }
    }
    
    var selectedSummaryProvider: SummaryProvider {
        get { SummaryProvider(rawValue: summaryProvider) ?? .openai }
        set { summaryProvider = newValue.rawValue }
    }
}
