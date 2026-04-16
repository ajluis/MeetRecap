import SwiftUI
import Security
import ServiceManagement
import SwiftData

struct SettingsView: View {
    @ObservedObject var appSettings: AppSettingsStore
    @ObservedObject var transcriptionService: TranscriptionService
    var meetingManager: MeetingManager?

    @State private var section: SettingsSection = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, apiKeys, transcription, ai, shortcuts, calendar, speakers, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .apiKeys: return "API Keys"
            case .transcription: return "Transcription"
            case .ai: return "AI & Summaries"
            case .shortcuts: return "Shortcuts"
            case .calendar: return "Calendar"
            case .speakers: return "Speakers"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .apiKeys: return "key.horizontal"
            case .transcription: return "waveform"
            case .ai: return "sparkles"
            case .shortcuts: return "command"
            case .calendar: return "calendar"
            case .speakers: return "person.wave.2"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case .general:       GeneralPane(appSettings: appSettings)
                    case .apiKeys:       APIKeysPane(transcriptionService: transcriptionService)
                    case .transcription: TranscriptionPane(
                        appSettings: appSettings,
                        transcriptionService: transcriptionService,
                        meetingManager: meetingManager
                    )
                    case .ai:            AIPane(appSettings: appSettings)
                    case .shortcuts:     ShortcutsPane(appSettings: appSettings)
                    case .calendar:      CalendarPane(appSettings: appSettings)
                    case .speakers:      SpeakerProfilesView(appSettings: appSettings)
                    case .about:         AboutPane()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle(section.title)
        }
        .frame(minWidth: 760, minHeight: 540)
    }
}

// MARK: - General pane

private struct GeneralPane: View {
    @ObservedObject var appSettings: AppSettingsStore

    var body: some View {
        PaneHeader(title: "General", subtitle: "How MeetRecap launches and handles recordings.")

        SettingsCard(title: "Startup") {
            ToggleRow(
                title: "Launch at login",
                subtitle: "Open MeetRecap automatically when you sign in.",
                isOn: Binding(
                    get: { appSettings.launchAtLogin },
                    set: { newValue in
                        appSettings.launchAtLogin = newValue
                        appSettings.save()
                        toggleLaunchAtLogin(enabled: newValue)
                    }
                )
            )
        }

        SettingsCard(title: "Recording") {
            ToggleRow(
                title: "Auto-transcribe recordings",
                subtitle: "Run transcription as soon as a recording stops.",
                isOn: $appSettings.autoTranscribe
            )
            .onChange(of: appSettings.autoTranscribe) { _, _ in appSettings.save() }

            Divider().opacity(0.4)

            ToggleRow(
                title: "Auto-generate summaries",
                subtitle: "Kick off an OpenRouter summary after transcription.",
                isOn: $appSettings.autoSummarize
            )
            .onChange(of: appSettings.autoSummarize) { _, _ in appSettings.save() }
        }
    }

