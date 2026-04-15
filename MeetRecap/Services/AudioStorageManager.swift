import Foundation
import SwiftData

/// Manages persistent storage for audio and video recordings.
///
/// Stores files in `~/Library/Application Support/MeetRecap/Recordings/` so they
/// survive across reboots and aren't wiped by the OS (unlike the temp dir).
@MainActor
final class AudioStorageManager {
    static let shared = AudioStorageManager()

    private let fileManager = FileManager.default

    /// Root directory for all MeetRecap recordings.
    let recordingsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let root = appSupport.appendingPathComponent("MeetRecap", isDirectory: true)
        self.recordingsDirectory = root.appendingPathComponent("Recordings", isDirectory: true)

        ensureDirectoryExists()
    }

    // MARK: - Directory Setup

    private func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: recordingsDirectory.path) {
            try? fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    // MARK: - New Recording URLs

    /// Generate a URL for a new audio recording (WAV).
    func newAudioURL(prefix: String = "recording") -> URL {
        ensureDirectoryExists()
        let fileName = "\(prefix)_\(UUID().uuidString).wav"
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    /// Generate a URL for a new screen recording (MOV).
    func newScreenRecordingURL(prefix: String = "screen") -> URL {
        ensureDirectoryExists()
        let fileName = "\(prefix)_\(UUID().uuidString).mov"
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    // MARK: - File Management

    /// Delete a file at the given URL. Silent if the file doesn't exist.
    func deleteFile(at url: URL?) {
        guard let url = url else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Return the total on-disk size of all recordings in bytes.
    func totalRecordingsSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Check whether a file exists at the given URL.
    func fileExists(at url: URL?) -> Bool {
        guard let url = url else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    // MARK: - Migration

    /// Migrate audio/screen recordings from the temp dir into the persistent directory.
    ///
    /// Runs once per meeting on app launch. For each meeting whose bookmark resolves
    /// to a temp-dir location (or fails to resolve), the file is copied into the
    /// persistent directory and the bookmark updated. Meetings with files already in
    /// the persistent directory or whose files are truly gone are left alone.
    func migrateMeetingsFromTempDirectory(modelContext: ModelContext) {
        let tempPath = fileManager.temporaryDirectory.path

        let descriptor = FetchDescriptor<Meeting>()
        guard let meetings = try? modelContext.fetch(descriptor) else { return }

        var mutated = false
        for meeting in meetings {
            mutated = migrateAudio(for: meeting, tempPath: tempPath) || mutated
            mutated = migrateScreenRecording(for: meeting, tempPath: tempPath) || mutated
        }

        if mutated {
            try? modelContext.save()
        }
    }

    private func migrateAudio(for meeting: Meeting, tempPath: String) -> Bool {
        guard let bookmark = meeting.audioFileBookmark else { return false }

        var isStale = false
        let resolvedURL = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)

        // Case 1: already pointing at our persistent directory, nothing to do
        if let url = resolvedURL, url.path.hasPrefix(recordingsDirectory.path) {
            return false
        }

        // Case 2: URL resolves, but it's in temp — copy and update bookmark
        if let url = resolvedURL, url.path.hasPrefix(tempPath), fileManager.fileExists(atPath: url.path) {
            let newURL = recordingsDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if !fileManager.fileExists(atPath: newURL.path) {
                    try fileManager.copyItem(at: url, to: newURL)
                }
                meeting.audioFileBookmark = try newURL.bookmarkData()
                meeting.audioStoragePath = newURL.path
                return true
            } catch {
                print("[AudioStorageManager] Failed to migrate audio for meeting \(meeting.id): \(error)")
                return false
            }
        }

        // Case 3: bookmark couldn't be resolved — try the fallback path if present
        if let path = meeting.audioStoragePath, fileManager.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            meeting.audioFileBookmark = try? url.bookmarkData()
            return meeting.audioFileBookmark != nil
        }

        return false
    }

    private func migrateScreenRecording(for meeting: Meeting, tempPath: String) -> Bool {
        guard let bookmark = meeting.screenRecordingBookmark else { return false }

        var isStale = false
        let resolvedURL = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)

        if let url = resolvedURL, url.path.hasPrefix(recordingsDirectory.path) {
            return false
        }

        if let url = resolvedURL, url.path.hasPrefix(tempPath), fileManager.fileExists(atPath: url.path) {
            let newURL = recordingsDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if !fileManager.fileExists(atPath: newURL.path) {
                    try fileManager.copyItem(at: url, to: newURL)
                }
                meeting.screenRecordingBookmark = try newURL.bookmarkData()
                return true
            } catch {
                print("[AudioStorageManager] Failed to migrate screen recording for meeting \(meeting.id): \(error)")
                return false
            }
        }

        return false
    }
}
