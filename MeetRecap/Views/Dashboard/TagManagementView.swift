import SwiftUI
import SwiftData

/// Popover/menu content for creating tags and toggling them on a meeting.
struct TagManagementView: View {
    let meeting: Meeting
    @ObservedObject var meetingManager: MeetingManager

    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTagName: String = ""
    @State private var newTagColor: String = Color.tagPalette.first ?? "#007AFF"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.subheadline)
                .fontWeight(.semibold)

            if allTags.isEmpty {
                Text("No tags yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(allTags) { tag in
                            TagRow(
                                tag: tag,
                                isAssigned: meeting.tags.contains(where: { $0.id == tag.id })
                            ) {
                                meetingManager.toggleTag(tag, on: meeting)
                            } onDelete: {
                                meetingManager.deleteTag(tag)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Divider()

            // Create new tag
            HStack(spacing: 6) {
                ColorPickerMenu(selectedHex: $newTagColor)

                TextField("New tag", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createTag)

                Button("Add", action: createTag)
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func createTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let tag = meetingManager.createTag(name: trimmed, colorHex: newTagColor) {
            meetingManager.toggleTag(tag, on: meeting)
        }
        newTagName = ""
    }
}

struct TagRow: View {
    let tag: Tag
    let isAssigned: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isAssigned ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isAssigned ? tag.color : .secondary)
                    Circle()
                        .fill(tag.color)
                        .frame(width: 10, height: 10)
                    Text(tag.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete tag")
        }
        .padding(.vertical, 2)
    }
}

struct ColorPickerMenu: View {
    @Binding var selectedHex: String

    var body: some View {
        Menu {
            ForEach(Color.tagPalette, id: \.self) { hex in
                Button {
                    selectedHex = hex
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(hex: hex) ?? .accentColor)
                            .frame(width: 12, height: 12)
                        Text(hex)
                    }
                }
            }
        } label: {
            Circle()
                .fill(Color(hex: selectedHex) ?? .accentColor)
                .frame(width: 16, height: 16)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
