import SwiftUI

/// Horizontal audio player bar: play/pause, seek slider, playback speed.
struct AudioPlayerBarView: View {
    @ObservedObject var playback: AudioPlaybackService

    @State private var isDraggingSlider = false
    @State private var draggedTime: TimeInterval = 0

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        HStack(spacing: 12) {
            // Play / pause
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(playback.duration == 0)

            // Current time
            Text(formatTime(isDraggingSlider ? draggedTime : playback.currentTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            // Seek slider
            Slider(
                value: Binding(
                    get: { isDraggingSlider ? draggedTime : playback.currentTime },
                    set: { newValue in
                        draggedTime = newValue
                    }
                ),
                in: 0...max(playback.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        draggedTime = playback.currentTime
                        isDraggingSlider = true
                    } else {
                        playback.seek(to: draggedTime)
                        isDraggingSlider = false
                    }
                }
            )
            .disabled(playback.duration == 0)

            // Duration
            Text(formatTime(playback.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            // Speed picker
            Menu {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        playback.playbackRate = speed
                    } label: {
                        if speed == playback.playbackRate {
                            Label("\(speedLabel(speed))×", systemImage: "checkmark")
                        } else {
                            Text("\(speedLabel(speed))×")
                        }
                    }
                }
            } label: {
                Text("\(speedLabel(playback.playbackRate))×")
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 36)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && !time.isNaN else { return "0:00" }
        let totalSeconds = max(0, Int(time))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func speedLabel(_ speed: Float) -> String {
        if speed == floor(speed) {
            return String(format: "%.0f", speed)
        }
        return String(format: "%.2g", speed)
    }
}
