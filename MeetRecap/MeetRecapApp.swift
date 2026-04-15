import SwiftUI
import SwiftData
import UserNotifications
import AppKit

@main
struct MeetRecapApp: App {
    @StateObject private var meetingManager = MeetingManager()
    @StateObject private var appSettingsStore = AppSettingsStore()
    
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
            MenuBarPopoverView(meetingManager: meetingManager)
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
        if meetingManager.audioRecorder.isRecording {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill")
                    .symbolEffect(.pulse)
                    .foregroundStyle(.red)
                Text(formatDuration(meetingManager.audioRecorder.currentDuration))
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
    @Environment(\.openWindow) private var openWindow
    @State private var recordScreen = false
    @State private var tick = false
    @State private var forceRefresh = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().padding(.vertical, 8)
            
            if meetingManager.audioRecorder.isRecording {
                audioLevelSection
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
            
            if meetingManager.audioRecorder.isRecording {
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
                .disabled(meetingManager.audioRecorder.isRecording)
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
            .disabled(meetingManager.audioRecorder.isRecording)
        }
    }
    
    // MARK: - Controls
    
    private var controlSection: some View {
        VStack(spacing: 4) {
            if meetingManager.audioRecorder.isRecording {
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
                Text(formatDuration(meetingManager.audioRecorder.currentDuration))
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
            // Ensure transcription model is loaded before starting
            if !meetingManager.isTranscriptionReady {
                await meetingManager.loadTranscriptionModel()
            }

            do {
                try meetingManager.audioRecorder.startRecording(
                    deviceID: meetingManager.audioDeviceManager.selectedDevice?.id
                )
                if recordScreen {
                    try await meetingManager.screenRecorder.startRecording()
                }
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
    
    private func stopRecording() {
        let audioURL = meetingManager.audioRecorder.stopRecording()
        Task {
            var screenURL: URL? = nil
            if recordScreen {
                screenURL = await meetingManager.screenRecorder.stopRecording()
            }
            await meetingManager.finishRecording(
                audioURL: audioURL,
                screenRecordingURL: screenURL,
                duration: meetingManager.audioRecorder.currentDuration
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
