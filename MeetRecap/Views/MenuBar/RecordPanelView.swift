import SwiftUI

struct RecordPanelView: View {
    @ObservedObject var audioRecorder: AudioRecorder
    @ObservedObject var screenRecorder: ScreenRecorder
    @ObservedObject var audioDeviceManager: AudioDeviceManager
    @ObservedObject var meetingManager: MeetingManager
    
    @State private var recordScreen = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
                .padding(.vertical, 8)
            
            settingsSection
            
            Divider()
                .padding(.vertical, 8)
            
            controlSection
        }
        .padding(16)
        .frame(width: 300)
        .alert("Error", isPresented: $showError) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("MeetRecap")
                    .font(.headline)
                
                if audioRecorder.isRecording {
                    Text("Recording \(formatDuration(audioRecorder.currentDuration))")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .contentTransition(.numericText())
                } else {
                    Text("Ready to record")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if audioRecorder.isRecording {
                // Audio level indicator
                AudioLevelView(level: audioRecorder.audioLevel)
            }
        }
    }
    
    // MARK: - Settings
    
    private var settingsSection: some View {
        VStack(spacing: 12) {
            // Microphone picker
            HStack {
                Image(systemName: "mic")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                
                Text("Microphone")
                    .font(.subheadline)
                
                Spacer()
                
                Menu {
                    ForEach(audioDeviceManager.inputDevices) { device in
                        Button {
                            audioDeviceManager.selectedDevice = device
                        } label: {
                            HStack {
                                Text(device.name)
                                if device.isDefault {
                                    Text("(Default)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    Text(audioDeviceManager.selectedDevice?.name ?? "Select")
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(audioRecorder.isRecording)
            }
            
            // Screen recording toggle
            HStack {
                Image(systemName: "display")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                
                Text("Record screen")
                    .font(.subheadline)
                
                Spacer()
                
                Toggle("", isOn: $recordScreen)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(audioRecorder.isRecording)
            }
            
            // Model status
            if !meetingManager.isTranscriptionReady {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading transcription model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Controls
    
    private var controlSection: some View {
        VStack(spacing: 12) {
            if audioRecorder.isRecording {
                // Stop button
                Button {
                    stopRecording()
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                
                // Duration display
                Text(formatDuration(audioRecorder.currentDuration))
                    .font(.system(.title2, design: .monospaced, weight: .medium))
                    .foregroundStyle(.red)
                    .contentTransition(.numericText())
                
            } else {
                // Start button
                Button {
                    startRecording()
                } label: {
                    HStack {
                        Image(systemName: "record.circle")
                        Text("Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!meetingManager.isTranscriptionReady)
            }
            
            // Open dashboard link
            Button {
                openDashboard()
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text("Open Dashboard")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
    
    // MARK: - Actions
    
    private func startRecording() {
        do {
            try audioRecorder.startRecording(
                deviceID: audioDeviceManager.selectedDevice?.id
            )
            
            if recordScreen {
                Task {
                    try? await screenRecorder.startRecording()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func stopRecording() {
        let audioURL = audioRecorder.stopRecording()
        
        Task {
            var screenURL: URL? = nil
            if recordScreen {
                screenURL = await screenRecorder.stopRecording()
            }
            
            await meetingManager.finishRecording(
                audioURL: audioURL,
                screenRecordingURL: screenURL,
                duration: audioRecorder.currentDuration
            )
        }
    }
    
    private func openDashboard() {
        // Post notification to open dashboard window
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Level View

struct AudioLevelView: View {
    let level: Float
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(height: 20)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index) / 5.0
        return level > threshold ? CGFloat(4 + index * 3) : 4
    }
    
    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) / 5.0
        if level > threshold {
            if index < 3 { return .green }
            else if index < 4 { return .yellow }
            else { return .red }
        }
        return .gray.opacity(0.3)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openDashboard = Notification.Name("openDashboard")
}
