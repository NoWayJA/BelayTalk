import AVFoundation
import OSLog

// MARK: - Protocol

nonisolated protocol RouteManaging: Sendable {
    var currentRoute: RouteState { get }
    var routeChanges: AsyncStream<RouteState> { get }
    var interruptions: AsyncStream<InterruptionEvent> { get }
    func configureSession() throws
}

// MARK: - Implementation

nonisolated final class RouteManager: RouteManaging, @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()

    private(set) var currentRoute: RouteState = .unavailable

    private let routeContinuation: AsyncStream<RouteState>.Continuation
    let routeChanges: AsyncStream<RouteState>

    private let interruptionContinuation: AsyncStream<InterruptionEvent>.Continuation
    let interruptions: AsyncStream<InterruptionEvent>

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
        NotificationCenter.default.removeObserver(self)
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
        currentRoute = detectRoute()
        Log.route.info("Audio session configured, route: \(self.currentRoute.rawValue)")
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

    // MARK: - Notification Observers

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        let newRoute = detectRoute()
        let oldRoute = currentRoute
        currentRoute = newRoute
        if newRoute != oldRoute {
            Log.route.info("Route changed: \(oldRoute.rawValue) → \(newRoute.rawValue)")
            routeContinuation.yield(newRoute)
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
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
