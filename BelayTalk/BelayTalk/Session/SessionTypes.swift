import Foundation

// MARK: - Session State Machine

/// Main session lifecycle states
nonisolated enum SessionState: String, Sendable {
    case idle
    case permissions
    case ready
    case connecting
    case active
    case reconnecting
    case interrupted
    case routeFailed
    case ended
}

// MARK: - TX State

/// Transmit state for the local audio pipeline
nonisolated enum TXState: String, Sendable {
    case disabled
    case armed       // VAD listening, not yet triggered
    case live        // Actively transmitting
    case holdOpen    // Open mic — always transmitting
    case muted       // User-initiated mute
}

// MARK: - TX Mode

/// Transmit mode selected by the user
nonisolated enum TXMode: String, Codable, CaseIterable, Sendable {
    case openMic     // Continuous TX + RX
    case voiceTX     // VAD-gated TX, always RX (default)
    case manualTX    // User-toggled TX, always RX

    var label: String {
        switch self {
        case .openMic: "Open Mic"
        case .voiceTX: "Voice TX"
        case .manualTX: "Manual TX"
        }
    }
}

// MARK: - Route State

/// Current audio route state
nonisolated enum RouteState: String, Sendable {
    case bluetooth
    case builtIn
    case wired
    case changing
    case unavailable
}

// MARK: - Connection Role

/// Role in the peer-to-peer session
nonisolated enum ConnectionRole: String, Sendable {
    case host
    case guest
}
