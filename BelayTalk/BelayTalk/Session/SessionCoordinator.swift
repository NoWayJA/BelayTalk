import AVFoundation
import MultipeerConnectivity
import OSLog

/// Top-level orchestrator that owns all modules and manages the session lifecycle.
///
/// Manages session state machine, TX state per mode, and bridges all module
/// events to the UI via `@Observable` properties.
@Observable
final class SessionCoordinator {
    // MARK: - Observable State

    private(set) var sessionState: SessionState = .idle
    private(set) var txState: TXState = .disabled
    private(set) var routeState: RouteState = .unavailable
    private(set) var connectedPeerName: String?
    private(set) var role: ConnectionRole?

    let metrics = SessionMetrics()
    let settings = AppSettings()

    // MARK: - Modules

    let transport = PeerTransport()
    private let audioEngine = AudioEngine()
    private let routeManager = RouteManager()
    private let vad = VoiceActivityDetector()
    private let remoteControl = RemoteControlHandler()
    private let recovery = RecoverySupervisor()
    private var handshake: HandshakeManager?

    // MARK: - Task Management

    private var monitorTasks: [Task<Void, Never>] = []
    private var reconnectionAttempted = false

    init() {
        audioEngine.delegate = self
        transport.delegate = self
        vad.updateSettings(
            sensitivity: settings.vadSensitivity,
            hangTime: settings.hangTime,
            windRejection: settings.windRejection
        )
    }

    // MARK: - Session Lifecycle

    func requestPermissions() async -> Bool {
        sessionState = .permissions
        let granted = await AVAudioApplication.requestRecordPermission()
        if granted {
            // Pre-configure audio session so route changes settle before MC connects.
            // Activating .voiceChat mode after MC is connected can disrupt the radio stack.
            do {
                try routeManager.configureSession()
                Log.session.info("Audio session pre-configured, route: \(self.routeManager.currentRoute.rawValue)")
            } catch {
                Log.session.warning("Audio session pre-configure failed: \(error.localizedDescription)")
            }
            sessionState = .ready
            Log.session.info("Microphone permission granted")
        } else {
            sessionState = .ended
            Log.session.error("Microphone permission denied")
        }
        return granted
    }

    func hostSession() {
        guard sessionState == .ready else { return }
        role = .host
        sessionState = .connecting
        transport.startAdvertising()
        Log.session.info("Hosting session — auto-accepting connections")
    }

    func joinSession() {
        guard sessionState == .ready else { return }
        role = .guest
        sessionState = .connecting
        transport.startBrowsing()
        Log.session.info("Joining session — browsing for peers")
    }

    func invitePeer(_ peerID: MCPeerID) {
        transport.invite(peer: peerID)
    }

    func endSession() {
        Log.session.info("Ending session")
        transport.sendControl(ControlFrame(message: .endSession))
        tearDown()
        sessionState = .ended
    }

    // MARK: - TX Control

    func toggleTX() {
        switch settings.txMode {
        case .manualTX:
            switch txState {
            case .disabled, .armed:
                setTXState(.live)
            case .live:
                setTXState(.armed)
            default:
                break
            }
        case .voiceTX:
            // Toggle mute in voice TX mode
            if txState == .muted {
                setTXState(.armed)
            } else if txState != .disabled {
                setTXState(.muted)
            }
        case .openMic:
            // Toggle mute in open mic mode
            if txState == .muted {
                setTXState(.holdOpen)
            } else if txState != .disabled {
                setTXState(.muted)
            }
        }
    }

    func updateTXMode(_ mode: TXMode) {
        settings.txMode = mode
        guard sessionState == .active else { return }
        applyTXMode()
        transport.sendControl(ControlFrame(
            message: .modeChange,
            payload: ["mode": mode.rawValue]
        ))
    }

    func updateVADSettings() {
        vad.updateSettings(
            sensitivity: settings.vadSensitivity,
            hangTime: settings.hangTime,
            windRejection: settings.windRejection
        )
    }

    // MARK: - TX State Management

    private func setTXState(_ state: TXState) {
        txState = state
        let muted = (state != .live && state != .holdOpen)
        audioEngine.setMuted(muted)

        let controlMsg: ControlMessage = muted ? .txOff : .txOn
        transport.sendControl(ControlFrame(message: controlMsg))

        Log.session.debug("TX state: \(state.rawValue)")
    }

    private func applyTXMode() {
        switch settings.txMode {
        case .openMic:
            setTXState(.holdOpen)
        case .voiceTX:
            setTXState(.armed)
        case .manualTX:
            setTXState(.armed)
        }
    }

    // MARK: - Handshake

