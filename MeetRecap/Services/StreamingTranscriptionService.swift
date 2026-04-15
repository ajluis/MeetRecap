import Foundation
import AVFoundation
import FluidAudio
import Combine

/// Thin wrapper around FluidAudio's `SlidingWindowAsrManager` for live, in-flight transcription.
///
/// Emits `confirmedTranscript` (stable) and `volatileTranscript` (tentative, may change)
/// as the audio tap streams buffers. The sliding-window manager handles all resampling
/// and windowing internally; we just feed it `AVAudioPCMBuffer`s as they arrive.
///
/// Live segments are ephemeral — after recording stops, the full-file transcription
/// + diarization replaces them entirely on the Meeting.
@MainActor
final class StreamingTranscriptionService: ObservableObject {
    @Published private(set) var confirmedTranscript: String = ""
    @Published private(set) var volatileTranscript: String = ""
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var recentUpdates: [LiveUpdate] = []

    struct LiveUpdate: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isConfirmed: Bool
        let timestamp: Date
    }

    private var manager: SlidingWindowAsrManager?
    private var updateTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Start a streaming session using already-loaded ASR models.
    func start(models: AsrModels) async {
        stop()

        let mgr = SlidingWindowAsrManager(config: .default)
        self.manager = mgr

        do {
            try await mgr.start(models: models, source: .microphone)
            isRunning = true
        } catch {
            print("[StreamingTranscriptionService] Failed to start: \(error)")
            self.manager = nil
            return
        }

        // Consume updates
        updateTask = Task { [weak self, manager = mgr] in
            let stream = await manager.transcriptionUpdates
            for await update in stream {
                await self?.handle(update: update)
            }
        }
    }

    /// Push a raw audio buffer into the streaming engine.
    /// Non-blocking — the sliding-window manager copies the data internally.
    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        Task { [weak self] in
            await self?.forward(buffer)
        }
    }

    private func forward(_ buffer: AVAudioPCMBuffer) async {
        guard let manager = manager else { return }
        await manager.streamAudio(buffer)  // actor-hop even though the call itself is sync
    }

    /// Stop the streaming session and clear displayed text.
    func stop() {
        updateTask?.cancel()
        updateTask = nil

        if let manager = manager {
            Task {
                await manager.cancel()
            }
        }
        manager = nil

        isRunning = false
        confirmedTranscript = ""
        volatileTranscript = ""
        recentUpdates = []
    }

    // MARK: - Updates

    private func handle(update: SlidingWindowTranscriptionUpdate) {
        if update.isConfirmed {
            if !confirmedTranscript.isEmpty {
                confirmedTranscript += " "
            }
            confirmedTranscript += update.text
            volatileTranscript = ""
        } else {
            volatileTranscript = update.text
        }

        let entry = LiveUpdate(
            text: update.text,
            isConfirmed: update.isConfirmed,
            timestamp: update.timestamp
        )
        recentUpdates.append(entry)
        if recentUpdates.count > 8 {
            recentUpdates.removeFirst(recentUpdates.count - 8)
        }
    }
}
