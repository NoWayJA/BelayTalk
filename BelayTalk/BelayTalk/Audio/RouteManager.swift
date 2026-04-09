import AVFoundation
import OSLog
import os

// MARK: - Protocol

nonisolated protocol RouteManaging: Sendable {
    var currentRoute: RouteState { get }
    var routeChanges: AsyncStream<RouteState> { get }
    var interruptions: AsyncStream<InterruptionEvent> { get }
    func configureSession() throws
    func configureSessionWithoutBluetooth() throws
    func upgradeToBluetoothHFP() throws
    func deactivateSession()
}

// MARK: - Implementation

nonisolated final class RouteManager: RouteManaging, @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()

    private let lock = OSAllocatedUnfairLock<RouteState>(initialState: .unavailable)

    var currentRoute: RouteState {
        lock.withLock { $0 }
    }

    private let routeContinuation: AsyncStream<RouteState>.Continuation
    let routeChanges: AsyncStream<RouteState>

    private let interruptionContinuation: AsyncStream<InterruptionEvent>.Continuation
    let interruptions: AsyncStream<InterruptionEvent>

    private var routeObserver: (any NSObjectProtocol)?
    private var interruptionObserver: (any NSObjectProtocol)?

    init() {
        var routeC: AsyncStream<RouteState>.Continuation!
        routeChanges = AsyncStream { routeC = $0 }
        routeContinuation = routeC

        var intC: AsyncStream<InterruptionEvent>.Continuation!
        interruptions = AsyncStream { intC = $0 }
        interruptionContinuation = intC

        observeNotifications()
    }

    deinit {
        routeContinuation.finish()
        interruptionContinuation.finish()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func configureSession() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(AudioConstants.sampleRate)
        try session.setPreferredIOBufferDuration(
            Double(AudioConstants.frameDurationMs) / 1000.0
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let route = detectRoute()
        lock.withLock { $0 = route }
        Log.route.info("Audio session configured, route: \(route.rawValue)")
    }

    /// Phase 1 audio configuration: voice processing WITHOUT Bluetooth HFP.
    /// Routes audio to the built-in speaker/mic to avoid A2DP→HFP switch
    /// that disrupts the AWDL radio MultipeerConnectivity uses.
    /// Echo cancellation still works via AudioEngine's setVoiceProcessingEnabled(true).
    func configureSessionWithoutBluetooth() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker]  // NO .allowBluetoothHFP
        )
        try session.setPreferredSampleRate(AudioConstants.sampleRate)
        try session.setPreferredIOBufferDuration(
            Double(AudioConstants.frameDurationMs) / 1000.0
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let route = detectRoute()
        lock.withLock { $0 = route }
        Log.route.info("Audio session configured (no BT), route: \(route.rawValue)")
    }

    /// Phase 2: Upgrade to Bluetooth HFP after MC connection is stable.
    /// Only changes the category options — mode stays .voiceChat so voice
    /// processing continues uninterrupted. This triggers A2DP→HFP switch.
    func upgradeToBluetoothHFP() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        let route = detectRoute()
        lock.withLock { $0 = route }
        Log.route.info("Audio session upgraded to BT HFP, route: \(route.rawValue)")
    }

    func deactivateSession() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            Log.route.info("Audio session deactivated")
        } catch {
            // Deactivation can fail if another app has the session active.
            // This is non-fatal — the session will be reconfigured on next use.
            Log.route.warning("Audio session deactivation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Route Detection

    private func detectRoute() -> RouteState {
        let outputs = session.currentRoute.outputs
        guard let port = outputs.first else { return .unavailable }
        switch port.portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth
        case .headphones, .usbAudio:
            return .wired
        case .builtInSpeaker, .builtInReceiver:
            return .builtIn
        default:
            return .builtIn
        }
    }

    // MARK: - Notification Observers (block-based for safe deinit)

    private func observeNotifications() {
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleRouteChange()
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
    }

    private func handleRouteChange() {
        let newRoute = detectRoute()
        let oldRoute = lock.withLock { current -> RouteState in
            let old = current
            current = newRoute
            return old
        }
        if newRoute != oldRoute {
            Log.route.info("Route changed: \(oldRoute.rawValue) → \(newRoute.rawValue)")
            routeContinuation.yield(newRoute)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            Log.route.warning("Audio interruption began")
            interruptionContinuation.yield(.began)
        case .ended:
            let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options)
                .contains(.shouldResume)
            Log.route.info("Audio interruption ended, shouldResume: \(shouldResume)")
            interruptionContinuation.yield(.ended(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }
}
