import Foundation
import AVFoundation
import Combine

enum RecordingState: Equatable {
    case idle
    case recording(duration: TimeInterval)
    case paused
    case processing
    case failed(String)
    
    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.paused, .paused), (.processing, .processing):
            return true
        case (.recording(let a), .recording(let b)):
            return Int(a) == Int(b)
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var audioLevel: Float = 0.0  // 0.0 to 1.0

    /// Called on each audio tap buffer. Used by StreamingTranscriptionService for live ASR.
    /// Runs on the audio tap thread — keep it non-blocking.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var selectedDeviceID: String?
    
    // Audio format for recording (44.1kHz mono float)
    private var recordingFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!
    }
    
    // Audio format for Parakeet (16kHz mono float)
    private var parakeetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }
    
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }
    
    var currentDuration: TimeInterval {
        if case .recording(let duration) = state { return duration }
        return 0
    }
    
    // MARK: - Recording
    
    /// Start recording with the specified audio device
    func startRecording(deviceID: String? = nil) throws {
        guard !isRecording else { return }
        
        self.selectedDeviceID = deviceID
        
        // Request microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    Task { @MainActor in
                        self.state = .failed("Microphone access denied")
                    }
                }
            }
            return
        default:
            throw AudioRecorderError.microphoneAccessDenied
        }
        
        // Create output file in persistent Application Support directory
        outputURL = AudioStorageManager.shared.newAudioURL()

        guard let outputURL = outputURL else {
            throw AudioRecorderError.fileCreationFailed
        }
        
        // Set up audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine
        
        let inputNode = engine.inputNode
        
        // Set input device if specified
        if let deviceID = deviceID {
            setInputDevice(deviceID: deviceID, for: inputNode)
        }
        
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Create output file
        outputFile = try AVAudioFile(forWriting: outputURL, settings: inputFormat.settings)
        
        // Install tap on input node with larger buffer for better quality
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,  // Larger buffer for better quality
            format: inputFormat
        ) { [weak self] buffer, time in
            self?.handleAudioBuffer(buffer)
            self?.onAudioBuffer?(buffer)
        }
        
        // Prepare and start engine
        engine.prepare()
        try engine.start()
        
        recordingStartTime = Date()
        state = .recording(duration: 0)
        
        // Start duration timer
        startDurationTimer()
    }
    
    /// Stop recording and return the audio file URL
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        
        durationTimer?.invalidate()
        durationTimer = nil
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        outputFile = nil
        
        let duration = currentDuration
        state = .idle
        
        return outputURL
    }
    
    func pauseRecording() {
        guard isRecording else { return }
        audioEngine?.pause()
        durationTimer?.invalidate()
        state = .paused
    }
    
    func resumeRecording() throws {
        guard case .paused = state else { return }
        try audioEngine?.start()
        startDurationTimer()
        state = .recording(duration: currentDuration)
    }
    
    // MARK: - Audio Processing
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Write to file
        do {
            try outputFile?.write(from: buffer)
        } catch {
            print("Failed to write audio buffer: \(error)")
        }
        
        // Calculate audio level for visualization
        guard let channelData = buffer.floatChannelData else { return }
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }

        // Calculate RMS for better level representation
        let sumSquares = channelDataValueArray.reduce(0) { $0 + $1 * $1 }
        let rms = sqrt(sumSquares / Float(buffer.frameLength))
        let avgPower = 20 * log10(max(rms, 0.0001))  // Avoid log(0)

        // Normalize to 0-1 range (-60dB to 0dB mapped)
        let normalizedLevel = max(0, min(1, (avgPower + 60) / 60))
        
        DispatchQueue.main.async {
            self.audioLevel = normalizedLevel
        }
    }
    
    private func startDurationTimer() {
        let startTime = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let duration = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                self.state = .recording(duration: duration)
            }
        }
    }
    
    private func setInputDevice(deviceID: String, for inputNode: AVAudioInputNode) {
        // Find the CoreAudio device ID from the unique ID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &propertySize
        ) == noErr else { return }
        
        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &propertySize, &deviceIDs
        ) == noErr else { return }
        
        for audioDeviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var deviceUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            
            guard AudioObjectGetPropertyData(
                audioDeviceID, &uidAddress, 0, nil, &uidSize, &deviceUID
            ) == noErr else { continue }
            
            if (deviceUID as String) == deviceID {
                // Set this as the input device
                var deviceIDValue = audioDeviceID
                let size = UInt32(MemoryLayout<AudioDeviceID>.size)
                var setterAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &setterAddress, 0, nil, size, &deviceIDValue
                )
                break
            }
        }
    }
}

// MARK: - Errors

enum AudioRecorderError: LocalizedError {
    case microphoneAccessDenied
    case fileCreationFailed
    case engineStartFailed
    
    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access denied. Please enable in System Settings > Privacy & Security > Microphone."
        case .fileCreationFailed:
            return "Failed to create recording file"
        case .engineStartFailed:
            return "Failed to start audio engine"
        }
    }
}
