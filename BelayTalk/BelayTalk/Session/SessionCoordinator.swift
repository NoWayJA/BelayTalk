import AVFoundation
import MultipeerConnectivity
import OSLog
import UIKit

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
    /// Current reconnection attempt number (0 = not reconnecting). Observable for UI.
    private(set) var reconnectAttempt: Int = 0
    /// Granular status message for the UI during connection lifecycle.
    private(set) var connectionStatusMessage: String = ""

    let metrics = SessionMetrics()
    let settings = AppSettings()

    // MARK: - Modules

    let transport: PeerTransport
    private let audioEngine = AudioEngine()
    private let routeManager = RouteManager()
    private let vad = VoiceActivityDetector()
    private let remoteControl = RemoteControlHandler()
    let recovery = RecoverySupervisor()
    private var handshake: HandshakeManager?

    // MARK: - Task Management

    private var monitorTasks: [Task<Void, Never>] = []
    private var reconnectionAttempted = false
    /// Timeout task for reconnection — if peer doesn't reconnect in time, schedule next attempt.
    private var reconnectTimeoutTask: Task<Void, Never>?
    /// Timeout task for the initial connection attempt.
    private var connectTimeoutTask: Task<Void, Never>?
    /// Number of connection retries during the initial .connecting phase.
    private var connectRetryCount = 0
    /// Maximum retries during initial connection before giving up.
    private static let maxConnectRetries = 3
    /// How long to wait for the initial connection before timing out.
    private static let connectTimeoutSeconds: TimeInterval = 30
    /// Grace period: during the first few seconds after audio startup,
    /// MC disconnects are expected (BT HFP negotiation disrupts AWDL).
    private var isInAudioStartupGrace = false
    private var audioStartupGraceTask: Task<Void, Never>?

    init() {
        transport = PeerTransport(displayName: settings.displayName)
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
        connectRetryCount = 0
        sessionState = .connecting
        connectionStatusMessage = "Advertising session…"
        transport.startAdvertising()
        startConnectTimeout()
        Log.session.info("Hosting session — auto-accepting connections")
    }

    func joinSession() {
        guard sessionState == .ready else { return }
        role = .guest
        connectRetryCount = 0
        sessionState = .connecting
        connectionStatusMessage = "Searching for peers…"
        transport.startBrowsing()
        startConnectTimeout()
        Log.session.info("Joining session — browsing for peers")
    }

    func invitePeer(_ peerID: MCPeerID) {
        connectionStatusMessage = "Connecting to \(peerID.displayName)…"
        transport.invite(peer: peerID)
    }

    /// Cancel a connection attempt (before session is active). No control frame needed.
    func cancelConnecting() {
        guard sessionState == .connecting else { return }
        Log.session.info("Connection attempt cancelled")
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        transport.stopAdvertising()
        transport.stopBrowsing()
        transport.disconnect()
        transport.recreateSession()
        routeManager.deactivateSession()
        handshake?.reset()
        connectedPeerName = nil
        role = nil
        connectRetryCount = 0
        connectionStatusMessage = ""
        sessionState = .ready
    }

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeoutSeconds))
            guard !Task.isCancelled else { return }
            guard let self, self.sessionState == .connecting else { return }
            Log.session.warning("Connection timed out after \(Self.connectTimeoutSeconds)s")
            self.cancelConnecting()
        }
    }

    /// User manually gives up on reconnection.
    func giveUpReconnecting() {
        guard sessionState == .reconnecting else { return }
        Log.session.info("User gave up reconnecting")
        tearDown()
        sessionState = .ready
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

    /// Apply a display name change to the transport layer.
    /// Only takes effect when not in an active session.
    func updateDisplayName(_ name: String) {
        guard sessionState == .idle || sessionState == .ready ||
              sessionState == .permissions || sessionState == .ended else { return }
        transport.updateDisplayName(name)
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

    // MARK: - App Lifecycle

    /// Call when the app enters the background (screen lock, home button, etc.)
    func handleDidEnterBackground() {
        guard sessionState == .active || sessionState == .reconnecting else { return }
        Log.session.info("App entered background — audio session stays active")
        // Audio session + engine continue running via background audio entitlement.
        // The silence buffer in AudioEngine keeps iOS from suspending us.
    }

    /// Call when the app returns to the foreground.
    func handleWillEnterForeground() {
        guard sessionState == .active || sessionState == .reconnecting ||
              sessionState == .interrupted else { return }
        Log.session.info("App entering foreground")

        // Re-activate the audio session in case iOS deactivated it while backgrounded.
        // This handles edge cases like Siri or phone calls interrupting audio.
        if sessionState == .interrupted {
            do {
                try routeManager.configureSession()
                try audioEngine.start()
                sessionState = .active
                applyTXMode()
                Log.session.info("Audio resumed after foreground return")
            } catch {
                Log.session.error("Failed to resume audio on foreground: \(error.localizedDescription)")
            }
        }
    }

    /// Keeps the screen on during an active session when the user has opted in.
    func updateIdleTimer() {
        let inSession = (sessionState == .active || sessionState == .reconnecting ||
                         sessionState == .interrupted || sessionState == .connecting)
        UIApplication.shared.isIdleTimerDisabled = settings.preventAutoLock && inSession
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
            if sessionState == .active && audioEngine.isRunning {
                // Re-handshake during grace period — audio already running, nothing more to do
                Log.session.info("Handshake succeeded on existing active session (grace reconnect)")
            } else {
                beginActiveSession()
            }
        case .failure(let error):
            Log.session.error("Handshake failed: \(String(describing: error))")
            if isInAudioStartupGrace {
                // During grace, a handshake failure is non-fatal — connection may re-establish
                Log.session.info("Handshake failed during grace period — waiting for reconnect")
            } else {
                tearDown()
                sessionState = .ready
            }
        }
    }

    private func beginActiveSession() {
        sessionState = .active
        connectionStatusMessage = "Starting audio…"
        metrics.markSessionStart()
        vad.reset()

        // Start the audio startup grace period BEFORE configuring audio.
        // BT HFP negotiation during .voiceChat mode setup disrupts AWDL,
        // causing MC disconnects. These are transient and expected.
        isInAudioStartupGrace = true
        audioStartupGraceTask?.cancel()
        audioStartupGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isInAudioStartupGrace = false
            self.audioStartupGraceTask = nil
            Log.session.info("Audio startup grace period ended")
            // If we disconnected during grace and never reconnected, trigger recovery now
            if !self.transport.isConnected && self.sessionState == .active {
                Log.session.warning("Still disconnected after grace period — triggering recovery")
                self.recovery.handlePeerDisconnected()
                self.sessionState = .reconnecting
            }
        }

        do {
            // Configure audio session AFTER MC handshake is complete.
            // Setting .voiceChat mode before MC connects interferes with AWDL radio.
            try routeManager.configureSession()
            routeState = routeManager.currentRoute
            try audioEngine.start()
        } catch {
            Log.session.error("Failed to start audio: \(error.localizedDescription)")
            isInAudioStartupGrace = false
            audioStartupGraceTask?.cancel()
            audioStartupGraceTask = nil
            tearDown()
            sessionState = .ready
            return
        }

        remoteControl.activate()
        applyTXMode()

        // Recreate recovery stream for this session so the for-await loop starts fresh
        recovery.recreateStream()
        startMonitoring()

        connectionStatusMessage = "Active"
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
        case .reconnect(let attempt):
            sessionState = .reconnecting
            reconnectAttempt = attempt
            connectionStatusMessage = "Reconnecting (attempt \(attempt))…"
            metrics.incrementReconnectCount()
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
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        reconnectTimeoutTask?.cancel()
        reconnectTimeoutTask = nil
        audioStartupGraceTask?.cancel()
        audioStartupGraceTask = nil
        isInAudioStartupGrace = false

        audioEngine.stop()
        routeManager.deactivateSession()
        vad.reset()
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
        reconnectAttempt = 0
        connectRetryCount = 0
        connectionStatusMessage = ""
        UIApplication.shared.isIdleTimerDisabled = false

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
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.reconnectAttempt = 0
            self.connectedPeerName = peerID.displayName
            self.transport.stopAdvertising()
            self.transport.stopBrowsing()
            self.recovery.handleReconnectSucceeded()
            self.reconnectionAttempted = false
            self.reconnectTimeoutTask?.cancel()
            self.reconnectTimeoutTask = nil

            if self.isInAudioStartupGrace && self.sessionState == .active {
                // Reconnected during grace — audio is already running.
                // Just re-handshake on the new MC connection.
                self.connectionStatusMessage = "Reconnected — re-handshaking…"
                Log.session.info("Peer reconnected during audio startup grace — re-handshaking")
            } else {
                self.connectionStatusMessage = "Connected — handshaking…"
                Log.session.info("Peer connected: \(peerID.displayName)")
            }
            self.startHandshake()
        }
    }

    nonisolated func transport(_ transport: PeerTransport, peerDidDisconnect peerID: MCPeerID) {
        Task { @MainActor in
            switch self.sessionState {
            case .active, .interrupted, .routeFailed:
                if self.isInAudioStartupGrace {
                    // During audio startup, MC disconnects are expected due to
                    // BT HFP negotiation disrupting AWDL. Don't stop audio or trigger recovery.
                    Log.session.info("Disconnect during audio startup grace — ignoring (BT/AWDL expected)")
                    return
                }
                // Stop audio IMMEDIATELY to prevent DTLS error flood.
                // The MCSession is dead — sending into it produces thousands of
                // "Failed to send DTLS packet" errors until the delegate fires.
                self.audioEngine.stop()
                // Peer dropped during an active session — attempt recovery
                self.recovery.handlePeerDisconnected()
                self.sessionState = .reconnecting
            case .connecting:
                // Connection attempt failed (e.g., AWDL/DTLS race).
                self.connectRetryCount += 1
                if self.connectRetryCount >= Self.maxConnectRetries {
                    Log.session.error("Connection failed after \(self.connectRetryCount) retries — giving up")
                    self.cancelConnecting()
                } else {
                    // Stay in .connecting and retry with a short delay to let MC settle.
                    self.connectionStatusMessage = "Connection dropped — retrying (\(self.connectRetryCount)/\(Self.maxConnectRetries))…"
                    Log.session.warning("Connection attempt failed (\(self.connectRetryCount)/\(Self.maxConnectRetries)), retrying in 1s...")
                    self.handshake?.reset()
                    self.transport.recreateSession()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard self.sessionState == .connecting else { return }
                        if self.role == .host {
                            self.transport.startAdvertising()
                        } else {
                            self.transport.startBrowsing()
                        }
                    }
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

    nonisolated func transport(_ transport: PeerTransport, didFailToStartWithError error: Error) {
        Task { @MainActor in
            Log.session.error("Transport failed to start: \(error.localizedDescription)")
            self.connectionStatusMessage = "Network error — check WiFi/Bluetooth"
            // If still in connecting state, cancel after a brief delay to show the message
            if self.sessionState == .connecting {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard self.sessionState == .connecting else { return }
                    self.cancelConnecting()
                }
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
