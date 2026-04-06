import AVFoundation

/// Audio format constants for the wire protocol and processing pipeline.
/// Nonisolated so constants are accessible from any context (audio thread, locks).
nonisolated enum AudioConstants {
    /// Wire format: 16 kHz mono
    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1

    /// 20ms frames = 320 samples at 16 kHz
    static let frameDurationMs: Int = 20
    static let samplesPerFrame: Int = 320

    /// Bytes per sample on wire (Int16 = 2 bytes)
    static let bytesPerSample: Int = 2
    static let frameByteSize: Int = samplesPerFrame * bytesPerSample // 640

    /// Processing format: Float32 at 16 kHz mono (used by AVAudioEngine)
    static let processingFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    )!

    /// Wire format: Int16 at 16 kHz mono
    static let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: true
    )!
}
