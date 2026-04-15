import SwiftUI
import SwiftData
import UserNotifications
import AppKit

@main
struct MeetRecapApp: App {
    @StateObject private var meetingManager = MeetingManager()
    @StateObject private var appSettingsStore = AppSettingsStore()
    @StateObject private var hotkeyManager = HotkeyManager()
    @StateObject private var calendarService = CalendarIntegrationService()
    @StateObject private var meetingDetection = MeetingDetectionService()

    let modelContainer: ModelContainer
    
    init() {
        do {
            let schema = Schema([
                Meeting.self,
                TranscriptSegment.self,
                AppSettings.self,
                Tag.self,
                SpeakerProfile.self
            ])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Request notification permissions (only in proper .app bundle)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }
    
    var body: some Scene {
        // Menu bar icon — use a dedicated View so @Environment(\.openWindow) works
        MenuBarExtra {
            MenuBarPopoverView(
                meetingManager: meetingManager,
                calendarService: calendarService,
                meetingDetection: meetingDetection,
                appSettings: appSettingsStore
            )
                .modelContainer(modelContainer)
                .onAppear {
                    configureManager()
                }
        } label: {
            MenuBarLabelView(meetingManager: meetingManager)
        }
        .menuBarExtraStyle(.window)
        
        // Dashboard window
        Window("MeetRecap Dashboard", id: "dashboard") {
            DashboardView(meetingManager: meetingManager)
                .modelContainer(modelContainer)
                .onAppear {
                    configureManager()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 800, height: 600)
        
        // Settings window
        Window("MeetRecap Settings", id: "settings") {
            SettingsView(
                appSettings: appSettingsStore,
                transcriptionService: meetingManager.transcriptionService
            )
            .modelContainer(modelContainer)
            .onAppear {
                configureManager()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 480, height: 380)
        
        // SwiftUI Settings (for system Settings menu)
        Settings {
            SettingsView(
                appSettings: appSettingsStore,
                transcriptionService: meetingManager.transcriptionService
            )
            .modelContainer(modelContainer)
            .onAppear {
                configureManager()
            }
        }
    }
    
    private func configureManager() {
        let context = ModelContext(modelContainer)
        appSettingsStore.setModelContext(context)
        meetingManager.configure(modelContext: context, appSettings: appSettingsStore)

        // One-time migration: move temp-dir recordings into persistent storage.
        AudioStorageManager.shared.migrateMeetingsFromTempDirectory(modelContext: context)

        // Give the meeting manager access to calendar for auto-titling recordings.
        meetingManager.calendarServiceRef = calendarService

        // Wire global hotkeys
        hotkeyManager.onToggleRecording = { [weak meetingManager] in
            meetingManager?.toggleRecording()
        }
        hotkeyManager.onOpenDashboard = {
            NSApplication.shared.activate(ignoringOtherApps: true)
            // Routing a SwiftUI openWindow from here is awkward; use URL scheme fallback.
            if let url = URL(string: "meetrecap://dashboard") {
                NSWorkspace.shared.open(url)
            }
        }
        hotkeyManager.enabled = appSettingsStore.enableGlobalShortcuts

        // Calendar + meeting detection
        calendarService.notificationMinutes = appSettingsStore.preRecordNotificationMinutes
        if appSettingsStore.enableCalendarIntegration {
            Task {
                _ = await calendarService.requestAccess()
                calendarService.start()
            }
        }
        if appSettingsStore.enableMeetingDetection {
            meetingDetection.start()
        }

        // Load model in background - don't block UI
        Task.detached {
            await meetingManager.loadTranscriptionModel()
        }
    }
}

// MARK: - Menu Bar Label (separate View for live updates)

struct MenuBarLabelView: View {
    @ObservedObject var meetingManager: MeetingManager
    @State private var tick = false
    
    var body: some View {
        if meetingManager.isAnyRecording {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .symbolEffect(.pulse)
                    .foregroundStyle(.red)
                Text(formatDuration(meetingManager.currentRecordingDuration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                tick.toggle()
            }
        } else {
            Image(systemName: "mic")
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Menu Bar Popover (separate View with @Environment(\.openWindow))

struct MenuBarPopoverView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var calendarService: CalendarIntegrationService
    @ObservedObject var meetingDetection: MeetingDetectionService
    @ObservedObject var appSettings: AppSettingsStore
    @Environment(\.openWindow) private var openWindow
    @State private var recordScreen = false
    @State private var tick = false
    @State private var forceRefresh = false

    private var imminentEvent: CalendarIntegrationService.UpcomingEvent? {
        guard appSettings.enableCalendarIntegration else { return nil }
        let window = TimeInterval(appSettings.preRecordNotificationMinutes * 60 + 30)
        return calendarService.upcomingEvents.first(where: { event in
            let until = event.startDate.timeIntervalSinceNow
            return until >= 0 && until <= window
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            if let event = imminentEvent, !meetingManager.isAnyRecording {
                UpcomingMeetingBanner(event: event) {
                    meetingManager.toggleRecording()
                }
                Divider().padding(.vertical, 4)
            } else if let detectedApp = meetingDetection.pendingPrompt,
                      !meetingManager.isAnyRecording {
                AppDetectedBanner(
                    app: detectedApp,
                    onRecord: {
                        meetingDetection.dismissPrompt()
                        meetingManager.toggleRecording()
                    },
                    onDismiss: {
                        meetingDetection.dismissPrompt()
                    },
                    onSilence: {
                        meetingDetection.silenceApp(bundleID: detectedApp.bundleID)
                    }
                )
                Divider().padding(.vertical, 4)
            } else {
                Divider().padding(.vertical, 8)
            }

            if meetingManager.isAnyRecording {
                audioLevelSection
                LiveTranscriptView(service: meetingManager.streamingTranscription)
                Divider().padding(.vertical, 4)
            }

            settingsSection
            Divider().padding(.vertical, 8)
            controlSection
        }
        .frame(width: 300)
        .padding(.vertical, 4)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            tick.toggle()
            forceRefresh.toggle()
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            Image(systemName: "mic.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            
            Text("MeetRecap")
                .font(.headline)
            
            Spacer()
            
            if meetingManager.isAnyRecording {
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.15))
                    .clipShape(Capsule())
                    .id(forceRefresh)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
    
    // MARK: - Audio Level
    
    private var audioLevelSection: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { index in
                let level = meetingManager.audioRecorder.audioLevel
                let threshold = Float(index) / 8.0
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? barColor(for: index) : Color.gray.opacity(0.3))
                    .frame(width: 4, height: level > threshold ? CGFloat(4 + index * 2) : 4)
            }
        }
        .frame(height: 24)
        .padding(.vertical, 4)
    }
    
    // MARK: - Settings
    
    private var settingsSection: some View {
        VStack(spacing: 8) {
            // Microphone picker
            HStack {
                Image(systemName: meetingManager.audioDeviceManager.systemAudioAvailable ? "waveform" : "mic")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meetingManager.audioDeviceManager.systemAudioAvailable ? "System Audio" : "Microphone")
                        .font(.subheadline)
                    if meetingManager.audioDeviceManager.systemAudioAvailable {
                        Text("Recording all device audio")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Picker("", selection: Binding(
                    get: { meetingManager.audioDeviceManager.selectedDevice },
                    set: { meetingManager.audioDeviceManager.selectedDevice = $0 }
                )) {
                    ForEach(meetingManager.audioDeviceManager.inputDevices) { device in
                        Text(device.name).tag(device as AudioDevice?)
                    }
                }
                .onChange(of: meetingManager.audioDeviceManager.selectedDevice) { _, newDevice in
                    // Update system audio status
                    meetingManager.audioDeviceManager.systemAudioAvailable = newDevice?.name.lowercased().contains("blackhole") ?? false ||
                                                                                newDevice?.name.lowercased().contains("aggregate") ?? false
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 150)
                .disabled(meetingManager.isAnyRecording)
            }
            .padding(.horizontal, 16)
            
            // Screen recording toggle
            Toggle(isOn: $recordScreen) {
                HStack {
                    Image(systemName: "display")
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text("Record screen")
                        .font(.subheadline)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16)
            .disabled(meetingManager.isAnyRecording)

            // System audio (native, no BlackHole) toggle
            if SystemAudioRecorder.isAvailable {
                Toggle(isOn: Binding(
                    get: { appSettings.useNativeSystemAudio },
                    set: {
                        appSettings.useNativeSystemAudio = $0
                        appSettings.save()
                    }
                )) {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Record system audio")
                                .font(.subheadline)
                            Text("Captures all device output, no BlackHole needed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 16)
                .disabled(meetingManager.isAnyRecording)
            }
        }
    }
    
    // MARK: - Controls
    
    private var controlSection: some View {
        VStack(spacing: 4) {
            if meetingManager.isAnyRecording {
                // Stop button
                Button {
                    stopRecording()
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 16)
                
                // Duration
                Text(formatDuration(meetingManager.currentRecordingDuration))
                    .font(.system(.title2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
                    .id(tick) // force refresh on tick
            } else {
                // Start button
                Button {
                    startRecording()
                } label: {
                    HStack {
                        Image(systemName: "record.circle")
                        Text("Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 16)
                .disabled(meetingManager.transcriptionState == .failed(""))

                if case .downloadingModel(let progress) = meetingManager.transcriptionState {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading model... \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else if case .loadingModel = meetingManager.transcriptionState {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading model...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else if case .failed(let error) = meetingManager.transcriptionState {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Model failed: \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(.top, 4)
                }
            }
            
            Divider().padding(.vertical, 4)
            
            // Dashboard
            Button {
                openWindow(id: "dashboard")
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text("Open Dashboard")
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            
            // Settings
            Button {
                openWindow(id: "settings")
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            
            Divider().padding(.vertical, 2)
            
            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit MeetRecap")
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .foregroundStyle(.secondary)
            
            Spacer().frame(height: 4)
        }
    }
    
    // MARK: - Actions

    private func startRecording() {
        Task {
            if !meetingManager.isTranscriptionReady {
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
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func barColor(for index: Int) -> Color {
        if index < 5 { return .green }
        else if index < 7 { return .yellow }
        else { return .red }
    }
}
