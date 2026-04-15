import SwiftUI

struct MenuBarView: View {
    @ObservedObject var audioRecorder: AudioRecorder
    @Binding var showRecordPanel: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: audioRecorder.isRecording ? "mic.fill" : "mic")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(audioRecorder.isRecording ? .red : .primary)
                .symbolEffect(.pulse, isActive: audioRecorder.isRecording)
            
            if audioRecorder.isRecording {
                Text(formatDuration(audioRecorder.currentDuration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .onTapGesture {
            showRecordPanel.toggle()
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