    private func startHandshake() {
        let isHost = (role == .host)
        handshake = HandshakeManager(transport: transport, isHost: isHost)
        handshake?.start { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handleHandshakeResult(result)
            }
        }
    }

    private func handleHandshakeResult(_ result: Result<Capabilities, HandshakeManager.HandshakeError>) {
        switch result {
        case .success(let caps):
            Log.session.info("Handshake complete: protocol v\(caps.protocolVersion)")
            beginActiveSession()
        case .failure(let error):
            Log.session.error("Handshake failed: \(String(describing: error))")
            tearDown()
            sessionState = .ended
        }
    }

    private func beginActiveSession() {
        sessionState = .active
        metrics.markSessionStart()

        do {
            // Audio session was pre-configured in requestPermissions().
            // Re-configure here only as a safety net (idempotent).
            try routeManager.configureSession()
            routeState = routeManager.currentRoute
            try audioEngine.start()
        } catch {
            Log.session.error("Failed to start audio: \(error.localizedDescription)")
            tearDown()
            sessionState = .ended
            return
        }

        remoteControl.activate()
        applyTXMode()
        startMonitoring()

        Log.session.info("Session active")
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        // Monitor route changes
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await route in self.routeManager.routeChanges {
                self.routeState = route
                self.recovery.handleRouteChange(route, speakerFallback: self.settings.speakerFallback)
                self.transport.sendControl(ControlFrame(
                    message: .routeChanged,
                    payload: ["route": route.rawValue]
                ))
            }
        })

        // Monitor interruptions
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.routeManager.interruptions {
                self.recovery.handleInterruption(event)
            }
        })

        // Monitor VAD
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await isVoice in self.vad.voiceActivity {
                if self.settings.txMode == .voiceTX && self.sessionState == .active {
                    self.setTXState(isVoice ? .live : .armed)
                }
            }
        })

        // Monitor remote control
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.remoteControl.events {
                if case .toggleTX = event {
                    self.toggleTX()
                }
            }
        })

        // Monitor recovery actions
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await action in self.recovery.actions {
                self.handleRecoveryAction(action)
            }
        })
    }

    private func handleRecoveryAction(_ action: RecoverySupervisor.RecoveryAction) {
        switch action {
        case .reconnect:
            sessionState = .reconnecting
            metrics.incrementReconnectCount()

            // Only set up advertising/browsing on the first attempt.
            // Subsequent recovery ticks should not recreateSession() —
            // that kills any MC negotiation in flight.
            guard !reconnectionAttempted else {
                Log.session.info("Recovery: already advertising/browsing, waiting for connection")
                return
            }
            reconnectionAttempted = true

            audioEngine.stop()
            transport.recreateSession()
            if role == .host {
                transport.startAdvertising()
                Log.session.info("Recovery: re-advertising as host")
            } else {
                transport.setAutoInviteOnDiscover(true)
                transport.startBrowsing()
                Log.session.info("Recovery: re-browsing as guest (will auto-invite)")
            }

        case .routeDegraded(let route):
            routeState = route
            Log.session.warning("Route degraded to \(route.rawValue)")

        case .routeFailed:
            sessionState = .routeFailed
            audioEngine.stop()

        case .interrupted:
            sessionState = .interrupted
            audioEngine.stop()

        case .resumed:
            do {
                try routeManager.configureSession()
                try audioEngine.start()
                sessionState = .active
                applyTXMode()
            } catch {
                Log.session.error("Resume failed: \(error.localizedDescription)")
                sessionState = .ended
            }

        case .gaveUp:
            tearDown()
            sessionState = .ended
        }
    }

    // MARK: - Tear Down

    private func tearDown() {
        for task in monitorTasks { task.cancel() }
        monitorTasks.removeAll()

        audioEngine.stop()
        remoteControl.deactivate()
        transport.stopAdvertising()
        transport.stopBrowsing()
        transport.disconnect()
        recovery.reset()
        handshake?.reset()

        txState = .disabled
        connectedPeerName = nil
        role = nil
        reconnectionAttempted = false

        Log.session.info("Session torn down")
    }
}

// MARK: - AudioEngineDelegate

extension SessionCoordinator: AudioEngineDelegate {
    nonisolated func audioEngine(_ engine: AudioEngine, didCapture header: AudioFrameHeader, payload: Data) {
        // Send captured audio to the peer
        transport.sendAudio(header: header, payload: payload)

        // Feed VAD
        if let buffer = AudioFormatConverter.int16DataToFloat32(payload) {
            vad.process(buffer)
        }

        Task { @MainActor in
            self.metrics.incrementPacketsSent()
        }
    }
}

// MARK: - PeerTransportDelegate

extension SessionCoordinator: PeerTransportDelegate {
    nonisolated func transport(_ transport: PeerTransport, didReceiveAudio header: AudioFrameHeader, payload: Data) {
        audioEngine.receiveAudioFrame(sequenceNumber: header.sequenceNumber, payload: payload)
        Task { @MainActor in
            self.metrics.incrementPacketsReceived()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, didReceiveControl frame: ControlFrame) {
        Task { @MainActor in
            self.handleControlFrame(frame)
        }
    }

    nonisolated func transport(_ transport: PeerTransport, peerDidConnect peerID: MCPeerID) {
        Task { @MainActor in
            self.connectedPeerName = peerID.displayName
            self.transport.stopAdvertising()
            self.transport.stopBrowsing()
            self.recovery.handleReconnectSucceeded()
            self.reconnectionAttempted = false
            Log.session.info("Peer connected: \(peerID.displayName)")
            self.startHandshake()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, peerDidDisconnect peerID: MCPeerID) {
        Task { @MainActor in
            if self.sessionState == .active {
                self.recovery.handlePeerDisconnected()
                self.sessionState = .reconnecting
            }
        }
    }
}

// MARK: - Control Frame Handling

extension SessionCoordinator {
    private func handleControlFrame(_ frame: ControlFrame) {
        // Route handshake messages to the handshake manager
        switch frame.message {
        case .hello, .helloAck, .caps, .ready, .start:
            handshake?.receive(frame)
            return
        default:
            break
        }

        switch frame.message {
        case .endSession:
            Log.session.info("Remote peer ended session")
            tearDown()
            sessionState = .ended

        case .ping:
            transport.sendControl(ControlFrame(message: .pong))

        case .pong:
            // RTT measurement would be calculated here
            break

        case .modeChange:
            if let modeStr = frame.payload?["mode"],
               let mode = TXMode(rawValue: modeStr) {
                Log.session.info("Remote peer changed mode to \(mode.rawValue)")
            }

        case .txOn, .txOff, .routeChanged, .reconnecting:
            Log.session.debug("Received control: \(frame.message.rawValue)")

        default:
            break
        }
    }
}
