import SwiftUI
import AppKit
import AVFoundation

/// Redesigned menu-bar popover — macOS 26 Liquid Glass.
///
/// Layout: hero record button with live duration + waveform ring → missing-key
/// banner → collapsible input drawer → recent meetings → footer actions.
struct MenuBarPopoverView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var calendarService: CalendarIntegrationService
    @ObservedObject var meetingDetection: MeetingDetectionService
    @ObservedObject var appSettings: AppSettingsStore

    @Environment(\.openWindow) private var openWindow
    @State private var recordScreen = false
    @State private var drawerExpanded = false
    @State private var tick: Bool = false
    @State private var showOnboarding = false

    private var imminentEvent: CalendarIntegrationService.UpcomingEvent? {
        guard appSettings.enableCalendarIntegration else { return nil }
        let window = TimeInterval(appSettings.preRecordNotificationMinutes * 60 + 30)
        return calendarService.upcomingEvents.first(where: { event in
            let until = event.startDate.timeIntervalSinceNow
            return until >= 0 && until <= window
        })
    }

    private var needsGroqKey: Bool {
        appSettings.selectedTranscriptionMode == .cloud &&
        (KeychainHelper.load(key: "meetrecap_groq_key") ?? "").isEmpty
    }

    private var needsOpenRouterKey: Bool {
        (KeychainHelper.load(key: "meetrecap_openrouter_key") ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            // Missing-key banner (prominent, directs to Settings)
            if needsGroqKey {
                setupBanner(
                    title: "Add a Groq API key",
                    subtitle: "Cloud transcription requires a key.",
                    systemImage: "key.horizontal.fill",
                    tint: .orange
                ) { openSettings() }
            } else if needsOpenRouterKey {
                setupBanner(
                    title: "Add an OpenRouter key",
                    subtitle: "Unlock summaries and chat.",
                    systemImage: "sparkles",
                    tint: .blue
                ) { openSettings() }
            }

            // Imminent meeting prompt
            if let event = imminentEvent, !meetingManager.isAnyRecording {
                UpcomingMeetingBanner(event: event) { meetingManager.toggleRecording() }
            }

            // Detected meeting app
            if !meetingManager.isAnyRecording,
               let app = meetingDetection.pendingPrompt {
                AppDetectedBanner(
                    app: app,
                    onRecord: {
                        meetingDetection.dismissPrompt()
                        meetingManager.toggleRecording()
                    },
                    onDismiss: { meetingDetection.dismissPrompt() },
                    onSilence: { meetingDetection.silenceApp(bundleID: app.bundleID) }
                )
            }

            recordHero

            if meetingManager.isAnyRecording {
                LiveTranscriptView(service: meetingManager.streamingTranscription)
                    .padding(.horizontal, 14)
            }

            inputDrawer

            recentMeetings

            footerActions
        }
        .padding(14)
        .frame(width: 340)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.10),
                        Color.black.opacity(0.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            tick.toggle()
        }
        .onAppear {
            if !appSettings.hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(
                appSettings: appSettings,
                transcriptionService: meetingManager.transcriptionService,
                onFinish: { showOnboarding = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 28, height: 28)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("MeetRecap").font(.system(size: 13, weight: .semibold))
                Text(modeDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if meetingManager.isAnyRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(GlassStyle.recordTint)
                        .frame(width: 6, height: 6)
                        .opacity(tick ? 1 : 0.4)
                    Text("REC")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(GlassStyle.recordTint.opacity(0.18))
                .clipShape(Capsule())
            }
        }
    }

    private var modeDescription: String {
        switch appSettings.selectedTranscriptionMode {
        case .cloud: return "Cloud transcription"
        case .local: return "On-device transcription"
        }
    }

    // MARK: - Record hero

    private var recordHero: some View {
        VStack(spacing: 10) {
            ZStack {
                // Outer glow during recording
                Circle()
                    .stroke(
                        meetingManager.isAnyRecording ? GlassStyle.recordTint.opacity(0.4) : Color.accentColor.opacity(0.25),
                        lineWidth: 2
                    )
                    .frame(width: 108, height: 108)
                    .scaleEffect(meetingManager.isAnyRecording && tick ? 1.04 : 1.0)
                    .animation(.easeInOut(duration: 0.5), value: tick)

                // Audio-level ring (when recording)
                if meetingManager.isAnyRecording {
                    audioLevelRing
                }

                // Button
                Button {
                    toggleRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: meetingManager.isAnyRecording
                                        ? [GlassStyle.recordTint, GlassStyle.recordTint.opacity(0.75)]
                                        : [Color.accentColor, Color.accentColor.opacity(0.75)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 88, height: 88)
                            .shadow(
                                color: (meetingManager.isAnyRecording ? GlassStyle.recordTint : Color.accentColor).opacity(0.4),
                                radius: 16, y: 4
                            )

                        if meetingManager.isAnyRecording {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white)
                                .frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .frame(height: 120)

            if meetingManager.isAnyRecording {
                Text(formatDuration(meetingManager.currentRecordingDuration))
                    .font(GlassStyle.displayNumber)
                    .foregroundStyle(GlassStyle.recordTint)
                    .id(tick)
            } else {
                VStack(spacing: 2) {
                    Text(startLabel)
                        .font(.system(size: 13, weight: .medium))
                    Text("Return to toggle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var startLabel: String {
        switch meetingManager.transcriptionState {
        case .downloadingModel(let p): return "Downloading model… \(Int(p * 100))%"
        case .loadingModel: return "Loading model…"
        case .failed: return "Start Recording"
        default: return "Start Recording"
        }
    }

    private var audioLevelRing: some View {
        let level = CGFloat(meetingManager.audioRecorder.audioLevel)
        return Circle()
            .trim(from: 0, to: max(0.05, min(1.0, level)))
            .stroke(
                AngularGradient(
                    colors: [GlassStyle.recordTint, .orange, .yellow, .green, GlassStyle.recordTint],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 100, height: 100)
            .rotationEffect(.degrees(-90))
            .animation(.easeOut(duration: 0.12), value: level)
    }

    // MARK: - Banners

    private func setupBanner(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .glassCard(cornerRadius: 12, tinted: true)
            .glassStroke(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input drawer (collapsible)

    private var inputDrawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.25)) { drawerExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text("Inputs")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(activeInputLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(drawerExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if drawerExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().opacity(0.2)

                    // Device picker
                    drawerRow(
                        icon: "mic",
                        label: "Input device"
                    ) {
                        Picker("", selection: Binding(
                            get: { meetingManager.audioDeviceManager.selectedDevice },
                            set: { meetingManager.audioDeviceManager.selectedDevice = $0 }
                        )) {
                            ForEach(meetingManager.audioDeviceManager.inputDevices) { device in
                                Text(device.name).tag(device as AudioDevice?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        .disabled(meetingManager.isAnyRecording)
                    }

                    // Screen recording
                    drawerRow(icon: "display", label: "Record screen") {
                        Toggle("", isOn: $recordScreen)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(meetingManager.isAnyRecording)
                    }

                    // System audio
                    if SystemAudioRecorder.isAvailable {
                        drawerRow(icon: "speaker.wave.2", label: "System audio") {
                            Toggle("", isOn: Binding(
                                get: { appSettings.useNativeSystemAudio },
                                set: {
                                    appSettings.useNativeSystemAudio = $0
                                    appSettings.save()
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(meetingManager.isAnyRecording)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .glassCard(cornerRadius: 14)
        .glassStroke(cornerRadius: 14)
    }

    private var activeInputLabel: String {
        if appSettings.useNativeSystemAudio, SystemAudioRecorder.isAvailable {
            return "System audio"
        }
        return meetingManager.audioDeviceManager.selectedDevice?.name ?? "Default mic"
    }

    private func drawerRow<Trailing: View>(
        icon: String,
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label).font(.system(size: 11))
            Spacer()
            trailing()
        }
    }

    // MARK: - Recent meetings

    @ViewBuilder
    private var recentMeetings: some View {
        RecentMeetingsStrip(
            meetings: meetingManager.recentMeetings(limit: 3),
            onOpen: { _ in openWindow(id: "dashboard") }
        )
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 0) {
            footerButton(icon: "rectangle.stack", label: "Dashboard") {
                openWindow(id: "dashboard")
            }
            Divider().frame(height: 18).opacity(0.3)
            footerButton(icon: "slider.horizontal.3", label: "Settings") {
                openSettings()
            }
            Divider().frame(height: 18).opacity(0.3)
            footerButton(icon: "power", label: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 2)
        .glassCard(cornerRadius: 12)
        .glassStroke(cornerRadius: 12)
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func toggleRecording() {
        if meetingManager.isAnyRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        Task {
            if !meetingManager.isTranscriptionReady,
               appSettings.selectedTranscriptionMode == .local {
                await meetingManager.loadTranscriptionModel()
            }
            do {
                try await meetingManager.startRecording()
                if recordScreen {
                    try await meetingManager.screenRecorder.startRecording()
                }
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }

    private func stopRecording() {
        Task {
            let (audioURL, duration) = await meetingManager.stopRecording()
            let calendarContext = meetingManager.consumeActiveCalendarContext()
            var screenURL: URL? = nil
            if recordScreen {
                screenURL = await meetingManager.screenRecorder.stopRecording()
            }
            await meetingManager.finishRecording(
                audioURL: audioURL,
                screenRecordingURL: screenURL,
                duration: duration,
                calendarContext: calendarContext
            )
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Recent meetings strip

struct RecentMeetingsStrip: View {
    let meetings: [Meeting]
    let onOpen: (Meeting) -> Void

    var body: some View {
        if meetings.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent")
                    .font(GlassStyle.sectionTitle)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(spacing: 4) {
                    ForEach(meetings) { meeting in
                        Button {
                            onOpen(meeting)
                        } label: {
                            HStack(spacing: 8) {
                                statusDot(meeting)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(meeting.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(meeting.date, style: .relative)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text(meeting.formattedDuration)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glassCard(cornerRadius: 12)
                .glassStroke(cornerRadius: 12)
            }
        }
    }

    private func statusDot(_ meeting: Meeting) -> some View {
        Circle()
            .fill(
                meeting.isSummarized ? Color.green :
                meeting.isTranscribed ? Color.blue : Color.orange
            )
            .frame(width: 6, height: 6)
    }
}
