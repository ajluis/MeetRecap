import Foundation
import AppKit
import Combine

/// Detects running videoconference apps (Zoom, Teams, Meet browser tab proxies)
/// and fires a callback on first detection so the UI can prompt to record.
@MainActor
final class MeetingDetectionService: ObservableObject {
    @Published private(set) var detectedApp: DetectedApp?

    /// Called the moment a meeting app is first detected as running.
    /// Not called again while the app remains running.
    var onDetected: ((DetectedApp) -> Void)?

    private var pollTimer: Timer?
    private var lastKnownBundleID: String?

    struct DetectedApp: Equatable {
        let bundleID: String
        let name: String
    }

    private static let knownBundleIDs: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams (classic)",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.logmein.GoToMeeting": "GoToMeeting",
        "com.hnc.Discord": "Discord"
    ]

    // MARK: - Lifecycle

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Polling

    private func poll() {
        let running = NSWorkspace.shared.runningApplications

        let hit = running.first(where: { app in
            guard let id = app.bundleIdentifier else { return false }
            return Self.knownBundleIDs.keys.contains(id)
        })

        if let hit = hit, let id = hit.bundleIdentifier {
            let name = Self.knownBundleIDs[id] ?? hit.localizedName ?? id
            let detected = DetectedApp(bundleID: id, name: name)
            detectedApp = detected

            if lastKnownBundleID != id {
                lastKnownBundleID = id
                onDetected?(detected)
            }
        } else {
            detectedApp = nil
            lastKnownBundleID = nil
        }
    }
}
