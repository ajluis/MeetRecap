import SwiftUI

/// Thin wrapper around DashboardView that owns first-run onboarding presentation
/// at the dashboard level. Keeps DashboardView itself focused on the data pane.
struct DashboardRootView: View {
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var appSettings: AppSettingsStore

    @State private var showOnboarding = false

    var body: some View {
        DashboardView(
            meetingManager: meetingManager,
            appSettings: appSettings
        )
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
}
