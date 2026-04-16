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
            DashboardRootView(
                meetingManager: meetingManager,
                appSettings: appSettingsStore
            )
                .modelContainer(modelContainer)
                .onAppear {
                    configureManager()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 680)

        // Settings window
        Window("MeetRecap Settings", id: "settings") {
            SettingsView(
                appSettings: appSettingsStore,
                transcriptionService: meetingManager.transcriptionService,
                meetingManager: meetingManager
            )
            .modelContainer(modelContainer)
            .onAppear {
                configureManager()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 820, height: 580)

        // SwiftUI Settings (for system Settings menu)
        Settings {
            SettingsView(
                appSettings: appSettingsStore,
                transcriptionService: meetingManager.transcriptionService,
                meetingManager: meetingManager
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

        // Load local model in background only if the user picked on-device mode.
        // Cloud mode is ready instantly — no download, no load.
        if appSettingsStore.selectedTranscriptionMode == .local {
            Task.detached {
                await meetingManager.loadTranscriptionModel()
            }
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

