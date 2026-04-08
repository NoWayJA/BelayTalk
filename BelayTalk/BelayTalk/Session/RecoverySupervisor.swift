import Foundation
import OSLog
import os

/// Monitors transport disconnection, route changes, and interruptions.
///
/// - Auto-reconnect with exponential backoff (0.5s → 5s cap, 10 max attempts)
/// - Route degradation: BT→speaker = warn, →unavailable = pause
/// - Interruption pause/resume respecting `shouldResume`
nonisolated final class RecoverySupervisor: @unchecked Sendable {

    struct Configuration: Sendable {
        var initialDelay: TimeInterval = 0.5
        var maxDelay: TimeInterval = 5.0
        var maxAttempts: Int = 10
        var autoResume: Bool = true
    }

    enum RecoveryAction: Sendable {
        case reconnect(attempt: Int)
        case routeDegraded(RouteState)
        case routeFailed
        case interrupted
        case resumed
        case gaveUp
    }

    private let lock = OSAllocatedUnfairLock<MutableState>(initialState: MutableState())
    private struct MutableState {
        var actionContinuation: AsyncStream<RecoveryAction>.Continuation?
        var config = Configuration()
        var currentAttempt = 0
        var reconnectTask: Task<Void, Never>?
    }

    var maxAttempts: Int {
        lock.withLock { $0.config.maxAttempts }
    }

    /// Each call creates a fresh stream — safe for multiple session lifetimes.
    private(set) var actions: AsyncStream<RecoveryAction>

    init(configuration: Configuration = Configuration()) {
        let (stream, continuation) = AsyncStream<RecoveryAction>.makeStream()
        actions = stream
        lock.withLock { state in
            state.actionContinuation = continuation
            state.config = configuration
        }
    }

    deinit {
        lock.withLock { state in
            state.reconnectTask?.cancel()
            state.actionContinuation?.finish()
        }
    }

    func updateConfiguration(_ config: Configuration) {
        lock.withLock { $0.config = config }
    }

    /// Recreate the actions stream for a new session. Call before startMonitoring().
    func recreateStream() {
        let (stream, continuation) = AsyncStream<RecoveryAction>.makeStream()
        lock.withLock { state in
            state.actionContinuation?.finish()
            state.actionContinuation = continuation
        }
        actions = stream
    }

    // MARK: - Peer Disconnection

    func handlePeerDisconnected() {
        Log.session.warning("Peer disconnected — starting recovery")
        lock.withLock { $0.currentAttempt = 0 }
        scheduleReconnect()
    }

    func handleReconnectSucceeded() {
        lock.withLock { state in
            state.reconnectTask?.cancel()
            state.reconnectTask = nil
            state.currentAttempt = 0
        }
        Log.session.info("Recovery: reconnect succeeded")
    }

    /// Schedule the next reconnection attempt. Automatically reschedules
    /// on failure up to maxAttempts with exponential backoff.
    func scheduleReconnect() {
        let (attempt, delay, shouldGiveUp) = lock.withLock { state -> (Int, TimeInterval, Bool) in
            if state.currentAttempt >= state.config.maxAttempts {
                return (state.currentAttempt, 0, true)
            }
            let delay = min(
                state.config.initialDelay * pow(2.0, Double(state.currentAttempt)),
                state.config.maxDelay
            )
            state.currentAttempt += 1
            return (state.currentAttempt, delay, false)
        }

        if shouldGiveUp {
            Log.session.error("Recovery: max attempts reached — giving up")
            yieldAction(.gaveUp)
            return
        }

        Log.session.info("Recovery: attempt \(attempt) in \(String(format: "%.1f", delay))s")

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.yieldAction(.reconnect(attempt: attempt))
        }
        lock.withLock { $0.reconnectTask = task }
    }

    // MARK: - Route Changes

    func handleRouteChange(_ newRoute: RouteState, speakerFallback: Bool) {
        switch newRoute {
        case .bluetooth, .wired:
            Log.route.info("Recovery: route OK (\(newRoute.rawValue))")

        case .builtIn:
            if speakerFallback {
                Log.route.warning("Recovery: degraded to built-in speaker (fallback enabled)")
                yieldAction(.routeDegraded(newRoute))
            } else {
                Log.route.error("Recovery: route degraded to built-in, no fallback — failing")
                yieldAction(.routeFailed)
            }

        case .changing:
            Log.route.info("Recovery: route changing...")

        case .unavailable:
            Log.route.error("Recovery: route unavailable")
            yieldAction(.routeFailed)
        }
    }

    // MARK: - Interruptions

    func handleInterruption(_ event: InterruptionEvent) {
        switch event {
        case .began:
            Log.session.warning("Recovery: audio interrupted")
            yieldAction(.interrupted)

        case .ended(let shouldResume):
            let autoResume = lock.withLock { $0.config.autoResume }
            if shouldResume && autoResume {
                Log.session.info("Recovery: interruption ended, resuming")
                yieldAction(.resumed)
            } else {
                Log.session.info("Recovery: interruption ended, not resuming (shouldResume=\(shouldResume), autoResume=\(autoResume))")
            }
        }
    }

    func reset() {
        lock.withLock { state in
            state.reconnectTask?.cancel()
            state.reconnectTask = nil
            state.currentAttempt = 0
        }
    }

    // MARK: - Private

    private func yieldAction(_ action: RecoveryAction) {
        lock.withLock { state in
            _ = state.actionContinuation?.yield(action)
        }
    }
}
