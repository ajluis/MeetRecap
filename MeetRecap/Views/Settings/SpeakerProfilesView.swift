import SwiftUI
import SwiftData

/// Settings tab that lists saved speaker profiles.
/// Users can rename, recolor, or delete profiles.
struct SpeakerProfilesView: View {
    @Query(sort: \SpeakerProfile.name) private var profiles: [SpeakerProfile]
    @Environment(\.modelContext) private var modelContext

    @ObservedObject var appSettings: AppSettingsStore

    @State private var pendingDelete: SpeakerProfile?
    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
            Section {
                if profiles.isEmpty {
                    Text("No saved speaker profiles yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Rename a speaker in a transcript and check \"Remember this voice\" to save a profile.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(profiles) { profile in
                        SpeakerProfileRow(profile: profile) {
                            pendingDelete = profile
                            showDeleteConfirm = true
                        }
                    }
                }
            } header: {
                Text("Saved Profiles")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Match threshold")
                        Spacer()
                        Text(String(format: "%.2f", appSettings.speakerMatchThreshold))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $appSettings.speakerMatchThreshold,
                        in: 0.6...0.95,
                        step: 0.01
                    )
                    .onChange(of: appSettings.speakerMatchThreshold) { _, _ in
                        appSettings.save()
                    }
                    Text("Higher values require stronger voice similarity before auto-labeling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Matching")
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Delete profile?",
            isPresented: $showDeleteConfirm,
            presenting: pendingDelete
        ) { profile in
            Button("Delete \(profile.name)", role: .destructive) {
                modelContext.delete(profile)
                try? modelContext.save()
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { profile in
            Text("This removes the voice profile for \(profile.name). Past transcripts are unchanged.")
        }
    }
}

struct SpeakerProfileRow: View {
    @Bindable var profile: SpeakerProfile
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var editedName = ""

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(profile.color)
                .frame(width: 12, height: 12)

            if isEditing {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                    .onAppear { editedName = profile.name }
            } else {
                Text(profile.name)
                    .onTapGesture(count: 2) {
                        editedName = profile.name
                        isEditing = true
                    }
                    .help("Double-click to rename")
            }

            Spacer()

            Text("\(profile.meetingCount) meeting\(profile.meetingCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formatDuration(profile.totalDuration))
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(Color.tagPalette, id: \.self) { hex in
                    Button {
                        profile.colorHex = hex
                    } label: {
                        HStack {
                            Circle().fill(Color(hex: hex) ?? .accentColor).frame(width: 12, height: 12)
                            Text(hex)
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Delete profile")
        }
    }

    private func commit() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            profile.name = trimmed
            profile.updatedAt = Date()
        }
        isEditing = false
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
