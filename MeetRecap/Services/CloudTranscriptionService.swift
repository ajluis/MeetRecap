import Foundation
import AVFoundation

/// Cloud transcription via Groq's OpenAI-compatible Whisper endpoint.
///
/// Uses `whisper-large-v3-turbo` — ~164x realtime, $0.04/hr, Whisper-quality accuracy.
/// Endpoint: POST https://api.groq.com/openai/v1/audio/transcriptions (multipart/form-data).
@MainActor
final class CloudTranscriptionService: ObservableObject {
    @Published var state: TranscriptionState = .idle

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let model = "whisper-large-v3-turbo"
    private let urlSession: URLSession

    /// Groq free tier caps upload at 25 MB. We aim comfortably below that when compressing.
    private let maxUploadBytes = 24 * 1024 * 1024

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Transcribe an audio file by uploading it to Groq. Compresses large files to
    /// 16 kHz mono AAC to stay under the upload limit while preserving accuracy.
    func transcribe(audioFileURL: URL) async throws -> TranscriptionResult {
        let apiKey = KeychainHelper.load(key: "meetrecap_groq_key") ?? ""
        guard !apiKey.isEmpty else {
            state = .failed("Missing Groq API key")
            throw CloudTranscriptionError.missingAPIKey
        }

        state = .transcribing(progress: nil)

        let uploadURL: URL
        var cleanupCompressedFile: URL?
        do {
            let (prepared, cleanup) = try await prepareUploadPayload(for: audioFileURL)
            uploadURL = prepared
            cleanupCompressedFile = cleanup
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        defer {
            if let url = cleanupCompressedFile {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            let payload = try buildMultipartBody(fileURL: uploadURL)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.addValue("multipart/form-data; boundary=\(payload.boundary)", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await urlSession.upload(for: request, from: payload.body)

            guard let http = response as? HTTPURLResponse else {
                throw CloudTranscriptionError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw CloudTranscriptionError.apiError(http.statusCode, msg)
            }

            let decoded = try JSONDecoder().decode(GroqResponse.self, from: data)
            let duration = AudioConverter.duration(of: audioFileURL) ?? decoded.duration ?? 0
            let segments = decoded.segments?.map { seg in
                TranscriptResultSegment(
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    startTime: seg.start,
                    endTime: seg.end,
                    speaker: nil,
                    confidence: seg.avg_logprob.map { Float(exp($0)) } ?? 0.9
                )
            } ?? [TranscriptResultSegment(
                text: decoded.text,
                startTime: 0,
                endTime: duration,
                speaker: nil,
                confidence: 0.9
            )]

            state = .completed
            return TranscriptionResult(
                segments: segments,
                fullText: decoded.text,
                duration: duration
            )
        } catch let error as CloudTranscriptionError {
            state = .failed(error.errorDescription ?? "Transcription failed")
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Light connectivity check — POSTs a tiny 1-second silence clip. Used by the
    /// "Test connection" button in Settings.
    func testConnection() async -> Result<Void, Error> {
        let apiKey = KeychainHelper.load(key: "meetrecap_groq_key") ?? ""
        guard !apiKey.isEmpty else {
            return .failure(CloudTranscriptionError.missingAPIKey)
        }
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetrecap_groq_test_\(UUID().uuidString).m4a")
            try writeSilentSample(to: tmp, durationSeconds: 1)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let payload = try buildMultipartBody(fileURL: tmp)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.addValue("multipart/form-data; boundary=\(payload.boundary)", forHTTPHeaderField: "Content-Type")

            let (data, response) = try await urlSession.upload(for: request, from: payload.body)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let msg = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
                return .failure(CloudTranscriptionError.apiError(code, msg))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Upload Preparation

    /// Returns a file URL safe to upload + an optional cleanup URL (if we had to
    /// compress to a temp file).
    private func prepareUploadPayload(for url: URL) async throws -> (upload: URL, cleanup: URL?) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 0 && size <= maxUploadBytes {
            return (url, nil)
        }
        // Compress: 16 kHz mono AAC in an .m4a container. Groq accepts m4a.
        let compressed = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetrecap_upload_\(UUID().uuidString).m4a")
        try await compressToM4A(inputURL: url, outputURL: compressed)
        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int) ?? 0
        if compressedSize > maxUploadBytes {
            try? FileManager.default.removeItem(at: compressed)
            throw CloudTranscriptionError.fileTooLarge(compressedSize)
        }
        return (compressed, compressed)
    }

    /// Compress any audio to 16 kHz mono AAC via AVAssetExportSession.
    private func compressToM4A(inputURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CloudTranscriptionError.compressionFailed("No exporter")
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a

        try? FileManager.default.removeItem(at: outputURL)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        if export.status != .completed {
            throw CloudTranscriptionError.compressionFailed(
                export.error?.localizedDescription ?? "status=\(export.status.rawValue)"
            )
        }
    }

    private func writeSilentSample(to url: URL, durationSeconds: Double) throws {
        let sampleRate: Double = 16000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CloudTranscriptionError.compressionFailed("audio format")
        }
        let frames = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CloudTranscriptionError.compressionFailed("pcm buffer")
        }
        buffer.frameLength = frames
        // Buffer is zero-initialized — silence.

        let tmpWav = url.deletingPathExtension().appendingPathExtension("wav")
        let wavFile = try AVAudioFile(forWriting: tmpWav, settings: format.settings)
        try wavFile.write(from: buffer)
        try compressToM4A_sync(inputURL: tmpWav, outputURL: url)
        try? FileManager.default.removeItem(at: tmpWav)
    }

    /// Synchronous variant used for the test-connection sample (1s silence).
    private func compressToM4A_sync(inputURL: URL, outputURL: URL) throws {
        let asset = AVURLAsset(url: inputURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CloudTranscriptionError.compressionFailed("No exporter")
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        try? FileManager.default.removeItem(at: outputURL)

        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()

        if export.status != .completed {
            throw CloudTranscriptionError.compressionFailed(
                export.error?.localizedDescription ?? "status=\(export.status.rawValue)"
            )
        }
    }

    // MARK: - Multipart Body

    private struct MultipartPayload {
        let boundary: String
        let body: Data
    }

    private func buildMultipartBody(fileURL: URL) throws -> MultipartPayload {
        let boundary = "meetrecap-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField("model", value: model)
        appendField("response_format", value: "verbose_json")
        appendField("temperature", value: "0")

        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let mimeType = Self.mimeType(for: fileURL.pathExtension.lowercased())

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return MultipartPayload(boundary: boundary, body: body)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Response Shape

private struct GroqResponse: Decodable {
    let text: String
    let duration: TimeInterval?
    let language: String?
    let segments: [Segment]?

    struct Segment: Decodable {
        let id: Int?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let avg_logprob: Double?
    }
}

// MARK: - Errors

enum CloudTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(Int, String)
    case fileTooLarge(Int)
    case compressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Groq API key in Settings → API Keys to use cloud transcription."
        case .invalidResponse:
            return "Invalid response from Groq"
        case .apiError(let code, let msg):
            return "Groq error (\(code)): \(msg)"
        case .fileTooLarge(let size):
            let mb = Double(size) / (1024 * 1024)
            return String(format: "Audio file is too large after compression (%.1f MB). Groq caps uploads at 25 MB.", mb)
        case .compressionFailed(let reason):
            return "Failed to compress audio: \(reason)"
        }
    }
}
