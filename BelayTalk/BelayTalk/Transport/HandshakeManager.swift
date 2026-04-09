import Foundation
import OSLog
import os

/// Handshake state machine: HELLO → HELLO_ACK → CAPS → READY → START
///
/// 5-second timeout per step. Version/capability validation during CAPS exchange.
/// All mutable state is protected by a lock for thread safety.
nonisolated final class HandshakeManager: @unchecked Sendable {
    enum HandshakeState: String, Sendable {
        case idle
        case sentHello
        case sentHelloAck
        case sentCaps
        case receivedCaps  // Guest: received CAPS from host, waiting for READY
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

    private let lock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())
    private struct MutableState {
        var state: HandshakeState = .idle
        var remoteCaps: Capabilities?
        var timeoutTask: Task<Void, Never>?
        var completion: ((Result<Capabilities, HandshakeError>) -> Void)?
    }

    var state: HandshakeState {
        lock.withLock { $0.state }
    }

    init(transport: PeerTransport, isHost: Bool) {
        self.transport = transport
        self.isHost = isHost
    }

    // MARK: - Start Handshake

    func start(completion: @escaping (Result<Capabilities, HandshakeError>) -> Void) {
        lock.withLock { state in
            state.completion = completion
            state.state = .idle
        }

        if isHost {
            // Host waits for HELLO from guest
            startTimeout()
        } else {
            // Guest sends HELLO
            transport.sendControl(ControlFrame(message: .hello))
            lock.withLock { $0.state = .sentHello }
            startTimeout()
            Log.transport.info("Handshake: sent HELLO")
        }
    }

    // MARK: - Process Incoming

    func receive(_ frame: ControlFrame) {
        cancelTimeout()

        let currentState = lock.withLock { $0.state }

        switch (currentState, frame.message, isHost) {

        // Host receives HELLO → sends HELLO_ACK
        case (.idle, .hello, true):
            transport.sendControl(ControlFrame(message: .helloAck))
            lock.withLock { $0.state = .sentHelloAck }
            startTimeout()
            Log.transport.info("Handshake: received HELLO, sent HELLO_ACK")

        // Guest receives HELLO_ACK → sends CAPS
        case (.sentHello, .helloAck, false):
            sendCaps()
            lock.withLock { $0.state = .sentCaps }
            startTimeout()
            Log.transport.info("Handshake: received HELLO_ACK, sent CAPS")

        // Host receives CAPS → validates → sends CAPS + READY
        case (.sentHelloAck, .caps, true):
            guard let caps = decodeCaps(from: frame) else {
                fail(.unexpectedMessage("Invalid CAPS payload"))
                return
            }
            guard validateCaps(caps) else { return }
            lock.withLock { $0.remoteCaps = caps }
            sendCaps()
            transport.sendControl(ControlFrame(message: .ready))
            lock.withLock { $0.state = .sentReady }
            startTimeout()
            Log.transport.info("Handshake: received CAPS, sent CAPS + READY")

        // Guest receives CAPS → transition to .receivedCaps
        case (.sentCaps, .caps, false):
            guard let caps = decodeCaps(from: frame) else {
                fail(.unexpectedMessage("Invalid CAPS payload"))
                return
            }
            guard validateCaps(caps) else { return }
            lock.withLock { state in
                state.remoteCaps = caps
                state.state = .receivedCaps
            }
            startTimeout()
            Log.transport.info("Handshake: received CAPS from host")

        // Guest receives READY (after CAPS) → sends START
        case (.receivedCaps, .ready, false):
            transport.sendControl(ControlFrame(message: .start))
            lock.withLock { $0.state = .completed }
            Log.transport.info("Handshake: received READY, sent START — complete")
            succeed()

        // Guest receives READY before CAPS (CAPS and READY sent back-to-back)
        // This handles the case where reliable messages arrive in order but
        // we haven't processed CAPS yet due to timing
        case (.sentCaps, .ready, false):
            Log.transport.warning("Handshake: READY received before CAPS — CAPS validation skipped")
            transport.sendControl(ControlFrame(message: .start))
            lock.withLock { $0.state = .completed }
            Log.transport.info("Handshake: received READY (before CAPS), sent START — complete")
            succeed()

        // Host receives START → complete
        case (.sentReady, .start, true):
            lock.withLock { $0.state = .completed }
            Log.transport.info("Handshake: received START — complete")
            succeed()

        default:
            Log.transport.warning("Handshake: unexpected \(frame.message.rawValue) in state \(currentState.rawValue)")
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
        let task = Task { [weak self, stepTimeout] in
            try? await Task.sleep(for: .seconds(stepTimeout))
            guard !Task.isCancelled else { return }
            self?.fail(.timeout)
        }
        lock.withLock { $0.timeoutTask = task }
    }

    private func cancelTimeout() {
        lock.withLock { state in
            state.timeoutTask?.cancel()
            state.timeoutTask = nil
        }
    }

    // MARK: - Completion

    private func succeed() {
        cancelTimeout()
        let (caps, completion) = lock.withLock { state -> (Capabilities, ((Result<Capabilities, HandshakeError>) -> Void)?) in
            let c = state.remoteCaps ?? Capabilities.current
            let cb = state.completion
            state.completion = nil
            return (c, cb)
        }
        completion?(.success(caps))
    }

    private func fail(_ error: HandshakeError) {
        cancelTimeout()
        let completion = lock.withLock { state -> ((Result<Capabilities, HandshakeError>) -> Void)? in
            guard state.state != .failed else { return nil }  // Prevent double-fire
            state.state = .failed
            let cb = state.completion
            state.completion = nil
            return cb
        }
        Log.transport.error("Handshake failed: \(String(describing: error))")
        completion?(.failure(error))
    }

    func reset() {
        let completion = lock.withLock { state -> ((Result<Capabilities, HandshakeError>) -> Void)? in
            state.timeoutTask?.cancel()
            state.timeoutTask = nil
            let cb = state.completion
            state.state = .idle
            state.remoteCaps = nil
            state.completion = nil
            return cb
        }
        // Notify any waiting caller that the handshake was cancelled
        completion?(.failure(.timeout))
    }
}