    private func toggleLaunchAtLogin(enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - API Keys pane

private struct APIKeysPane: View {
    @ObservedObject var transcriptionService: TranscriptionService

    @State private var groqKey = ""
    @State private var showGroq = false
    @State private var groqResult: TestState = .idle

    @State private var openRouterKey = ""
    @State private var showRouter = false
    @State private var routerResult: TestState = .idle

    @State private var savedBanner: String?

    enum TestState { case idle, testing, ok, fail(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PaneHeader(
                title: "API Keys",
                subtitle: "Keys are stored in your macOS Keychain. MeetRecap only sends requests from your Mac."
            )

            SettingsCard(
                title: "Groq — Transcription",
                subtitle: "Powers cloud transcription (Whisper v3 Turbo). Get a free key from console.groq.com."
            ) {
                KeyFieldRow(
                    placeholder: "gsk_...",
                    text: $groqKey,
                    isVisible: $showGroq
                )

                HStack(spacing: 10) {
                    Button {
                        Task { await testGroq() }
                    } label: {
                        HStack(spacing: 6) {
                            if case .testing = groqResult { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checkmark.shield") }
                            Text("Test connection")
                        }
                    }
                    .buttonStyle(.bordered)

                    Link(destination: URL(string: "https://console.groq.com/keys")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Get a key")
                        }
                        .font(.system(size: 12))
                    }

                    Spacer()

                    testBadge(groqResult)
                }
            }

            SettingsCard(
                title: "OpenRouter — Summaries & Chat",
                subtitle: "Powers summaries, action-item extraction, and chat-with-meeting."
            ) {
                KeyFieldRow(
                    placeholder: "sk-or-...",
                    text: $openRouterKey,
                    isVisible: $showRouter
                )

                HStack(spacing: 10) {
                    Button {
                        Task { await testOpenRouter() }
                    } label: {
                        HStack(spacing: 6) {
                            if case .testing = routerResult { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checkmark.shield") }
                            Text("Test connection")
                        }
                    }
                    .buttonStyle(.bordered)

                    Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Get a key")
                        }
                        .font(.system(size: 12))
                    }

                    Spacer()

                    testBadge(routerResult)
                }
            }

            HStack {
                Spacer()
                Button("Save") { saveAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            if let savedBanner = savedBanner {
                Label(savedBanner, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .onAppear {
            groqKey = KeychainHelper.load(key: "meetrecap_groq_key") ?? ""
            openRouterKey = KeychainHelper.load(key: "meetrecap_openrouter_key") ?? ""
        }
    }

    @ViewBuilder
    private func testBadge(_ state: TestState) -> some View {
        switch state {
        case .idle, .testing:
            EmptyView()
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .fail(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func saveAll() {
        if !groqKey.isEmpty {
            KeychainHelper.save(key: "meetrecap_groq_key", value: groqKey)
        } else {
            KeychainHelper.delete(key: "meetrecap_groq_key")
        }
        if !openRouterKey.isEmpty {
            KeychainHelper.save(key: "meetrecap_openrouter_key", value: openRouterKey)
        } else {
            KeychainHelper.delete(key: "meetrecap_openrouter_key")
        }
        withAnimation { savedBanner = "Keys saved to Keychain" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { savedBanner = nil }
        }
    }

    private func testGroq() async {
        guard !groqKey.isEmpty else {
            groqResult = .fail("Enter a key first")
            return
        }
        KeychainHelper.save(key: "meetrecap_groq_key", value: groqKey)
        groqResult = .testing
        switch await transcriptionService.cloudService.testConnection() {
        case .success: groqResult = .ok
        case .failure(let e): groqResult = .fail(e.localizedDescription)
        }
    }

    private func testOpenRouter() async {
        guard !openRouterKey.isEmpty else {
            routerResult = .fail("Enter a key first")
            return
        }
        KeychainHelper.save(key: "meetrecap_openrouter_key", value: openRouterKey)
        routerResult = .testing
        switch await OpenRouterPing.test(apiKey: openRouterKey) {
        case .success: routerResult = .ok
        case .failure(let e): routerResult = .fail(e.localizedDescription)
        }
    }
}

// MARK: - Transcription pane

private struct TranscriptionPane: View {
    @ObservedObject var appSettings: AppSettingsStore
    @ObservedObject var transcriptionService: TranscriptionService
    var meetingManager: MeetingManager?

    var body: some View {
        PaneHeader(
            title: "Transcription",
            subtitle: "Choose where your audio is processed."
        )

        SettingsCard(title: "Mode") {
            ForEach(TranscriptionMode.allCases) { mode in
                TranscriptionModeRow(
                    mode: mode,
                    isSelected: appSettings.selectedTranscriptionMode == mode,
                    onSelect: {
                        appSettings.selectedTranscriptionMode = mode
                        appSettings.save()
                        Task { await meetingManager?.updateTranscriptionMode(mode) }
                    }
                )
                if mode != TranscriptionMode.allCases.last {
                    Divider().opacity(0.4)
                }
            }
        }

        if appSettings.selectedTranscriptionMode == .local {
            SettingsCard(
                title: "On-device Model",
                subtitle: "FluidAudio Parakeet TDT runs on Apple Neural Engine."
            ) {
                HStack {
                    Text("Model version")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appSettings.selectedParakeetVersion },
                        set: { newValue in
                            appSettings.selectedParakeetVersion = newValue
                            appSettings.save()
                            Task { try? await transcriptionService.loadModel(version: newValue) }
                        }
                    )) {
                        ForEach(ParakeetVersion.allCases, id: \.self) { version in
                            Text(version.displayName).tag(version)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                Divider().opacity(0.4)

                HStack {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    statusBadge
                }

                Divider().opacity(0.4)

                ToggleRow(
                    title: "Speaker diarization",
                    subtitle: "Tag who spoke each segment. Local-only feature.",
                    isOn: $appSettings.enableSpeakerDiarization
                )
                .onChange(of: appSettings.enableSpeakerDiarization) { _, _ in appSettings.save() }
            }
        } else {
            SettingsCard(
                title: "Cloud details",
                subtitle: "Groq Whisper large-v3-turbo, ~$0.04/hour, audio uploaded over HTTPS."
            ) {
                DetailRow(label: "Provider", value: "Groq")
                Divider().opacity(0.4)
                DetailRow(label: "Model", value: "whisper-large-v3-turbo")
                Divider().opacity(0.4)
                DetailRow(label: "Pricing", value: "$0.04 per hour of audio")
                Divider().opacity(0.4)
                DetailRow(label: "Upload limit", value: "25 MB per file (auto-compressed)")
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch transcriptionService.state {
        case .idle, .completed:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loadingModel:
            Label("Loading…", systemImage: "arrow.clockwise").foregroundStyle(.orange)
        case .downloadingModel(let p):
            Label("Downloading \(Int(p * 100))%", systemImage: "arrow.down.circle").foregroundStyle(.blue)
        case .uploading:
            Label("Uploading", systemImage: "arrow.up.circle").foregroundStyle(.blue)
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform").foregroundStyle(.blue)
        case .diarizing:
            Label("Diarizing…", systemImage: "person.wave.2").foregroundStyle(.blue)
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
        }
    }
}

// MARK: - AI pane

private struct AIPane: View {
    @ObservedObject var appSettings: AppSettingsStore

    var body: some View {
        PaneHeader(
            title: "AI & Summaries",
            subtitle: "OpenRouter model used to generate summaries and power chat."
        )

        SettingsCard(title: "Model") {
            HStack {
                Text("Model ID")
                Spacer()
                TextField("z-ai/glm-5.1", text: $appSettings.openRouterModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit { appSettings.save() }
            }
            .onChange(of: appSettings.openRouterModel) { _, _ in appSettings.save() }

            Divider().opacity(0.4)

            HStack {
                Text("Reasoning effort")
                Spacer()
                Picker("", selection: $appSettings.selectedReasoningEffort) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            .onChange(of: appSettings.selectedReasoningEffort) { _, _ in appSettings.save() }
        }
    }
}

// MARK: - Shortcuts pane

private struct ShortcutsPane: View {
    @ObservedObject var appSettings: AppSettingsStore

    var body: some View {
        PaneHeader(
            title: "Shortcuts",
            subtitle: "Global shortcuts work anywhere on your Mac."
        )

        SettingsCard(title: "Global hotkeys") {
            ToggleRow(
                title: "Enable global shortcuts",
                subtitle: "No Accessibility permission required.",
                isOn: $appSettings.enableGlobalShortcuts
            )
            .onChange(of: appSettings.enableGlobalShortcuts) { _, _ in appSettings.save() }
        }

        SettingsCard(title: "Defaults") {
            ShortcutRow(label: "Toggle recording", keys: "⌘⇧R")
            Divider().opacity(0.4)
            ShortcutRow(label: "Open dashboard", keys: "⌘⇧D")
        }
    }
}

// MARK: - Calendar pane

private struct CalendarPane: View {
    @ObservedObject var appSettings: AppSettingsStore

    var body: some View {
        PaneHeader(
            title: "Calendar",
            subtitle: "Optionally watch your calendar for meetings and auto-prompt to record."
        )

        SettingsCard(title: "Integration") {
            ToggleRow(
                title: "Integrate with Calendar",
                subtitle: "Watches for events with video-call links (Zoom, Teams, Meet).",
                isOn: $appSettings.enableCalendarIntegration
            )
            .onChange(of: appSettings.enableCalendarIntegration) { _, _ in appSettings.save() }

            Divider().opacity(0.4)

            HStack {
                Text("Pre-meeting notification")
                Spacer()
                Stepper("\(appSettings.preRecordNotificationMinutes) min", value: $appSettings.preRecordNotificationMinutes, in: 1...30)
                    .onChange(of: appSettings.preRecordNotificationMinutes) { _, _ in appSettings.save() }
                    .disabled(!appSettings.enableCalendarIntegration)
            }
        }

        SettingsCard(title: "App detection") {
            ToggleRow(
                title: "Detect meeting apps",
                subtitle: "Zoom, Teams, and similar. Prompts when they launch.",
                isOn: $appSettings.enableMeetingDetection
            )
            .onChange(of: appSettings.enableMeetingDetection) { _, _ in appSettings.save() }
        }
    }
}

// MARK: - About pane

private struct AboutPane: View {
    var body: some View {
        PaneHeader(title: "About", subtitle: nil)

        SettingsCard(title: "MeetRecap") {
            DetailRow(label: "Version", value: "1.0")
            Divider().opacity(0.4)
            DetailRow(label: "Transcription", value: "Groq Whisper v3 Turbo / FluidAudio Parakeet")
            Divider().opacity(0.4)
            DetailRow(label: "AI", value: "OpenRouter")
        }
    }
}

// MARK: - Reusable building blocks

struct PaneHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GlassStyle.sectionTitle)
                    .foregroundStyle(.secondary)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(spacing: 12) {
                content
            }
            .padding(16)
            .glassCard(cornerRadius: GlassStyle.controlRadius)
            .glassStroke(cornerRadius: GlassStyle.controlRadius)
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle = subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

struct KeyFieldRow: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isVisible {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )

            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }
}

struct TranscriptionModeRow: View {
    let mode: TranscriptionMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(mode.tagline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @Published var transcriptionMode: String
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
    @Published var hasCompletedOnboarding: Bool

    private var modelContext: ModelContext?

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

    init() {
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
            transcriptionMode = settings.transcriptionMode
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
            hasCompletedOnboarding = settings.hasCompletedOnboarding
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
        settings.transcriptionMode = transcriptionMode
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
        settings.hasCompletedOnboarding = hasCompletedOnboarding
        settings.updatedAt = Date()

        try? context.save()
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
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
