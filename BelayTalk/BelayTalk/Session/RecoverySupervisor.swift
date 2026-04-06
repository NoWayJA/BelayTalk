import Foundation
import OSLog

/// Monitors transport disconnection, route changes, and interruptions.
///
/// - Auto-reconnect with exponential backoff (0.5s → 5s cap, 10 max attempts)
/// - Route degradation: BT→speaker = warn, →unavailable = pause
/// - Interruption pause/resume respecting `shouldResume`
nonisolated final class RecoverySupervisor {

    struct Configuration {
        var initialDelay: TimeInterval = 0.5
        var maxDelay: TimeInterval = 5.0
        var maxAttempts: Int = 10
        var autoResume: Bool = true
    }

    enum RecoveryAction: Sendable {
        case reconnect
        case routeDegraded(RouteState)
        case routeFailed
        case interrupted
        case resumed
        case gaveUp
    }

    private let actionContinuation: AsyncStream<RecoveryAction>.Continuation
    let actions: AsyncStream<RecoveryAction>

    private var config: Configuration
    private var currentAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    init(configuration: Configuration = Configuration()) {
        self.config = configuration

        var c: AsyncStream<RecoveryAction>.Continuation!
        actions = AsyncStream { c = $0 }
        actionContinuation = c
    }

    deinit {
        reconnectTask?.cancel()
        actionContinuation.finish()
    }

    func updateConfiguration(_ config: Configuration) {
        self.config = config
    }

    // MARK: - Peer Disconnection

    func handlePeerDisconnected() {
        Log.session.warning("Peer disconnected — starting recovery")
        currentAttempt = 0
        scheduleReconnect()
    }

    func handleReconnectSucceeded() {
        reconnectTask?.cancel()
        reconnectTask = nil
        currentAttempt = 0
        Log.session.info("Recovery: reconnect succeeded")
    }

    private func scheduleReconnect() {
        guard currentAttempt < config.maxAttempts else {
            Log.session.error("Recovery: max attempts (\(self.config.maxAttempts)) reached — giving up")
            actionContinuation.yield(.gaveUp)
            return
        }

        let delay = min(
            config.initialDelay * pow(2.0, Double(currentAttempt)),
            config.maxDelay
        )
        currentAttempt += 1

        Log.session.info("Recovery: attempt \(self.currentAttempt)/\(self.config.maxAttempts) in \(String(format: "%.1f", delay))s")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.actionContinuation.yield(.reconnect)
        }
    }

    // MARK: - Route Changes

    func handleRouteChange(_ newRoute: RouteState, speakerFallback: Bool) {
        switch newRoute {
        case .bluetooth, .wired:
            Log.route.info("Recovery: route OK (\(newRoute.rawValue))")

        case .builtIn:
            if speakerFallback {
                Log.route.warning("Recovery: degraded to built-in speaker (fallback enabled)")
                actionContinuation.yield(.routeDegraded(newRoute))
            } else {
                Log.route.error("Recovery: route degraded to built-in, no fallback — failing")
                actionContinuation.yield(.routeFailed)
            }

        case .changing:
            Log.route.info("Recovery: route changing...")

        case .unavailable:
            Log.route.error("Recovery: route unavailable")
            actionContinuation.yield(.routeFailed)
        }
    }

    // MARK: - Interruptions

    func handleInterruption(_ event: InterruptionEvent) {
        switch event {
        case .began:
            Log.session.warning("Recovery: audio interrupted")
            actionContinuation.yield(.interrupted)

        case .ended(let shouldResume):
            if shouldResume && config.autoResume {
                Log.session.info("Recovery: interruption ended, resuming")
                actionContinuation.yield(.resumed)
            } else {
                Log.session.info("Recovery: interruption ended, not resuming (shouldResume=\(shouldResume), autoResume=\(self.config.autoResume))")
            }
        }
    }

    func reset() {
        reconnectTask?.cancel()
        reconnectTask = nil
        currentAttempt = 0
    }
}
