import SwiftUI

/// First-launch onboarding sheet that collects the two API keys MeetRecap needs:
///   1. Groq — for Whisper audio transcription (cloud mode)
///   2. OpenRouter — for summaries + chat
/// Both are stored in the macOS Keychain. Users can "Skip for now" and add keys
/// later from Settings.
struct OnboardingView: View {
    @ObservedObject var appSettings: AppSettingsStore
    @ObservedObject var transcriptionService: TranscriptionService
    let onFinish: () -> Void

    @State private var page: Page = .welcome
    @State private var groqKey = ""
    @State private var openRouterKey = ""
    @State private var showGroq = false
    @State private var showRouter = false
    @State private var isTestingGroq = false
    @State private var groqTestResult: TestResult?
    @State private var isTestingRouter = false
    @State private var routerTestResult: TestResult?

    enum Page: Int, CaseIterable { case welcome, transcription, ai, finish }
    enum TestResult { case success, failure(String) }

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .welcome:      welcomePage
            case .transcription: transcriptionPage
            case .ai:           aiPage
            case .finish:       finishPage
            }
        }
        .frame(width: 560, height: 620)
        .background {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.18),
                    Color.black.opacity(0.4)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .onAppear {
            groqKey = KeychainHelper.load(key: "meetrecap_groq_key") ?? ""
            openRouterKey = KeychainHelper.load(key: "meetrecap_openrouter_key") ?? ""
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 128, height: 128)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(Color.accentColor, .white.opacity(0.9))
            }

            VStack(spacing: 8) {
                Text("Welcome to MeetRecap")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("Record any meeting. Get a clean transcript and summary in seconds.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)

            Spacer()

            pageControls(
                canSkip: true,
                onNext: { page = .transcription },
                nextTitle: "Get Started"
            )
        }
        .padding(28)
    }

    // MARK: - Transcription page

    private var transcriptionPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                step: "Step 1 of 2",
                title: "Connect transcription",
                subtitle: "MeetRecap uses Groq Whisper for instant, cheap cloud transcription (~$0.04/hour). Your audio is streamed to Groq for processing."
            )

            VStack(alignment: .leading, spacing: 16) {
                linkLabel(
                    title: "Get a Groq API key (free tier)",
                    url: "https://console.groq.com/keys"
                )

                keyField(
                    placeholder: "gsk_...",
                    text: $groqKey,
                    isVisible: $showGroq
                )

                testButton(
                    isTesting: $isTestingGroq,
                    result: $groqTestResult,
                    action: testGroq
                )
            }
            .padding(22)
            .glassCard()
            .glassStroke()
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Spacer()

            pageControls(
                canSkip: true,
                onBack: { page = .welcome },
                onNext: {
                    if !groqKey.isEmpty {
                        KeychainHelper.save(key: "meetrecap_groq_key", value: groqKey)
                    }
                    page = .ai
                },
                nextTitle: groqKey.isEmpty ? "Skip for now" : "Continue"
            )
        }
        .padding(.vertical, 28)
    }

    // MARK: - AI page

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(
                step: "Step 2 of 2",
                title: "Connect AI features",
                subtitle: "OpenRouter powers summaries, action-item extraction, and chat-with-meeting. One key unlocks dozens of models — default is GLM 5.1."
            )

            VStack(alignment: .leading, spacing: 16) {
                linkLabel(
                    title: "Get an OpenRouter API key",
                    url: "https://openrouter.ai/keys"
                )

                keyField(
                    placeholder: "sk-or-...",
                    text: $openRouterKey,
                    isVisible: $showRouter
                )

                testButton(
                    isTesting: $isTestingRouter,
                    result: $routerTestResult,
                    action: testOpenRouter
                )
            }
            .padding(22)
            .glassCard()
            .glassStroke()
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Spacer()

            pageControls(
                canSkip: true,
                onBack: { page = .transcription },
                onNext: {
                    if !openRouterKey.isEmpty {
                        KeychainHelper.save(key: "meetrecap_openrouter_key", value: openRouterKey)
                    }
                    page = .finish
                },
                nextTitle: openRouterKey.isEmpty ? "Skip for now" : "Continue"
            )
        }
        .padding(.vertical, 28)
    }

    // MARK: - Finish

    private var finishPage: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle().fill(.green.opacity(0.22)).frame(width: 128, height: 128)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(.green, .white)
            }

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Click the microphone in your menu bar to start your first meeting.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)

            Spacer()

            Button {
                appSettings.hasCompletedOnboarding = true
                appSettings.save()
                onFinish()
            } label: {
                Text("Open MeetRecap")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 120)
            .padding(.bottom, 8)
        }
        .padding(28)
    }

    // MARK: - Building blocks

    private func pageHeader(step: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step)
                .font(GlassStyle.sectionTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
    }

    private func linkLabel(title: String, url: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 11))
            Link(title, destination: URL(string: url)!)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.accentColor)
    }

    private func keyField(
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>
    ) -> some View {
        HStack(spacing: 6) {
            Group {
                if isVisible.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private func testButton(
        isTesting: Binding<Bool>,
        result: Binding<TestResult?>,
        action: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    isTesting.wrappedValue = true
                    await action()
                    isTesting.wrappedValue = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isTesting.wrappedValue {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text("Test connection")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if let result = result.wrappedValue {
                switch result {
                case .success:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    private func pageControls(
        canSkip: Bool,
        onBack: (() -> Void)? = nil,
        onNext: @escaping () -> Void,
        nextTitle: String = "Continue"
    ) -> some View {
        HStack {
            if let onBack = onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if canSkip && page != .finish {
                Button("Skip all") {
                    appSettings.hasCompletedOnboarding = true
                    appSettings.save()
                    onFinish()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            }

            Button(action: onNext) {
                Text(nextTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Test actions

    private func testGroq() async {
        guard !groqKey.isEmpty else {
            groqTestResult = .failure("Enter a key first")
            return
        }
        KeychainHelper.save(key: "meetrecap_groq_key", value: groqKey)
        switch await transcriptionService.cloudService.testConnection() {
        case .success:
            groqTestResult = .success
        case .failure(let error):
            groqTestResult = .failure(error.localizedDescription)
        }
    }

    private func testOpenRouter() async {
        guard !openRouterKey.isEmpty else {
            routerTestResult = .failure("Enter a key first")
            return
        }
        KeychainHelper.save(key: "meetrecap_openrouter_key", value: openRouterKey)
        switch await OpenRouterPing.test(apiKey: openRouterKey) {
        case .success:
            routerTestResult = .success
        case .failure(let error):
            routerTestResult = .failure(error.localizedDescription)
        }
    }
}

/// Tiny connectivity check for OpenRouter — GETs /api/v1/models with the key
/// and accepts any 2xx as a valid auth.
enum OpenRouterPing {
    static func test(apiKey: String) async -> Result<Void, Error> {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            return .failure(NSError(domain: "OpenRouterPing", code: 1))
        }
        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("MeetRecap", forHTTPHeaderField: "X-Title")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .failure(NSError(
                    domain: "OpenRouterPing",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]
                ))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
