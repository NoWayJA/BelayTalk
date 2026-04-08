import MediaPlayer
import OSLog

// MARK: - Protocol

nonisolated protocol RemoteControlHandling: Sendable {
    var events: AsyncStream<RemoteControlEvent> { get }
    func activate()
    func deactivate()
}

// MARK: - Implementation

/// Handles headset button presses via MPRemoteCommandCenter.
///
/// Maps togglePlayPause / play / pause to TX toggle.
/// Sets minimal NowPlayingInfo (required for commands to fire).
nonisolated final class RemoteControlHandler: RemoteControlHandling, @unchecked Sendable {
    private let commandCenter = MPRemoteCommandCenter.shared()

    private let eventContinuation: AsyncStream<RemoteControlEvent>.Continuation
    let events: AsyncStream<RemoteControlEvent>

    init() {
        var c: AsyncStream<RemoteControlEvent>.Continuation!
        events = AsyncStream { c = $0 }
        eventContinuation = c
    }

    deinit {
        deactivate()
        eventContinuation.finish()
    }

    func activate() {
        // Deactivate first to prevent accumulating duplicate targets
        deactivate()

        // Set minimal now-playing info so remote commands are delivered
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "BelayTalk",
            MPMediaItemPropertyArtist: "Active Session",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleToggle()
            return .success
        }
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handleToggle()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handleToggle()
            return .success
        }

        Log.remote.info("Remote control activated")
    }

    func deactivate() {
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        Log.remote.info("Remote control deactivated")
    }

    private func handleToggle() {
        Log.remote.debug("Headset button pressed — toggle TX")
        eventContinuation.yield(.toggleTX)
    }
}
