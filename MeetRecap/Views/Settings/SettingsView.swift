import SwiftUI
import Security
import ServiceManagement
import SwiftData

struct SettingsView: View {
    @ObservedObject var appSettings: AppSettingsStore
    @ObservedObject var transcriptionService: TranscriptionService
    
    @State private var openRouterKey = ""
    @State private var showOpenRouterKey = false
    @State private var saveMessage: String?
    
    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            apiKeysTab
                .tabItem {
                    Label("API Keys", systemImage: "key")
                }

            transcriptionTab
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }

            shortcutsTab
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }

            calendarTab
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

            SpeakerProfilesView(appSettings: appSettings)
                .tabItem {
                    Label("Speakers", systemImage: "person.wave.2")
                }
        }
        .frame(width: 520, height: 420)
        .onAppear {
            loadAPIKeys()
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section {
                Toggle("Enable global shortcuts", isOn: $appSettings.enableGlobalShortcuts)
                    .onChange(of: appSettings.enableGlobalShortcuts) { _, _ in appSettings.save() }
            } footer: {
                Text("Global shortcuts work anywhere on your Mac without requiring Accessibility permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Defaults") {
                ShortcutRow(label: "Toggle recording", keys: "⌘⇧R")
                ShortcutRow(label: "Open dashboard", keys: "⌘⇧D")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Calendar Tab

    private var calendarTab: some View {
        Form {
            Section {
                Toggle("Integrate with Calendar", isOn: $appSettings.enableCalendarIntegration)
                    .onChange(of: appSettings.enableCalendarIntegration) { _, _ in appSettings.save() }

                Stepper(value: $appSettings.preRecordNotificationMinutes, in: 1...30) {
                    Text("Notify \(appSettings.preRecordNotificationMinutes) min before meetings")
                }
                .onChange(of: appSettings.preRecordNotificationMinutes) { _, _ in appSettings.save() }
                .disabled(!appSettings.enableCalendarIntegration)
            } header: {
                Text("Calendar")
            } footer: {
                Text("Polls your calendar every minute for events with video-call links (Zoom, Teams, Meet).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Detect meeting apps (Zoom, Teams, …)", isOn: $appSettings.enableMeetingDetection)
                    .onChange(of: appSettings.enableMeetingDetection) { _, _ in appSettings.save() }
            } header: {
                Text("App Detection")
            } footer: {
                Text("Shows a prompt to record when Zoom, Teams, or similar apps are launched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $appSettings.launchAtLogin)
                    .onChange(of: appSettings.launchAtLogin) { _, newValue in
                        appSettings.save()
                        toggleLaunchAtLogin(enabled: newValue)
                    }
            }
            
            Section("Recording") {
                Toggle("Auto-transcribe recordings", isOn: $appSettings.autoTranscribe)
                    .onChange(of: appSettings.autoTranscribe) { _, _ in appSettings.save() }
                
                Toggle("Auto-generate summaries", isOn: $appSettings.autoSummarize)
                    .onChange(of: appSettings.autoSummarize) { _, _ in appSettings.save() }
                
                Toggle("Speaker diarization", isOn: $appSettings.enableSpeakerDiarization)
                    .onChange(of: appSettings.enableSpeakerDiarization) { _, _ in appSettings.save() }
            }
            
            Section("AI Summary (OpenRouter)") {
                HStack {
                    Text("Model")
                    Spacer()
                    TextField("z-ai/glm-5.1", text: $appSettings.openRouterModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit { appSettings.save() }
                }
                .onChange(of: appSettings.openRouterModel) { _, _ in appSettings.save() }

                Picker("Reasoning effort", selection: $appSettings.selectedReasoningEffort) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }
                .onChange(of: appSettings.selectedReasoningEffort) { _, _ in appSettings.save() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - API Keys Tab
    
    private var apiKeysTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stored in your macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    keyField(
                        label: "OpenRouter API Key",
                        placeholder: "sk-or-...",
                        text: $openRouterKey,
                        isVisible: $showOpenRouterKey
                    )
                    Text("Powers all AI features — summaries, chat, and smart titles. Default model: z-ai/glm-5.1.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("OpenRouter")
            }

            Section {
                Button("Save API Key") {
                    saveAPIKeys()
                }
                .buttonStyle(.borderedProminent)

                if let message = saveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func keyField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Group {
                if isVisible.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
    }
    
    // MARK: - Transcription Tab
    
    private var transcriptionTab: some View {
        Form {
            Section("Parakeet Model") {
                Picker("Model version", selection: $appSettings.selectedParakeetVersion) {
                    ForEach(ParakeetVersion.allCases, id: \.self) { version in
                        Text(version.displayName).tag(version)
                    }
                }
                .onChange(of: appSettings.selectedParakeetVersion) { _, newValue in
                    appSettings.save()
                    Task {
                        try? await transcriptionService.loadModel(version: newValue)
                    }
                }
                
                HStack {
                    Text("Status")
                    Spacer()
                    switch transcriptionService.state {
                    case .idle:
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .loadingModel:
                        Label("Loading...", systemImage: "arrow.clockwise")
                            .foregroundStyle(.orange)
                    case .downloadingModel(let progress):
                        Label("Downloading \(Int(progress * 100))%", systemImage: "arrow.down.circle")
                            .foregroundStyle(.blue)
                    case .failed(let error):
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    default:
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("About") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parakeet TDT runs on Apple Neural Engine (ANE)")
                        .font(.caption)
                    Text("~190x realtime speed | ~66MB memory | 25 languages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Powered by FluidAudio (github.com/FluidInference/FluidAudio)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Keychain Helpers
    
    private func loadAPIKeys() {
        openRouterKey = KeychainHelper.load(key: "meetrecap_openrouter_key") ?? ""
    }

    private func saveAPIKeys() {
        if !openRouterKey.isEmpty {
            KeychainHelper.save(key: "meetrecap_openrouter_key", value: openRouterKey)
        }
        saveMessage = "API key saved to Keychain"

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveMessage = nil
        }
    }
    
    private func toggleLaunchAtLogin(enabled: Bool) {
        // Uses SMAppService for macOS 13+
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Shortcut Row Helper

struct ShortcutRow: View {
    let label: String
    let keys: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(keys)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

// MARK: - App Settings Store (Observable wrapper)

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var parakeetVersion: String
    @Published var openRouterModel: String
    @Published var reasoningEffort: String
    @Published var autoTranscribe: Bool
    @Published var autoSummarize: Bool
    @Published var launchAtLogin: Bool
    @Published var enableSpeakerDiarization: Bool
    @Published var enableGlobalShortcuts: Bool
    @Published var enableCalendarIntegration: Bool
    @Published var enableMeetingDetection: Bool
    @Published var preRecordNotificationMinutes: Int
    @Published var speakerMatchThreshold: Double
    @Published var useNativeSystemAudio: Bool

    private var modelContext: ModelContext?
    
    var selectedParakeetVersion: ParakeetVersion {
        get { ParakeetVersion(rawValue: parakeetVersion) ?? .v3 }
        set { parakeetVersion = newValue.rawValue }
    }

    var selectedReasoningEffort: ReasoningEffort {
        get { ReasoningEffort(rawValue: reasoningEffort) ?? .low }
        set { reasoningEffort = newValue.rawValue }
    }
    
    init() {
        self.parakeetVersion = ParakeetVersion.v3.rawValue
        self.openRouterModel = "z-ai/glm-5.1"
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
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        loadFromStore()
    }
    
    private func loadFromStore() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        if let settings = try? context.fetch(descriptor).first {
            parakeetVersion = settings.parakeetVersion
            openRouterModel = settings.openRouterModel
            reasoningEffort = settings.reasoningEffort
            autoTranscribe = settings.autoTranscribe
            autoSummarize = settings.autoSummarize
            launchAtLogin = settings.launchAtLogin
            enableSpeakerDiarization = settings.enableSpeakerDiarization
            enableGlobalShortcuts = settings.enableGlobalShortcuts
            enableCalendarIntegration = settings.enableCalendarIntegration
            enableMeetingDetection = settings.enableMeetingDetection
            preRecordNotificationMinutes = settings.preRecordNotificationMinutes
            speakerMatchThreshold = settings.speakerMatchThreshold
            useNativeSystemAudio = settings.useNativeSystemAudio
        }
    }
    
    func save() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<AppSettings>()
        let settings: AppSettings
        if let existing = try? context.fetch(descriptor).first {
            settings = existing
        } else {
            settings = AppSettings()
            context.insert(settings)
        }
        
        settings.parakeetVersion = parakeetVersion
        settings.openRouterModel = openRouterModel
        settings.reasoningEffort = reasoningEffort
        settings.autoTranscribe = autoTranscribe
        settings.autoSummarize = autoSummarize
        settings.launchAtLogin = launchAtLogin
        settings.enableSpeakerDiarization = enableSpeakerDiarization
        settings.enableGlobalShortcuts = enableGlobalShortcuts
        settings.enableCalendarIntegration = enableCalendarIntegration
        settings.enableMeetingDetection = enableMeetingDetection
        settings.preRecordNotificationMinutes = preRecordNotificationMinutes
        settings.speakerMatchThreshold = speakerMatchThreshold
        settings.useNativeSystemAudio = useNativeSystemAudio
        settings.updatedAt = Date()
        
        try? context.save()
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
