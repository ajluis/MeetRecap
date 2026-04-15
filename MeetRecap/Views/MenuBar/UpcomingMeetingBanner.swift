import SwiftUI

/// Compact banner shown in the menu-bar popover when a calendar meeting is imminent.
/// Offers a one-tap Record action that kicks off toggleRecording().
struct UpcomingMeetingBanner: View {
    let event: CalendarIntegrationService.UpcomingEvent
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Record") {
                onRecord()
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private var subtitle: String {
        let mins = event.minutesUntilStart
        let base: String
        if mins == 0 {
            base = "Starting now"
        } else if mins == 1 {
            base = "Starts in 1 min"
        } else {
            base = "Starts in \(mins) min"
        }
        if event.videoURL != nil {
            return base + " · Video meeting"
        }
        return base
    }
}
