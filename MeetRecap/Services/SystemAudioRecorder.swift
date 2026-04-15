import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

/// Captures system audio natively via `SCStream` — no BlackHole / Loopback / aggregate
/// device required.
///
/// Public surface intentionally mirrors `AudioRecorder` so `MeetingManager` can swap
/// between them via a simple flag in settings.
///
/// Notes:
///   - `capturesAudio = true` has been available since macOS 13; we resample to
///     16 kHz mono Float32 for consistency with Parakeet + the existing mic path.
///   - `excludesCurrentProcessAudio = true` prevents re-capture of anything the
///     app itself plays back (e.g. the review player).
@MainActor
final class SystemAudioRecorder: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var audioLevel: Float = 0.0

    /// Forwarded audio buffers (resampled to 16 kHz mono) for live transcription.
    /// Runs off the capture queue — keep it non-blocking.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var durationTimer: Timer?
    private var startedAt: Date?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// 16 kHz mono Float32 — matches everything downstream (file, ASR, streaming).
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }()

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var currentDuration: TimeInterval {
        if case .recording(let d) = state { return d }
        return 0
    }

    // MARK: - Availability

    /// Runtime check for whether system audio capture is usable on this Mac.
    /// Requires macOS 13+ and the Screen Recording permission.
    static var isAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    // MARK: - Recording

    /// Start system-audio-only capture. Writes a 16 kHz mono WAV into persistent storage.
    func startRecording() async throws {
        guard !isRecording else { return }

        // Need at least one display to stream from, even when we're only keeping audio.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplayAvailable
        }

        // Output file — persistent storage
        let url = AudioStorageManager.shared.newAudioURL(prefix: "sys_audio")
        outputFile = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        outputURL = url

        // Configure stream — system audio enabled, minimal video frame rate to save CPU.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // Bare-minimum video so SCStream accepts the config.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = try SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = stream

        let output = AudioStreamOutput { [weak self] buffer in
            self?.handle(rawBuffer: buffer)
        }
        self.streamOutput = output

        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        // Screen output still needs to be consumed even though we ignore it.
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .utility))

        try await stream.startCapture()

        startedAt = Date()
        state = .recording(duration: 0)
        startDurationTimer()
    }

    /// Stop capture and return the WAV file URL.
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        durationTimer?.invalidate()
        durationTimer = nil

        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        outputFile = nil

        let url = outputURL
        outputURL = nil
        state = .idle
        return url
    }

    // MARK: - Buffer handling

    private nonisolated func handle(rawBuffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.process(rawBuffer: rawBuffer)
        }
    }

    private func process(rawBuffer: AVAudioPCMBuffer) {
        // Lazily build a converter once we see the first buffer's format.
        if converter == nil || sourceFormat?.sampleRate != rawBuffer.format.sampleRate {
            sourceFormat = rawBuffer.format
            converter = AVAudioConverter(from: rawBuffer.format, to: targetFormat)
        }
        guard let converter = converter else { return }

        let ratio = targetFormat.sampleRate / rawBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(rawBuffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return rawBuffer
        }

        if let error = error {
            print("[SystemAudioRecorder] Convert failed: \(error)")
            return
        }
        guard output.frameLength > 0 else { return }

        // Write to file
        do {
            try outputFile?.write(from: output)
        } catch {
            print("[SystemAudioRecorder] Write failed: \(error)")
        }

        // Audio level (RMS -> 0..1)
        if let channelData = output.floatChannelData?[0] {
            let frameCount = Int(output.frameLength)
            var sum: Float = 0
            for i in 0..<frameCount {
                let s = channelData[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(max(frameCount, 1)))
            let db = 20 * log10(max(rms, 0.0001))
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { self.audioLevel = level }
        }

        // Forward to live transcription.
        onAudioBuffer?(output)
    }

    private func startDurationTimer() {
        let start = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let duration = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                self.state = .recording(duration: duration)
            }
        }
    }
}

// MARK: - Stream Output Handler

private final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let onAudioBuffer: (AVAudioPCMBuffer) -> Void

    init(onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onAudioBuffer = onAudioBuffer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        onAudioBuffer(buffer)
    }

    /// Convert a CMSampleBuffer from SCStream into an AVAudioPCMBuffer.
    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        // `streamDescription` needs an UnsafePointer — copy into a local var so we
        // have a mutable pointer regardless of asbdPtr's mutability.
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        // Copy raw audio data from the CMSampleBuffer into the AVAudioPCMBuffer's underlying storage.
        guard let abl = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let src = audioBufferList.mBuffers.mData else { return nil }
        let bytes = Int(audioBufferList.mBuffers.mDataByteSize)
        memcpy(abl, src, bytes)
        return buffer
    }
}

// MARK: - Errors

enum SystemAudioError: LocalizedError {
    case noDisplayAvailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable: return "No display available for system audio capture."
        case .permissionDenied:
            return "Screen recording permission is required for system audio capture."
        }
    }
}
