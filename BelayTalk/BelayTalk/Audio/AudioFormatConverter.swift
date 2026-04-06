@preconcurrency import AVFoundation
import OSLog

/// Converts audio between processing format (Float32) and wire format (Int16),
/// with optional sample rate conversion between hardware native and 16 kHz.
nonisolated final class AudioFormatConverter: @unchecked Sendable {

    /// Convert Float32 PCM buffer to Int16 wire data
    static func float32ToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let floatData = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        var data = Data(count: frameCount * AudioConstants.bytesPerSample)

        data.withUnsafeMutableBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                int16Ptr[i] = Int16(clamped * Float(Int16.max))
            }
        }
        return data
    }

    /// Convert Int16 wire data to Float32 PCM buffer
    static func int16DataToFloat32(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = data.count / AudioConstants.bytesPerSample
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: AudioConstants.processingFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              )
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let floatData = buffer.floatChannelData?[0] else { return nil }

        data.withUnsafeBytes { rawBuffer in
            guard let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                floatData[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }
        return buffer
    }

    /// Convert a buffer from one sample rate to another using AVAudioConverter
    static func convertSampleRate(
        from inputBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            Log.audio.error("Failed to create sample rate converter")
            return nil
        }

        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * ratio
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            Log.audio.error("Sample rate conversion failed: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    /// Generate a silence buffer of the standard frame size
    static func silenceBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AudioConstants.processingFormat,
            frameCapacity: AVAudioFrameCount(AudioConstants.samplesPerFrame)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(AudioConstants.samplesPerFrame)
        // Buffer is zero-initialized by default — silence
        return buffer
    }
}
