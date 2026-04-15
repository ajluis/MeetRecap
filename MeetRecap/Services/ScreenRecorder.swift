import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Combine

@MainActor
final class ScreenRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedDisplay: SCDisplay?
    
    private var stream: SCStream?
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var streamOutput: StreamOutput?
    
    init() {
        Task {
            await refreshAvailableContent()
        }
    }
    
    // MARK: - Content Discovery
    
    func refreshAvailableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            availableDisplays = content.displays
            availableWindows = content.windows
            
            if selectedDisplay == nil {
                selectedDisplay = content.displays.first
            }
        } catch {
            print("Failed to get shareable content: \(error)")
        }
    }
    
    // MARK: - Recording
    
    func startRecording(display: SCDisplay? = nil) async throws {
        guard !isRecording else { return }
        
        let targetDisplay = display ?? selectedDisplay ?? availableDisplays.first
        guard let targetDisplay = targetDisplay else {
            throw ScreenRecorderError.noDisplayAvailable
        }
        
        // Check screen capture permission
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenRecorderError.screenRecordingDenied
        }
        
        // Create output file in persistent Application Support directory
        outputURL = AudioStorageManager.shared.newScreenRecordingURL()

        guard let outputURL = outputURL else {
            throw ScreenRecorderError.fileCreationFailed
        }
        
        // Configure stream
        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        
        let configuration = SCStreamConfiguration()
        configuration.width = targetDisplay.width
        configuration.height = targetDisplay.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps
        configuration.showsCursor = true
        configuration.capturesAudio = false  // Audio captured separately via AVAudioEngine
        
        // Create and start stream
        stream = try SCStream(filter: filter, configuration: configuration, delegate: nil)
        
        // Set up video writer
        videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetDisplay.width,
            AVVideoHeightKey: targetDisplay.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true
        
        if let writer = videoWriter, let input = videoWriterInput {
            writer.add(input)
        }
        
        // Create stream output handler
        streamOutput = StreamOutput(
            videoWriter: videoWriter,
            videoWriterInput: videoWriterInput
        )
        
        // Add stream output
        try stream?.addStreamOutput(
            streamOutput!,
            type: .screen,
            sampleHandlerQueue: .global(qos: .userInteractive)
        )
        
        // Start capture
        try await stream?.startCapture()
        
        // Start writing
        videoWriter?.startWriting()
        videoWriter?.startSession(atSourceTime: CMTime.zero)
        
        isRecording = true
    }
    
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        
        // Stop stream capture
        try? await stream?.stopCapture()
        stream = nil
        
        // Finish writing
        videoWriterInput?.markAsFinished()
        await videoWriter?.finishWriting()
        videoWriter = nil
        videoWriterInput = nil
        streamOutput = nil
        
        isRecording = false
        
        return outputURL
    }
}

// MARK: - Stream Output Handler

private class StreamOutput: NSObject, SCStreamOutput {
    private let videoWriter: AVAssetWriter?
    private let videoWriterInput: AVAssetWriterInput?
    private var frameCount: Int64 = 0
    
    init(videoWriter: AVAssetWriter?, videoWriterInput: AVAssetWriterInput?) {
        self.videoWriter = videoWriter
        self.videoWriterInput = videoWriterInput
    }
    
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        guard let writerInput = videoWriterInput,
              writerInput.isReadyForMoreMediaData else {
            return
        }
        
        writerInput.append(sampleBuffer)
        frameCount += 1
    }
}

// MARK: - Errors

enum ScreenRecorderError: LocalizedError {
    case noDisplayAvailable
    case screenRecordingDenied
    case fileCreationFailed
    case streamStartFailed
    
    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for recording"
        case .screenRecordingDenied:
            return "Screen recording permission denied. Please enable in System Settings > Privacy & Security > Screen Recording."
        case .fileCreationFailed:
            return "Failed to create screen recording file"
        case .streamStartFailed:
            return "Failed to start screen capture stream"
        }
    }
}
