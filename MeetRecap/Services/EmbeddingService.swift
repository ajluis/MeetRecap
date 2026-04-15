import Foundation

/// Generates text embeddings via OpenAI's embeddings API (`text-embedding-3-small`, 1536-dim).
/// Batches inputs and retries lightly. Output is a fixed-dim Float array suitable for cosine search.
actor EmbeddingService {
    static let shared = EmbeddingService()

    /// text-embedding-3-small — 1536 dims, cheap (~$0.02 / 1M tokens).
    static let dimension = 1536
    private let model = "text-embedding-3-small"
    private let endpoint = URL(string: "https://api.openai.com/v1/embeddings")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - API

    /// Embed a batch of strings. Returns embeddings in the same order.
    /// Throws if the API key is missing or the API returns an error.
    func embed(_ texts: [String], apiKey: String) async throws -> [[Float]] {
        guard !apiKey.isEmpty else { throw EmbeddingError.missingKey }
        guard !texts.isEmpty else { return [] }

        // Chunk to stay under input limits (OpenAI allows up to 2048 inputs but payload size matters).
        let maxBatch = 128
        var all: [[Float]] = []
        for chunkStart in stride(from: 0, to: texts.count, by: maxBatch) {
            let chunkEnd = min(chunkStart + maxBatch, texts.count)
            let chunk = Array(texts[chunkStart..<chunkEnd])
            let vectors = try await requestEmbeddings(chunk, apiKey: apiKey)
            all.append(contentsOf: vectors)
        }
        return all
    }

    /// Convenience for a single query string.
    func embed(_ text: String, apiKey: String) async throws -> [Float] {
        let result = try await embed([text], apiKey: apiKey)
        return result.first ?? []
    }

    // MARK: - Request

    private func requestEmbeddings(_ texts: [String], apiKey: String) async throws -> [[Float]] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "input": texts
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingError.badResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw EmbeddingError.api("Embeddings API error: \(msg)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.parseError
        }

        // Sort by returned index to preserve caller order.
        let sorted = dataArr.sorted { lhs, rhs in
            (lhs["index"] as? Int ?? 0) < (rhs["index"] as? Int ?? 0)
        }
        return sorted.compactMap { item -> [Float]? in
            guard let values = item["embedding"] as? [Double] else { return nil }
            return values.map { Float($0) }
        }
    }
}

// MARK: - Encoding helpers

enum EmbeddingCoding {
    /// Encode a 1D Float vector as Data (little-endian Float32).
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    /// Decode Data → [Float].
    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer.prefix(count))
        }
    }
}

// MARK: - Errors

enum EmbeddingError: LocalizedError {
    case missingKey
    case badResponse
    case api(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .missingKey: return "OpenAI API key required for embeddings"
        case .badResponse: return "Invalid embeddings API response"
        case .api(let msg): return msg
        case .parseError: return "Failed to parse embeddings response"
        }
    }
}
