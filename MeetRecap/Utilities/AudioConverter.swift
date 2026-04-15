import Foundation
import AVFoundation
import CoreMedia

final class AudioConverter {
    
    enum ConversionError: LocalizedError {
        case fileNotFound(String)
        case formatConversionFailed
        case bufferAllocationFailed
        case invalidAudioFormat
        
        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "Audio file not found: \(path)"
            case .formatConversionFailed: return "Failed to convert audio format"
            case .bufferAllocationFailed: return "Failed to allocate audio buffer"
            case .invalidAudioFormat: return "Invalid audio format"
            }
        }
    }
    
    /// Target format: 16kHz mono float32 (required by Parakeet)
    static var targetFormat: AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create target audio format")
        }
        return format
    }
    
    /// Convert an audio file URL to 16kHz mono float samples
    func resampleAudioFile(_ url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.fileNotFound(url.path)
        }
        
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        let targetFormat = Self.targetFormat
        
        // If already in target format, read directly
        if inputFormat.sampleRate == targetFormat.sampleRate &&
           inputFormat.channelCount == targetFormat.channelCount &&
           inputFormat.commonFormat == .pcmFormatFloat32 {
            return try readDirectly(audioFile: audioFile)
        }
        
        // Convert to target format
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw ConversionError.formatConversionFailed
        }
        
        let frameCount = AVAudioFrameCount(
            Double(audioFile.length) * targetFormat.sampleRate / inputFormat.sampleRate
        )
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else {
            throw ConversionError.bufferAllocationFailed
        }
        
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        )!
        try audioFile.read(into: inputBuffer)
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            throw error
        }
        
        guard let floatChannelData = outputBuffer.floatChannelData else {
            throw ConversionError.invalidAudioFormat
        }
        
        return Array(UnsafeBufferPointer(
            start: floatChannelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }
    
    /// Convert audio file and write to a new WAV file at 16kHz mono
    func resampleAudioFileToWAV(inputURL: URL, outputURL: URL) throws {
        let samples = try resampleAudioFile(inputURL)
        try writeWAV(samples: samples, outputURL: outputURL, sampleRate: 16000)
    }
    
    /// Write float samples to a WAV file
    func writeWAV(samples: [Float], outputURL: URL, sampleRate: Double = 16000) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ConversionError.invalidAudioFormat
        }
        
        let audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings
        )
        
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        
        let channelData = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { ptr in
            channelData.update(from: ptr.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        
        try audioFile.write(from: buffer)
    }
    
    /// Read audio samples directly without conversion
    private func readDirectly(audioFile: AVAudioFile) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        )!
        try audioFile.read(into: buffer)
        
        guard let floatData = buffer.floatChannelData else {
            throw ConversionError.invalidAudioFormat
        }
        
        return Array(UnsafeBufferPointer(
            start: floatData[0],
            count: Int(buffer.frameLength)
        ))
    }
    
    /// Convert AVAudioPCMBuffer to [Float] (mono)
    static func bufferToFloats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
    }
    
    /// Get duration of an audio file in seconds
    static func duration(of url: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }
}
