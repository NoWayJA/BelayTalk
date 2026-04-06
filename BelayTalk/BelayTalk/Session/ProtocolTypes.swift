import Foundation

// MARK: - Frame Type

/// Discriminator byte for wire frames
nonisolated enum FrameType: UInt8, Sendable {
    case control = 0x00
    case audio   = 0x01
}

// MARK: - Audio Codec

/// Codec identifier carried in audio frame headers
nonisolated enum AudioCodec: UInt8, Codable, Sendable {
    case pcmInt16 = 0x01
}

// MARK: - Audio Frame Header

/// Binary header for audio frames — 19 bytes on wire.
///
/// Layout:
/// ```
/// [0..3]   sequenceNumber  UInt32
/// [4..11]  timestamp       UInt64 (mach_absolute_time)
/// [12]     codec           UInt8
/// [13..14] sampleRate      UInt16
/// [15..16] durationMs      UInt16
/// [17]     txState         UInt8
/// [18]     reserved        UInt8
/// ```
nonisolated struct AudioFrameHeader: Sendable {
    var sequenceNumber: UInt32
    var timestamp: UInt64
    var codec: AudioCodec
    var sampleRate: UInt16
    var durationMs: UInt16
    var txState: UInt8
    var reserved: UInt8

    static let size = 19
}

// MARK: - Control Messages

/// Control message types for the signaling channel
nonisolated enum ControlMessage: String, Codable, Sendable {
    case hello
    case helloAck
    case caps
    case ready
    case start
    case txOn
    case txOff
    case modeChange
    case routeChanged
    case ping
    case pong
    case reconnecting
    case endSession
}

/// JSON-encoded control frame sent over the reliable channel
nonisolated struct ControlFrame: Codable, Sendable {
    let message: ControlMessage
    let payload: [String: String]?

    init(message: ControlMessage, payload: [String: String]? = nil) {
        self.message = message
        self.payload = payload
    }
}

// MARK: - Capabilities

/// Device/app capabilities exchanged during the handshake CAPS step
nonisolated struct Capabilities: Codable, Sendable {
    let protocolVersion: Int
    let appVersion: String
    let supportedCodecs: [AudioCodec]
    let sampleRate: Int
    let frameDurationMs: Int

    static let current = Capabilities(
        protocolVersion: 1,
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        supportedCodecs: [.pcmInt16],
        sampleRate: 16_000,
        frameDurationMs: 20
    )
}

// MARK: - Events

/// Audio session interruption events
nonisolated enum InterruptionEvent: Sendable {
    case began
    case ended(shouldResume: Bool)
}

/// Remote control (headset button) events
nonisolated enum RemoteControlEvent: Sendable {
    case toggleTX
}
