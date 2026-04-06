import Foundation
import OSLog

/// Handshake state machine: HELLO → HELLO_ACK → CAPS → READY → START
///
/// 5-second timeout per step. Version/capability validation during CAPS exchange.
nonisolated final class HandshakeManager: @unchecked Sendable {
    enum HandshakeState: String, Sendable {
        case idle
        case sentHello
        case sentHelloAck
        case sentCaps
        case sentReady
        case completed
        case failed
    }

    enum HandshakeError: Error, Sendable {
        case timeout
        case versionMismatch
        case codecMismatch
        case unexpectedMessage(String)
    }

    private let transport: PeerTransport
    private let isHost: Bool
    private let stepTimeout: TimeInterval = 5.0

    private(set) var state: HandshakeState = .idle
    private(set) var remoteCaps: Capabilities?

    private var timeoutTask: Task<Void, Never>?
    private var completion: ((Result<Capabilities, HandshakeError>) -> Void)?

    init(transport: PeerTransport, isHost: Bool) {
        self.transport = transport
        self.isHost = isHost
    }

    // MARK: - Start Handshake

    func start(completion: @escaping (Result<Capabilities, HandshakeError>) -> Void) {
        self.completion = completion
        state = .idle

        if isHost {
            // Host waits for HELLO from guest
            startTimeout()
        } else {
            // Guest sends HELLO
            transport.sendControl(ControlFrame(message: .hello))
            state = .sentHello
            startTimeout()
            Log.transport.info("Handshake: sent HELLO")
        }
    }

    // MARK: - Process Incoming

    func receive(_ frame: ControlFrame) {
        cancelTimeout()

        switch (state, frame.message, isHost) {

        // Host receives HELLO → sends HELLO_ACK
        case (.idle, .hello, true):
            transport.sendControl(ControlFrame(message: .helloAck))
            state = .sentHelloAck
            startTimeout()
            Log.transport.info("Handshake: received HELLO, sent HELLO_ACK")

        // Guest receives HELLO_ACK → sends CAPS
        case (.sentHello, .helloAck, false):
            sendCaps()
            state = .sentCaps
            startTimeout()
            Log.transport.info("Handshake: received HELLO_ACK, sent CAPS")

        // Host receives CAPS → validates → sends CAPS + READY
        case (.sentHelloAck, .caps, true):
            guard let caps = decodeCaps(from: frame) else {
                fail(.unexpectedMessage("Invalid CAPS payload"))
                return
            }
            guard validateCaps(caps) else { return }
            remoteCaps = caps
            sendCaps()
            transport.sendControl(ControlFrame(message: .ready))
            state = .sentReady
            startTimeout()
            Log.transport.info("Handshake: received CAPS, sent CAPS + READY")

        // Guest receives CAPS
        case (.sentCaps, .caps, false):
            guard let caps = decodeCaps(from: frame) else {
                fail(.unexpectedMessage("Invalid CAPS payload"))
                return
            }
            guard validateCaps(caps) else { return }
            remoteCaps = caps
            Log.transport.info("Handshake: received CAPS from host")

        // Guest receives READY → sends START
        case (.sentCaps, .ready, false):
            transport.sendControl(ControlFrame(message: .start))
            state = .completed
            Log.transport.info("Handshake: received READY, sent START — complete")
            succeed()

        // Host receives START → complete
        case (.sentReady, .start, true):
            state = .completed
            Log.transport.info("Handshake: received START — complete")
            succeed()

        default:
            Log.transport.warning("Handshake: unexpected \(frame.message.rawValue) in state \(self.state.rawValue)")
        }
    }

    // MARK: - Caps Encoding

    private func sendCaps() {
        let caps = Capabilities.current
        if let data = try? JSONEncoder().encode(caps),
           let json = String(data: data, encoding: .utf8) {
            transport.sendControl(ControlFrame(
                message: .caps,
                payload: ["capabilities": json]
            ))
        }
    }

    private func decodeCaps(from frame: ControlFrame) -> Capabilities? {
        guard let json = frame.payload?["capabilities"],
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Capabilities.self, from: data)
    }

    private func validateCaps(_ caps: Capabilities) -> Bool {
        if caps.protocolVersion != Capabilities.current.protocolVersion {
            Log.transport.error("Version mismatch: remote=\(caps.protocolVersion), local=\(Capabilities.current.protocolVersion)")
            fail(.versionMismatch)
            return false
        }

        let commonCodecs = Set(caps.supportedCodecs).intersection(Capabilities.current.supportedCodecs)
        if commonCodecs.isEmpty {
            Log.transport.error("No common codecs")
            fail(.codecMismatch)
            return false
        }

        return true
    }

    // MARK: - Timeout

    private func startTimeout() {
        timeoutTask = Task { [weak self, stepTimeout] in
            try? await Task.sleep(for: .seconds(stepTimeout))
            guard !Task.isCancelled else { return }
            self?.fail(.timeout)
        }
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // MARK: - Completion

    private func succeed() {
        cancelTimeout()
        let caps = remoteCaps ?? Capabilities.current
        completion?(.success(caps))
        completion = nil
    }

    private func fail(_ error: HandshakeError) {
        cancelTimeout()
        state = .failed
        Log.transport.error("Handshake failed: \(String(describing: error))")
        completion?(.failure(error))
        completion = nil
    }

    func reset() {
        cancelTimeout()
        state = .idle
        remoteCaps = nil
        completion = nil
    }
}
