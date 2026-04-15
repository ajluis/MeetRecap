import Foundation
import EventKit
import UserNotifications
import Combine

/// Polls the user's calendar for upcoming meetings that have video-call URLs.
/// When a meeting is imminent, fires a local notification suggesting to record.
///
/// Requires `NSCalendarsUsageDescription` in Info.plist.
@MainActor
final class CalendarIntegrationService: ObservableObject {
    @Published private(set) var upcomingEvents: [UpcomingEvent] = []
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined

    /// Minutes before the meeting to notify the user.
    var notificationMinutes: Int = 2

    private let eventStore = EKEventStore()
    private var pollTimer: Timer?
    private var notifiedEventIdentifiers: Set<String> = []

    struct UpcomingEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let startDate: Date
        let videoURL: URL?

        var minutesUntilStart: Int {
            max(0, Int(startDate.timeIntervalSinceNow / 60))
        }
    }

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Authorization

    func requestAccess() async -> Bool {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await eventStore.requestFullAccessToEvents()
            } else {
                granted = try await eventStore.requestAccess(to: .event)
            }
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        } catch {
            print("[CalendarIntegrationService] Access request failed: \(error)")
            return false
        }
    }

    // MARK: - Polling

    func start() {
        stop()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Fire once immediately
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Refresh the list of upcoming events and deliver pre-meeting notifications if due.
    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status

        let authorized: Bool
        if #available(macOS 14.0, *) {
            authorized = (status == .fullAccess || status == .writeOnly)
        } else {
            authorized = (status == .authorized)
        }
        guard authorized else {
            upcomingEvents = []
            return
        }

        let now = Date()
        let horizon = now.addingTimeInterval(15 * 60)  // next 15 minutes
        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: horizon,
            calendars: calendars
        )
        let events = eventStore.events(matching: predicate)

        let parsed: [UpcomingEvent] = events.compactMap { event in
            guard let id = event.eventIdentifier,
                  !event.isAllDay,
                  event.startDate >= now else { return nil }
            let url = videoURL(in: event)
            // Only surface events with a video URL — in-person ones aren't recordable here.
            guard url != nil || event.location?.isEmpty == false else { return nil }
            return UpcomingEvent(
                id: id,
                title: event.title ?? "Meeting",
                startDate: event.startDate,
                videoURL: url
            )
        }

        upcomingEvents = parsed

        // Notify when a meeting is within notificationMinutes
        for event in parsed {
            let threshold = notificationMinutes * 60 + 30  // add slack so we catch it
            let timeUntil = event.startDate.timeIntervalSinceNow
            if timeUntil <= Double(threshold), timeUntil > 0,
               !notifiedEventIdentifiers.contains(event.id) {
                notifiedEventIdentifiers.insert(event.id)
                sendNotification(for: event)
            }
        }
    }

    // MARK: - Helpers

    private func videoURL(in event: EKEvent) -> URL? {
        let patterns = [
            "zoom.us",
            "teams.microsoft.com",
            "teams.live.com",
            "meet.google.com",
            "whereby.com",
            "kumospace.com",
            "gather.town",
            "around.co",
            "meet.jit.si",
            "discord.com/channels",
            "discord.gg",
            "chime.aws",
            "bluejeans.com",
            "gotomeeting.com",
            "webex.com"
        ]

        if let eventURL = event.url,
           let host = eventURL.host?.lowercased(),
           patterns.contains(where: host.contains) {
            return eventURL
        }

        let haystack = [event.notes, event.location]
            .compactMap { $0 }
            .joined(separator: "\n")

        for pattern in patterns {
            if let range = haystack.range(of: pattern) {
                // Extract surrounding URL
                let start = haystack[..<range.lowerBound].lastIndex(of: " ") ?? haystack.startIndex
                let end = haystack[range.upperBound...].firstIndex(of: " ") ?? haystack.endIndex
                let candidate = String(haystack[start..<end])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t<>\"'"))
                if let url = URL(string: candidate) { return url }
            }
        }

        return nil
    }

    private func sendNotification(for event: UpcomingEvent) {
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = "Upcoming meeting"
        content.body = "\"\(event.title)\" starts in \(max(event.minutesUntilStart, 0)) min — record?"
        content.sound = .default
        content.userInfo = ["eventIdentifier": event.id]

        let request = UNNotificationRequest(
            identifier: "meetrecap-calendar-\(event.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
