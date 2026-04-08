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
    /// Timeout task for reconnection — if peer doesn't reconnect in time, schedule next attempt.
    private var reconnectTimeoutTask: Task<Void, Never>?

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
            // Do NOT configure the audio session here. Activating .voiceChat mode
            // starts voice processing which interferes with the AWDL radio that
            // MultipeerConnectivity uses for discovery and connection.
            // Audio session is configured in beginActiveSession() after handshake.
            sessionState = .ready
            Log.session.info("Microphone permission granted")
        } else {
            sessionState = .idle
            Log.session.error("Microphone permission denied")
        }
        return granted
    }

    /// Prepare coordinator for a new session (reset state from .ended to .ready).
    func prepareForNewSession() {
        guard sessionState == .ended else { return }
        transport.recreateSession()
        metrics.reset()
        sessionState = .ready
        Log.session.info("Ready for new session")
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
        // Send endSession control frame and give it a moment to deliver
        // before tearing down the transport. MCSession.disconnect() kills
        // the DTLS connection immediately, so without this delay the
        // reliable frame never reaches the peer.
        transport.sendControl(ControlFrame(message: .endSession))
        sessionState = .ending
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            tearDown()
            sessionState = .ready
        }
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
        // Cancel any existing monitoring from a previous active phase (e.g., reconnection)
        cancelMonitoring()

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
            sessionState = .ready
        }
    }

    private func beginActiveSession() {
        sessionState = .active
        metrics.markSessionStart()

        do {
            // Configure audio session AFTER MC handshake is complete.
            // Setting .voiceChat mode before MC connects interferes with AWDL radio.
            try routeManager.configureSession()
            routeState = routeManager.currentRoute
            try audioEngine.start()
        } catch {
            Log.session.error("Failed to start audio: \(error.localizedDescription)")
            tearDown()
            sessionState = .ready
            return
        }

        remoteControl.activate()
        applyTXMode()

        // Recreate recovery stream for this session so the for-await loop starts fresh
        recovery.recreateStream()
        startMonitoring()

        Log.session.info("Session active")
    }

    // MARK: - Monitoring

    private func cancelMonitoring() {
        for task in monitorTasks { task.cancel() }
        monitorTasks.removeAll()
    }

    private func startMonitoring() {
        // Cancel any previous monitors first to prevent accumulation
        cancelMonitoring()

        // Monitor route changes
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await route in self.routeManager.routeChanges {
                guard !Task.isCancelled else { break }
                self.routeState = route
                self.recovery.handleRouteChange(route, speakerFallback: self.settings.speakerFallback)
                if self.sessionState == .active {
                    self.transport.sendControl(ControlFrame(
                        message: .routeChanged,
                        payload: ["route": route.rawValue]
                    ))
                }
            }
        })

        // Monitor interruptions
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.routeManager.interruptions {
                guard !Task.isCancelled else { break }
                self.recovery.handleInterruption(event)
            }
        })

        // Monitor VAD
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await isVoice in self.vad.voiceActivity {
                guard !Task.isCancelled else { break }
                if self.settings.txMode == .voiceTX && self.sessionState == .active {
                    self.setTXState(isVoice ? .live : .armed)
                }
            }
        })

        // Monitor remote control
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.remoteControl.events {
                guard !Task.isCancelled else { break }
                if case .toggleTX = event {
                    self.toggleTX()
                }
            }
        })

        // Monitor recovery actions
        monitorTasks.append(Task { [weak self] in
            guard let self else { return }
            for await action in self.recovery.actions {
                guard !Task.isCancelled else { break }
                self.handleRecoveryAction(action)
            }
        })
    }

    private func handleRecoveryAction(_ action: RecoverySupervisor.RecoveryAction) {
        switch action {
        case .reconnect:
            sessionState = .reconnecting
            metrics.incrementReconnectCount()

            // Stop audio on first attempt only
            if !reconnectionAttempted {
                audioEngine.stop()
            }
            reconnectionAttempted = true

            // Always tear down and recreate the MC layer for each attempt.
            // A failed MC connection leaves the session in a corrupted internal state
            // ("Not in connected state, so giving up for participant..."), so we must
            // start fresh each time.
            transport.stopAdvertising()
            transport.stopBrowsing()
            transport.recreateSession()

            if role == .host {
                transport.startAdvertising()
                Log.session.info("Recovery: re-advertising as host")
            } else {
                transport.setAutoInviteOnDiscover(true)
                transport.startBrowsing()
                Log.session.info("Recovery: re-browsing as guest (will auto-invite)")
            }

            // Set a timeout — if not reconnected in time, schedule next attempt
            reconnectTimeoutTask?.cancel()
            reconnectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                guard let self, self.sessionState == .reconnecting else { return }
                Log.session.info("Recovery: reconnect attempt timed out, scheduling next")
                self.recovery.scheduleReconnect()
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
                tearDown()
                sessionState = .ready
            }

        case .gaveUp:
            tearDown()
            sessionState = .ready
        }
    }

    // MARK: - Tear Down

    private func tearDown() {
        cancelMonitoring()
        reconnectTimeoutTask?.cancel()
        reconnectTimeoutTask = nil

        audioEngine.stop()
        remoteControl.deactivate()
        transport.stopAdvertising()
        transport.stopBrowsing()
        transport.disconnect()
        transport.recreateSession()  // Ensure fresh MCSession for next use
        recovery.reset()
        handshake?.reset()
        metrics.reset()

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

        // Feed VAD with the original Float32 data via Int16→Float32 roundtrip.
        // This is necessary since we only have the wire-encoded payload here.
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
            self.reconnectTimeoutTask?.cancel()
            self.reconnectTimeoutTask = nil
            Log.session.info("Peer connected: \(peerID.displayName)")
            self.startHandshake()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, peerDidDisconnect peerID: MCPeerID) {
        Task { @MainActor in
            switch self.sessionState {
            case .active, .interrupted, .routeFailed:
                // Peer dropped during an active session — attempt recovery
                self.recovery.handlePeerDisconnected()
                self.sessionState = .reconnecting
            case .connecting:
                // Connection attempt failed (e.g., AWDL/DTLS race).
                // Stay in .connecting and retry — recreate the MC session to clear
                // stale DTLS state, then resume advertising/browsing. The peer is
                // still there, so MC will rediscover it.
                Log.session.warning("Connection attempt failed, retrying...")
                self.handshake?.reset()
                self.transport.recreateSession()
                if self.role == .host {
                    self.transport.startAdvertising()
                } else {
                    self.transport.startBrowsing()
                }
            case .reconnecting:
                // Another disconnect during reconnection — will be retried by timeout
                Log.session.warning("Peer disconnected during reconnection")
            case .ending, .ended, .ready:
                // We initiated the disconnect, or session is already over — ignore
                break
            default:
                break
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
            sessionState = .ready

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
