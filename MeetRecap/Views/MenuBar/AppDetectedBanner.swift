import SwiftUI

/// Banner shown in the menu-bar popover when a known meeting app (Zoom, Teams, …)
/// is detected launching and the user hasn't silenced prompts for it.
struct AppDetectedBanner: View {
    let app: MeetingDetectionService.DetectedApp
    let onRecord: () -> Void
    let onDismiss: () -> Void
    let onSilence: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "video.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(app.name) is running")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("Record this meeting?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Don't ask for \(app.name) again", action: onSilence)
                Button("Dismiss", action: onDismiss)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("Record", action: onRecord)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }
}
