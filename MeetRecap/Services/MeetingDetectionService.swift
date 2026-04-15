import Foundation
import AppKit
import Combine

/// Detects running videoconference apps (Zoom, Teams, Meet browser tab proxies)
/// and publishes the first detection so the UI can prompt the user to record.
@MainActor
final class MeetingDetectionService: ObservableObject {
    /// Currently running meeting app, if any.
    @Published private(set) var detectedApp: DetectedApp?

    /// Bundle IDs the user has opted out of being prompted for. Persisted in UserDefaults.
    @Published private(set) var silencedBundleIDs: Set<String> = []

    /// Bundle IDs dismissed for this session only (until the app quits and relaunches).
    private var sessionDismissedBundleIDs: Set<String> = []

    /// The event the UI should show a banner for, after filtering silenced + dismissed.
    @Published private(set) var pendingPrompt: DetectedApp?

    private var pollTimer: Timer?
    private var lastKnownBundleID: String?

    private let silencedKey = "meetrecap.silenced_meeting_apps"

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
        loadSilenced()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    // MARK: - Dismiss / Silence

    /// Dismiss the current banner for this session only. Will re-prompt on next detection of a new app.
    func dismissPrompt() {
        if let app = pendingPrompt {
            sessionDismissedBundleIDs.insert(app.bundleID)
        }
        pendingPrompt = nil
    }

    /// Silence prompts for the given bundle ID permanently.
    func silenceApp(bundleID: String) {
        silencedBundleIDs.insert(bundleID)
        UserDefaults.standard.set(Array(silencedBundleIDs), forKey: silencedKey)
        if pendingPrompt?.bundleID == bundleID {
            pendingPrompt = nil
        }
    }

    /// Clear a previous silence.
    func unsilenceApp(bundleID: String) {
        silencedBundleIDs.remove(bundleID)
        UserDefaults.standard.set(Array(silencedBundleIDs), forKey: silencedKey)
    }

    private func loadSilenced() {
        if let arr = UserDefaults.standard.array(forKey: silencedKey) as? [String] {
            silencedBundleIDs = Set(arr)
        }
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
                // Only surface a prompt if the user hasn't silenced or dismissed this app.
                if !silencedBundleIDs.contains(id),
                   !sessionDismissedBundleIDs.contains(id) {
                    pendingPrompt = detected
                }
            }
        } else {
            detectedApp = nil
            pendingPrompt = nil
            lastKnownBundleID = nil
        }
    }
}
