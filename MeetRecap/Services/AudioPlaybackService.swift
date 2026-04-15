import Foundation
import AVFoundation
import Combine

/// Simple audio playback service built on `AVAudioPlayer`.
///
/// Publishes `currentTime` at ~15 Hz so SwiftUI can animate a playhead and
/// highlight the active transcript segment without starving the main thread.
@MainActor
final class AudioPlaybackService: NSObject, ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0 {
        didSet {
            player?.rate = playbackRate
        }
    }

    /// URL of the currently loaded file, nil if nothing is loaded.
    private(set) var currentURL: URL?

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    // MARK: - Loading

    /// Load an audio file. Stops any existing playback. Returns false if the file can't be read.
    @discardableResult
    func load(url: URL) -> Bool {
        if currentURL == url, player != nil {
            return true
        }

        stop()

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.enableRate = true
            newPlayer.prepareToPlay()
            newPlayer.delegate = self
            newPlayer.rate = playbackRate

            self.player = newPlayer
            self.currentURL = url
            self.duration = newPlayer.duration
            self.currentTime = 0
            return true
        } catch {
            print("[AudioPlaybackService] Failed to load audio: \(error)")
            self.player = nil
            self.currentURL = nil
            self.duration = 0
            return false
        }
    }

    // MARK: - Transport

    func play() {
        guard let player = player else { return }
        player.rate = playbackRate  // enableRate requires rate set after play()
        player.play()
        isPlaying = true
        startProgressTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopProgressTimer()
    }

    /// Seek to an absolute time, clamped to the file duration.
    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let clamped = max(0, min(time, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Seek to `time` and begin playback.
    func seekAndPlay(to time: TimeInterval) {
        seek(to: time)
        play()
    }

    // MARK: - Progress

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        if let progressTimer = progressTimer {
            RunLoop.main.add(progressTimer, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = player.duration
            self.stopProgressTimer()
        }
    }
}
